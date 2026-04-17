# frozen_string_literal: true

class ContractsController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE = 50
  CSV_LIMIT = 100_000

  SORT_COLUMNS = {
    "date"   => "celebration_date",
    "price"  => "base_price",
    "object" => "object"
  }.freeze

  def index
    scope = build_filtered_scope

    respond_to do |format|
      format.html do
        # HTTP cache: list pages are public, safe to cache in browsers/CDNs.
        # A 304 costs ~2ms vs ~200ms for a full render on the 2M-row table.
        expires_in 2.minutes, public: true,
                   stale_while_revalidate: 30.seconds,
                   stale_if_error:         1.hour

        # Reuse the dashboard cached count for the "all contracts" total shown in
        # the subtitle — avoids an uncached SELECT COUNT(*) FROM contracts on every load.
        @all_count    = Rails.cache.fetch("dashboard/contract_count", expires_in: 10.minutes) { Contract.count }
        @total        = scope.count
        @page         = [ params[:page].to_i, 1 ].max
        @total_pages  = (@total.to_f / PER_PAGE).ceil
        @sort         = SORT_COLUMNS.key?(params[:sort]) ? params[:sort] : "date"
        @direction    = %w[asc desc].include?(params[:direction]) ? params[:direction] : "desc"

        sort_col = SORT_COLUMNS[@sort]
        @contracts = scope.order(Arel.sql("#{sort_col} #{@direction}, contracts.id DESC"))
                          .limit(PER_PAGE).offset((@page - 1) * PER_PAGE)

        # Cache these filter-dropdown values — they change only on import runs
        @procedure_types = Rails.cache.fetch("contracts/procedure_types", expires_in: 10.minutes) { Contract.distinct.pluck(:procedure_type).compact.sort }
        @countries       = Rails.cache.fetch("contracts/countries",       expires_in: 10.minutes) { Contract.distinct.pluck(:country_code).compact.sort }
        @flag_types      = Rails.cache.fetch("contracts/flag_types",      expires_in: 10.minutes) { Flag.distinct.order(:flag_type).pluck(:flag_type) }
        @source_options  = Rails.cache.fetch("contracts/source_options",  expires_in: 10.minutes) { DataSource.order(:name).pluck(:id, :name) }
      end

      format.csv do
        csv_scope = scope
          .includes(:contracting_entity, :winners, :flags)
          .order(Arel.sql("celebration_date DESC, contracts.id DESC"))
          .limit(CSV_LIMIT)

        filename = csv_filename("contracts")
        headers["X-Accel-Buffering"] = "no"

        send_data generate_csv(csv_scope), filename: filename, type: "text/csv; charset=utf-8"
      end

      format.json do
        json_scope = scope
          .includes(:contracting_entity, :winners, :flags)
          .order(Arel.sql("celebration_date DESC, contracts.id DESC"))
          .limit(CSV_LIMIT)

        contracts_json = json_scope.map(&:to_evidence_hash)
        send_data({ contracts: contracts_json, count: contracts_json.size, exported_at: Time.current.iso8601 }.to_json,
                  filename: csv_filename("contracts", ext: "json"), type: "application/json; charset=utf-8")
      end
    end
  end

  def show
    @contract = Contract.includes(:contracting_entity, :winners, :data_source, :flags).find(params[:id])

    respond_to do |format|
      format.html
      format.json do
        send_data @contract.to_evidence_hash.to_json,
                  filename: "contract-#{@contract.external_id}-#{Date.current.iso8601}.json",
                  type: "application/json; charset=utf-8"
      end
    end
  end

  private

  def build_filtered_scope
    # :winners and :data_source are only needed on the show page / exports.
    # Loading them for 50 list rows adds 2 unnecessary batch queries every request.
    scope = Contract.includes(:contracting_entity, :flags)
    @selected_source_ids = Array(params[:source_ids]).reject(&:blank?).map(&:to_i).uniq

    # Require at least 3 characters to avoid leading-wildcard full-table scans
    # on a 2 million-row table for every keystroke.
    if params[:q].present? && params[:q].length >= 3
      scope = scope.where("object LIKE ?", "%#{params[:q]}%")
    end

    if params[:procedure_type].present?
      scope = scope.where(procedure_type: params[:procedure_type])
    end

    if params[:country].present?
      scope = scope.where(country_code: params[:country])
    end

    if @selected_source_ids.any?
      scope = scope.where(data_source_id: @selected_source_ids)
    end

    # flag_type implies "flagged only" — handle it first to avoid a redundant
    # second joins(:flags).distinct when both flag_type and flagged=only are set.
    if params[:flag_type].present?
      scope = scope.joins(:flags).where(flags: { flag_type: params[:flag_type] }).distinct
    elsif params[:flagged] == "only"
      scope = scope.joins(:flags).distinct
    elsif params[:flagged] == "none"
      scope = scope.left_outer_joins(:flags).where(flags: { id: nil })
    end

    if params[:date_from].present?
      scope = scope.where("publication_date >= ?", params[:date_from])
    end

    if params[:date_to].present?
      scope = scope.where("publication_date <= ?", params[:date_to])
    end

    scope
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

  def csv_filename(prefix, ext: "csv")
    parts = [ prefix ]
    parts << "flagged-#{params[:flag_type].downcase}" if params[:flag_type].present?
    parts << "flagged" if params[:flagged] == "only" && params[:flag_type].blank?
    parts << params[:country].downcase if params[:country].present?
    parts << Date.current.iso8601
    "open-tender-watch-#{parts.join('-')}.#{ext}"
  end
end
