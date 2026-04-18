# frozen_string_literal: true

# Companies are private entities that appear as contract winners (adjudicatários).
# This controller provides a company-centric view: who they are, what contracts
# they have won, and what risk flags are attached to those contracts.
class CompaniesController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE       = 50
  PIVOT_PER_PAGE = 20
  CSV_LIMIT      = 100_000
  SORT_COLS      = %w[name won_value won_count].freeze
  CONTRACT_SORT_COLS = %w[celebration_date base_price object].freeze
  PIVOT_SORT_COLS    = %w[authority_name contract_count total_value].freeze

  def index
    @query    = params[:q].presence
    @sort_col = SORT_COLS.include?(params[:sort]) ? params[:sort] : "won_value"
    @sort_dir = params[:dir] == "asc" ? "asc" : "desc"
    @page     = [ params[:page].to_i, 1 ].max

    # Base filter — private entities only (contract winners)
    entity_scope = Entity.where(is_public_body: false)
    if @query.present? && @query.length >= 2
      term = "%#{@query}%"
      entity_scope = entity_scope.where("entities.name LIKE ? OR entities.tax_identifier LIKE ?", term, term)
    end

    @total       = entity_scope.count
    @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max

    # Use pre-computed won_value / won_contract_count columns — avoids a
    # GROUP BY + SUM over millions of contract_winners rows.
    # has_high_flag hits flag_entity_stats (small, indexed) rather than flags.
    @companies = entity_scope
      .select(
        "entities.*",
        "entities.won_contract_count AS won_count",
        "entities.won_value",
        "CASE WHEN EXISTS (
           SELECT 1 FROM flag_entity_stats fes
           WHERE fes.entity_id = entities.id AND fes.severity = 'high'
         ) THEN 1 ELSE 0 END AS has_high_flag"
      )
      .order(Arel.sql("#{@sort_col} #{@sort_dir}"))
      .limit(PER_PAGE)
      .offset((@page - 1) * PER_PAGE)
  end

  def show
    @entity = Entity.find(params[:id])

    # Total won value and contract count — use pre-computed columns to avoid
    # a full JOIN + aggregate over potentially thousands of won contracts.
    @total_won_value  = @entity.won_value
    @entity_won_total = @entity.won_contract_count

    # Flag stats across all won contracts, reshaped to match the entity view.
    won_contract_ids = ContractWinner.where(entity_id: @entity.id).select(:contract_id)
    @company_risk_score = Flag.where(contract_id: won_contract_ids).sum(:score)
    @flag_stats = Flag
      .joins(:contract)
      .where(contract_id: won_contract_ids)
      .group(:flag_type)
      .select(
        "flags.flag_type",
        "COALESCE(SUM(contracts.base_price), 0) AS total_exposure",
        "COUNT(*) AS contract_count",
        "#{Flag.max_severity_sql} AS severity"
      )
      .order("total_exposure DESC")

    @flag_types  = @flag_stats.map(&:flag_type)
    @flag_filter = params[:flag_type].presence
    @benford_analysis = BenfordAnalysis.find_by(entity_id: @entity.id)

    base_scope = @entity.contracts_won

    if @flag_filter.present?
      base_scope = base_scope.where(
        "EXISTS (SELECT 1 FROM flags f WHERE f.contract_id = contracts.id AND f.flag_type = ?)",
        @flag_filter
      )
    end

    @date_from = params[:date_from].presence
    @date_to   = params[:date_to].presence
    base_scope = base_scope.where("contracts.publication_date >= ?", @date_from) if @date_from.present?
    base_scope = base_scope.where("contracts.publication_date <= ?", @date_to)   if @date_to.present?

    @sort_col = CONTRACT_SORT_COLS.include?(params[:sort]) ? params[:sort] : "celebration_date"
    @sort_dir = params[:dir] == "asc" ? "asc" : "desc"

    respond_to do |format|
      format.html do
        # Use aggregated stats when a flag filter is active to avoid recounting the
        # same won-contract subset on every request.
        @total = if @flag_filter.blank? && @date_from.blank? && @date_to.blank?
          @entity.won_contract_count
        elsif @flag_filter.present? && @date_from.blank? && @date_to.blank?
          @flag_stats.find { |stat| stat.flag_type == @flag_filter }&.contract_count.to_i
        else
          base_scope.count
        end
        @page        = [ params[:page].to_i, 1 ].max
        @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max

        order_sql = "#{Contract.table_name}.#{@sort_col} #{@sort_dir}, #{Contract.table_name}.id #{@sort_dir}"

        @contracts = base_scope
          .preload(:contracting_entity, :data_source, :flags)
          .order(Arel.sql(order_sql))
          .limit(PER_PAGE)
          .offset((@page - 1) * PER_PAGE)

        # Directors & officers
        @directors = @entity.company_directors.order(:role, :name)

        # Pivot: contracts grouped by contracting authority
        @pivot_page = [ params[:pivot_page].to_i, 1 ].max
        @pivot_sort_col = PIVOT_SORT_COLS.include?(params[:pivot_sort]) ? params[:pivot_sort] : "total_value"
        @pivot_sort_dir = params[:pivot_dir] == "asc" ? "asc" : "desc"

        pivot_base = ContractWinner
          .joins(:contract)
          .joins("LEFT JOIN entities auth ON auth.id = contracts.contracting_entity_id")
          .where(entity_id: @entity.id)
          .group("contracts.contracting_entity_id", "auth.name", "auth.tax_identifier", "auth.id")

        # Cache the pivot GROUP BY count — changes only when contracts are re-imported,
        # so 1h TTL is safe and avoids re-running the aggregate on every page nav.
        @pivot_total       = Rails.cache.fetch("company/#{@entity.id}/pivot_total", expires_in: 1.hour) { pivot_base.count.size }
        @pivot_total_pages = [ (@pivot_total.to_f / PIVOT_PER_PAGE).ceil, 1 ].max

        @authority_pivot = pivot_base
          .select(
            "contracts.contracting_entity_id AS authority_id",
            "auth.id                          AS auth_entity_id",
            "auth.name                        AS authority_name",
            "auth.tax_identifier              AS authority_nif",
            "COUNT(DISTINCT contract_winners.id) AS contract_count",
            "COALESCE(SUM(contracts.base_price), 0) AS total_value"
          )
          .order(Arel.sql("#{@pivot_sort_col} #{@pivot_sort_dir}"))
          .limit(PIVOT_PER_PAGE)
          .offset((@pivot_page - 1) * PIVOT_PER_PAGE)
      end

      format.csv do
        csv_scope = base_scope
          .includes(:contracting_entity, :winners, :flags)
          .order(Arel.sql("#{Contract.table_name}.celebration_date DESC, #{Contract.table_name}.id DESC"))
          .limit(CSV_LIMIT)

        filename = "open-tender-watch-company-#{@entity.tax_identifier}-#{Date.current.iso8601}.csv"
        send_data generate_csv(csv_scope), filename: filename, type: "text/csv; charset=utf-8"
      end

      format.json do
        entity_json = {
          company: {
            id: @entity.id,
            name: @entity.name,
            tax_identifier: @entity.tax_identifier,
            country_code: @entity.country_code,
            address: @entity.address,
            locality: @entity.locality,
            postal_code: @entity.postal_code,
            won_contract_count: @entity.won_contract_count,
            won_value: @entity.won_value&.to_f,
            risk_score: @company_risk_score
          },
          flag_stats: @flag_stats.map { |s|
            {
              flag_type: s.flag_type,
              severity: s.severity,
              total_exposure: s.total_exposure.to_f,
              contract_count: s.contract_count.to_i
            }
          },
          benford_analysis: @benford_analysis ? {
            sample_size: @benford_analysis.sample_size,
            chi_square: @benford_analysis.chi_square,
            flagged: @benford_analysis.flagged,
            digit_distribution: @benford_analysis.digit_distribution
          } : nil,
          exported_at: Time.current.iso8601
        }
        send_data entity_json.to_json,
                  filename: "open-tender-watch-company-#{@entity.tax_identifier}-#{Date.current.iso8601}.json",
                  type: "application/json; charset=utf-8"
      end
    end
  end

  private

  def generate_csv(scope)
    require "csv"
    CSV.generate do |csv|
      csv << Contract::CSV_COLUMNS
      scope.find_each(batch_size: 1000) do |contract|
        csv << contract.to_csv_row
      end
    end
  end
end
