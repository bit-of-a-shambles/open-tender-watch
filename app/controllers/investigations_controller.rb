# frozen_string_literal: true

class InvestigationsController < ApplicationController
  before_action :require_journalist_access!
  before_action :set_entity, only: [ :show ]

  def index
    @severity_filter = normalized_severity(params[:severity])
    @lead_type_filter = normalized_lead_type(params[:lead_type])

    result = Investigations::LeadBuilderService.new(
      severity: @severity_filter,
      lead_type: @lead_type_filter,
      limit: params[:limit]
    ).call

    @leads = result[:leads]
    @meta = result[:meta]
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
end
