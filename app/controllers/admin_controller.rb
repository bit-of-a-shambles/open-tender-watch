# frozen_string_literal: true

class AdminController < ApplicationController
  before_action :authenticate_admin!

  def index
    @total_tokens = AccessToken.count
    @active_tokens = AccessToken.active.count
    @total_usages = AccessTokenUsage.count
    @recent_usages = AccessTokenUsage.includes(:access_token)
                                     .order(created_at: :desc)
                                     .limit(50)
  end

  def tokens
    @tokens = AccessToken.order(last_used_at: :desc, created_at: :desc)
  end

  def token_detail
    @token = AccessToken.find(params[:id])
    @usages = @token.access_token_usages.order(created_at: :desc).limit(100)
  end

  private

  def authenticate_admin!
    admin_password = ENV["ADMIN_PASSWORD"]
    unless admin_password.present?
      render plain: "ADMIN_PASSWORD not configured", status: :service_unavailable
      return
    end

    authenticate_or_request_with_http_basic("Admin") do |_user, password|
      ActiveSupport::SecurityUtils.secure_compare(password, admin_password)
    end
  end
end
