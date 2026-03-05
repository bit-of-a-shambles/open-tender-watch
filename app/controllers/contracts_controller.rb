# frozen_string_literal: true

class ContractsController < ApplicationController
  include ActionView::Helpers::NumberHelper

  PER_PAGE = 50

  def index
    scope = Contract.includes(:contracting_entity, :winners, :data_source, :flags)
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

    # Reuse the dashboard cached count for the "all contracts" total shown in
    # the subtitle — avoids an uncached SELECT COUNT(*) FROM contracts on every load.
    @all_count    = Rails.cache.fetch("dashboard/contract_count", expires_in: 10.minutes) { Contract.count }
    @total        = scope.count
    @page         = [ params[:page].to_i, 1 ].max
    @total_pages  = (@total.to_f / PER_PAGE).ceil
    @contracts    = scope.order(celebration_date: :desc, id: :desc)
                         .limit(PER_PAGE).offset((@page - 1) * PER_PAGE)

    # Cache these filter-dropdown values — they change only on import runs
    @procedure_types = Rails.cache.fetch("contracts/procedure_types", expires_in: 10.minutes) { Contract.distinct.pluck(:procedure_type).compact.sort }
    @countries       = Rails.cache.fetch("contracts/countries",       expires_in: 10.minutes) { Contract.distinct.pluck(:country_code).compact.sort }
    @flag_types      = Rails.cache.fetch("contracts/flag_types",      expires_in: 10.minutes) { Flag.distinct.order(:flag_type).pluck(:flag_type) }
    @source_options  = Rails.cache.fetch("contracts/source_options",  expires_in: 10.minutes) { DataSource.order(:name).pluck(:id, :name) }
  end

  def show
    @contract = Contract.includes(:contracting_entity, :winners, :data_source, :flags).find(params[:id])
  end
end
