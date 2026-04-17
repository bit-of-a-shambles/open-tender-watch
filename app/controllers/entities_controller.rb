# frozen_string_literal: true

class EntitiesController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE  = 50
  CSV_LIMIT = 100_000
  SORT_COLS = %w[celebration_date base_price object].freeze

  def index
    base = Entity.all

    if params[:q].present? && params[:q].length >= 2
      term = "%#{params[:q]}%"
      base = base.where("entities.name LIKE ? OR entities.tax_identifier LIKE ?", term, term)
    end

    base = base.where(is_public_body: true)  if params[:type] == "public"
    base = base.where(is_public_body: false) if params[:type] == "private"

    @total       = base.count
    @page        = [ params[:page].to_i, 1 ].max
    @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max

    # Use pre-computed columns — avoids a GROUP BY + SUM over 2M+ contracts.
    @entities = base
      .order("contract_count DESC, name ASC")
      .limit(PER_PAGE)
      .offset((@page - 1) * PER_PAGE)
  end

  def show
    @entity = Entity.find(params[:id])

    # Aggregate flag stats first (always unfiltered — drives sidebar and filter chips)
    @flag_stats = FlagEntityStat
      .where(entity_id: @entity.id)
      .group(:flag_type)
      .select(
        "flag_type",
        "SUM(total_exposure) AS total_exposure",
        "SUM(contract_count) AS contract_count",
        "#{Flag.max_severity_sql} AS severity"
      )
      .order("total_exposure DESC")

    @flag_types  = @flag_stats.map(&:flag_type)
    @flag_filter = params[:flag_type].presence

    base_scope = @entity.contracts_as_contracting_entity
    @entity_contract_total = @entity.contract_count

    # Use a correlated EXISTS subquery rather than IN (subquery).
    # IN materialises the full set of matching flag rows (1M+ for A2), which
    # is extremely slow.  EXISTS short-circuits on the first hit and the
    # planner uses the composite index_flags_on_contract_id_and_flag_type
    # index: O(entity_contracts) vs O(total_flagged_contracts).
    if @flag_filter.present?
      base_scope = base_scope.where(
        "EXISTS (SELECT 1 FROM flags f WHERE f.contract_id = contracts.id AND f.flag_type = ?)",
        @flag_filter
      )
    end

    @date_from = params[:date_from].presence
    @date_to   = params[:date_to].presence

    if @date_from.present?
      base_scope = base_scope.where("publication_date >= ?", @date_from)
    end

    if @date_to.present?
      base_scope = base_scope.where("publication_date <= ?", @date_to)
    end

    @sort_col = SORT_COLS.include?(params[:sort]) ? params[:sort] : "celebration_date"
    @sort_dir = params[:dir] == "asc" ? "asc" : "desc"

    respond_to do |format|
      format.html do
        # Avoid COUNT(*) with EXISTS over tens-of-thousands of contracts for large
        # entities (e.g. 33K contracts for chualgave). When a flag filter is active,
        # use the pre-computed contract_count from flag_entity_stats instead.
        # Date filters still fall back to a real count (rare + bounded).
        @total = if @flag_filter.present? && @date_from.blank? && @date_to.blank?
          @flag_stats.find { |s| s.flag_type == @flag_filter }&.contract_count.to_i
        elsif @date_from.blank? && @date_to.blank?
          @entity.contract_count
        else
          base_scope.count
        end
        @page        = [ params[:page].to_i, 1 ].max
        @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max

        order_sql = "#{Contract.table_name}.#{@sort_col} #{@sort_dir}, #{Contract.table_name}.id #{@sort_dir}"

        # Use preload instead of includes to fire separate queries per association,
        # avoiding the "eager load + large WHERE IN" strategy that Rails picks when
        # it can't determine the final SQL at planning time.
        @contracts = base_scope
          .preload(:winners, :flags)
          .order(Arel.sql(order_sql))
          .limit(PER_PAGE)
          .offset((@page - 1) * PER_PAGE)

        @benford_analysis = BenfordAnalysis.find_by(entity_id: @entity.id)
        @entity_risk_score = Flag.joins(:contract)
                                 .where(contracts: { contracting_entity_id: @entity.id })
                                 .sum(:score)
      end

      format.csv do
        csv_scope = base_scope
          .includes(:contracting_entity, :winners, :flags)
          .order(Arel.sql("#{Contract.table_name}.celebration_date DESC, #{Contract.table_name}.id DESC"))
          .limit(CSV_LIMIT)

        filename = "open-tender-watch-entity-#{@entity.tax_identifier}-#{Date.current.iso8601}.csv"
        send_data generate_csv(csv_scope), filename: filename, type: "text/csv; charset=utf-8"
      end

      format.json do
        benford = BenfordAnalysis.find_by(entity_id: @entity.id)
        risk_score = Flag.joins(:contract)
                         .where(contracts: { contracting_entity_id: @entity.id })
                         .sum(:score)

        entity_json = {
          entity: {
            id: @entity.id,
            name: @entity.name,
            tax_identifier: @entity.tax_identifier,
            country_code: @entity.country_code,
            is_public_body: @entity.is_public_body,
            contract_count: @entity.contract_count,
            total_contracted_value: @entity.total_contracted_value&.to_f,
            risk_score: risk_score
          },
          flag_stats: @flag_stats.map { |s|
            { flag_type: s.flag_type, severity: s.severity, total_exposure: s.total_exposure.to_f, contract_count: s.contract_count.to_i }
          },
          benford_analysis: benford ? {
            sample_size: benford.sample_size,
            chi_square: benford.chi_square,
            flagged: benford.flagged,
            digit_distribution: benford.digit_distribution
          } : nil,
          exported_at: Time.current.iso8601
        }
        send_data entity_json.to_json,
                  filename: "open-tender-watch-entity-#{@entity.tax_identifier}-#{Date.current.iso8601}.json",
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
