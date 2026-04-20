class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_locale
  before_action :log_token_usage

  helper_method :current_access_level, :current_access_token, :journalist_access?

  private

  def set_locale
    I18n.locale = session[:locale].presence&.to_sym || I18n.default_locale
  end

  def current_access_token
    return @current_access_token if defined?(@current_access_token)
    @current_access_token = if session[:access_token_id]
      AccessToken.active.find_by(id: session[:access_token_id])
    end
  end

  def current_access_level
    current_access_token&.access_level || "public"
  end

  def journalist_access?
    current_access_level != "public"
  end

  def log_token_usage
    return unless current_access_token
    return unless request.get? && request.path != "/access"
    current_access_token.record_usage!(path: request.path, ip_address: request.remote_ip)
  end
end
