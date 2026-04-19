# frozen_string_literal: true

class EntitiesController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE  = 50
  CSV_LIMIT = 100_000
  SORT_COLS = %w[celebration_date base_price object].freeze

  # Aggregated row per flag_type with an inline per-severity breakdown. The
  # view renders the breakdown only when it contains more than one entry —
  # e.g. A9_PRICE_ANOMALY (high + medium) or B5_BENFORD_DEVIATION.
  FlagStat = Struct.new(:flag_type, :total_exposure, :contract_count, :breakdown, keyword_init: true)

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

    # Aggregate flag stats — one row per flag_type with an inline per-severity
    # breakdown. The outer row's severity badge is derived at display time
    # from the canonical FLAG_TYPE_SEVERITY mapping so stale values in
    # flag_entity_stats don't leak into the UI. The breakdown preserves the
    # DB's severity variants for flags that legitimately have more than one
    # (A9_PRICE_ANOMALY, B5_BENFORD_DEVIATION, ...).
    per_severity_rows = FlagEntityStat
      .where(entity_id: @entity.id)
      .group(:flag_type, :severity)
      .select(
        "flag_type",
        "severity",
        "SUM(total_exposure) AS total_exposure",
        "SUM(contract_count) AS contract_count"
      )
      .to_a

    @flag_stats = per_severity_rows
      .group_by(&:flag_type)
      .map { |flag_type, rows| build_flag_stat(flag_type, rows) }
      .sort_by { |s| [ s.flag_type, -s.total_exposure ] }

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
          @flag_stats
            .select { |s| s.flag_type == @flag_filter }
            .sum { |s| s.contract_count.to_i }
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
