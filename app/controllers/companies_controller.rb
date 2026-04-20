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

  # Aggregated row per flag_type with an inline per-severity breakdown. The
  # view renders the breakdown only when it contains more than one entry —
  # e.g. A9_PRICE_ANOMALY (high + medium) or B5_BENFORD_DEVIATION.
  FlagStat = Struct.new(:flag_type, :total_exposure, :contract_count, :breakdown, keyword_init: true)

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

    # Flag stats across all won contracts — one row per flag_type, with an
    # inline per-severity breakdown. The outer severity badge is derived at
    # display time from the canonical FLAG_TYPE_SEVERITY mapping so stale
    # per-row severities in flags don't leak into the UI; the breakdown
    # preserves DB severity variants for flags that legitimately have more
    # than one (A9_PRICE_ANOMALY, B5_BENFORD_DEVIATION, ...).
    won_contract_ids = ContractWinner.where(entity_id: @entity.id).select(:contract_id)
    @company_risk_score = Flag.where(contract_id: won_contract_ids).sum(:score)
    per_severity_rows = Flag
      .joins(:contract)
      .where(contract_id: won_contract_ids)
      .group(:flag_type, :severity)
      .select(
        "flags.flag_type",
        "flags.severity",
        "COALESCE(SUM(contracts.base_price), 0) AS total_exposure",
        "COUNT(*) AS contract_count"
      )
      .to_a

    @flag_stats = per_severity_rows
      .group_by(&:flag_type)
      .map { |flag_type, rows| build_flag_stat(flag_type, rows) }
      .sort_by { |s| [ s.flag_type, -s.total_exposure ] }

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
          @flag_stats
            .select { |stat| stat.flag_type == @flag_filter }
            .sum { |stat| stat.contract_count.to_i }
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

        # Directors & officers / people roles (all stints, active first)
        @directors = @entity.all_people_roles

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
              flag_type:      s.flag_type,
              severity:       helpers.flag_type_severity(s.flag_type),
              total_exposure: s.total_exposure,
              contract_count: s.contract_count,
              severity_breakdown: s.breakdown.map { |b|
                { severity: b[:severity], contract_count: b[:contract_count], total_exposure: b[:total_exposure] }
              }
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

  def build_flag_stat(flag_type, rows)
    # When the DB has a single severity for this flag_type, treat it as a
    # fixed-severity flag and override with the canonical value — this cleans
    # up stale rows (e.g. A2 stored as "high" is canonically "low"). When the
    # DB has multiple severities for the same flag_type (A9 high+medium,
    # B5 high+medium), preserve them: the variance carries signal.
    use_canonical = rows.map(&:severity).uniq.size <= 1
    canonical = helpers.flag_type_severity(flag_type)

    breakdown = rows
      .map { |r|
        { severity:       use_canonical ? canonical : r.severity,
          contract_count: r.contract_count.to_i,
          total_exposure: r.total_exposure.to_f }
      }
      .sort_by { |b| helpers.severity_rank(b[:severity]) }

    FlagStat.new(
      flag_type:      flag_type,
      total_exposure: breakdown.sum { |b| b[:total_exposure] },
      contract_count: breakdown.sum { |b| b[:contract_count] },
      breakdown:      breakdown
    )
  end

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
