# frozen_string_literal: true

class TokensController < ApplicationController
  def new
  end

  def create
    token_str = params[:token].to_s.strip
    access_token = AccessToken.active.find_by(token: token_str)

    if access_token
      session[:access_token_id] = access_token.id
      access_token.record_usage!(path: "/access", ip_address: request.remote_ip)
      redirect_to root_path, notice: t("tokens.success")
    else
      flash.now[:alert] = t("tokens.invalid")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:access_token_id)
    redirect_to root_path, notice: t("tokens.signed_out")
  end
end
