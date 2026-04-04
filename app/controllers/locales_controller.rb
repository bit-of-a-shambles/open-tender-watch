# frozen_string_literal: true

class LocalesController < ApplicationController
  AVAILABLE = %w[en pt].freeze

  def set
    locale = params[:locale]
    session[:locale] = locale if AVAILABLE.include?(locale)

    redirect_back fallback_location: root_path, status: :see_other
  end
end
