# frozen_string_literal: true

# Companies are private entities that appear as contract winners (adjudicatários).
# This controller provides a company-centric view: who they are, what contracts
# they have won, and what risk flags are attached to those contracts.
class CompaniesController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE       = 50
  PIVOT_PER_PAGE = 20
  SORT_COLS      = %w[name won_value won_count].freeze
  CONTRACT_SORT_COLS = %w[celebration_date base_price object].freeze

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

    # Join contract_winners → contracts to compute won value and won count.
    # LEFT JOIN so companies with no won contracts still appear (won_value = 0).
    # GROUP BY entities.id; SQLite supports ORDER BY computed aliases.
    @companies = entity_scope
      .joins("LEFT JOIN contract_winners cw ON cw.entity_id = entities.id")
      .joins("LEFT JOIN contracts c ON c.id = cw.contract_id")
      .group("entities.id")
      .select(
        "entities.*",
        "COUNT(DISTINCT cw.id)       AS won_count",
        "COALESCE(SUM(c.base_price), 0) AS won_value",
        # High-severity flag indicator — 1 if any won contract carries a high flag
        "CASE WHEN EXISTS (
           SELECT 1 FROM flags f2
           JOIN contract_winners cw2 ON cw2.contract_id = f2.contract_id
           WHERE cw2.entity_id = entities.id AND f2.severity = 'high'
         ) THEN 1 ELSE 0 END AS has_high_flag"
      )
      .order(Arel.sql("#{@sort_col} #{@sort_dir}"))
      .limit(PER_PAGE)
      .offset((@page - 1) * PER_PAGE)
  end

  def show
    @entity = Entity.find(params[:id])

    # Total won value and contract count (unfiltered)
    @total_won_value  = @entity.contracts_won.sum(:base_price)
    @entity_won_total = @entity.contracts_won.count

    # Flag stats across all won contracts
    won_contract_ids = ContractWinner.where(entity_id: @entity.id).select(:contract_id)
    @flag_stats = Flag
      .where(contract_id: won_contract_ids)
      .group(:flag_type, :severity)
      .select("flag_type, severity, COUNT(*) AS contract_count")
      .order("contract_count DESC")

    @flag_types  = @flag_stats.map(&:flag_type).uniq
    @flag_filter = params[:flag_type].presence

    base_scope = @entity.contracts_won

    if @flag_filter.present?
      base_scope = base_scope.where(
        "contracts.id IN (SELECT contract_id FROM flags WHERE flag_type = ?)",
        @flag_filter
      )
    end

    @date_from = params[:date_from].presence
    @date_to   = params[:date_to].presence
    base_scope = base_scope.where("contracts.publication_date >= ?", @date_from) if @date_from.present?
    base_scope = base_scope.where("contracts.publication_date <= ?", @date_to)   if @date_to.present?

    @sort_col = CONTRACT_SORT_COLS.include?(params[:sort]) ? params[:sort] : "celebration_date"
    @sort_dir = params[:dir] == "asc" ? "asc" : "desc"

    @total       = base_scope.count
    @page        = [ params[:page].to_i, 1 ].max
    @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max

    order_sql = "#{Contract.table_name}.#{@sort_col} #{@sort_dir}, #{Contract.table_name}.id #{@sort_dir}"

    @contracts = base_scope
      .preload(:contracting_entity, :data_source, :flags)
      .order(Arel.sql(order_sql))
      .limit(PER_PAGE)
      .offset((@page - 1) * PER_PAGE)

    @benford_analysis = BenfordAnalysis.find_by(entity_id: @entity.id)

    # Directors & officers
    @directors = @entity.company_directors.order(:role, :name)

    # Pivot: contracts grouped by contracting authority
    @pivot_page = [ params[:pivot_page].to_i, 1 ].max

    pivot_base = ContractWinner
      .joins(:contract)
      .joins("LEFT JOIN entities auth ON auth.id = contracts.contracting_entity_id")
      .where(entity_id: @entity.id)
      .group("contracts.contracting_entity_id", "auth.name", "auth.tax_identifier", "auth.id")

    # Count distinct groups separately (no custom select so ActiveRecord can generate valid SQL)
    @pivot_total       = pivot_base.count.size
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
      .order(Arel.sql("total_value DESC"))
      .limit(PIVOT_PER_PAGE)
      .offset((@pivot_page - 1) * PIVOT_PER_PAGE)
  end
end
