# frozen_string_literal: true

class InvestigationsController < ApplicationController
  TOP_PER_LEAD_TYPE_LIMIT = 20

  before_action :require_journalist_access!
  before_action :set_entity, only: [ :show ]

  def index
    @severity_filter = normalized_severity(params[:severity])
    @lead_type_filter = normalized_lead_type(params[:lead_type])

    if @lead_type_filter.present?
      load_filtered_leads
    else
      load_top_leads_by_type
    end
  end

  def show
    @report = Investigations::CaseReportService.new(entity: @entity).call
    @data_sources = DataSource.order(:name)
  end

  private

  def set_entity
    @entity = Entity.find(params[:id])
  end

  def require_journalist_access!
    return if journalist_access?

    redirect_to new_access_token_path, alert: t("investigations.access_required")
  end

  def normalized_severity(value)
    return nil if value.blank?

    normalized = value.to_s
    Flag.severities.key?(normalized) ? normalized : nil
  end

  def normalized_lead_type(value)
    return nil if value.blank?

    normalized = value.to_s
    Investigations::LeadBuilderService::ALLOWED_LEAD_TYPES.include?(normalized) ? normalized : nil
  end

  def load_filtered_leads
    result = Investigations::LeadBuilderService.new(
      severity: @severity_filter,
      lead_type: @lead_type_filter,
      limit: params[:limit]
    ).call

    @leads = result[:leads]
    @meta = result[:meta]
    @grouped_leads = {}
  end

  def load_top_leads_by_type
    @grouped_leads = Investigations::LeadBuilderService::ALLOWED_LEAD_TYPES.each_with_object({}) do |lead_type, grouped|
      result = Investigations::LeadBuilderService.new(
        severity: @severity_filter,
        lead_type: lead_type,
        limit: TOP_PER_LEAD_TYPE_LIMIT
      ).call
      grouped[lead_type] = result[:leads]
    end

    @leads = @grouped_leads.values.flatten
    @meta = {
      filters: {
        severity: @severity_filter,
        lead_type: nil
      },
      limit: TOP_PER_LEAD_TYPE_LIMIT,
      candidate_count: @leads.size,
      grouped: true,
      groups_with_results: @grouped_leads.values.count(&:present?)
    }
  end
end
