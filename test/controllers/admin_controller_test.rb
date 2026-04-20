# frozen_string_literal: true

require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ADMIN_PASSWORD"] = "test_admin_pw_123"
  end

  teardown do
    ENV.delete("ADMIN_PASSWORD")
  end

  test "index requires authentication" do
    get admin_url
    assert_response :unauthorized
  end

  test "index with wrong password returns unauthorized" do
    get admin_url, headers: { "HTTP_AUTHORIZATION" => basic_auth("admin", "wrong") }
    assert_response :unauthorized
  end

  test "index with correct password renders" do
    get admin_url, headers: { "HTTP_AUTHORIZATION" => basic_auth("admin", "test_admin_pw_123") }
    assert_response :success
    assert_includes response.body, I18n.t("admin.title")
  end

  test "tokens page renders with auth" do
    get admin_tokens_url, headers: { "HTTP_AUTHORIZATION" => basic_auth("admin", "test_admin_pw_123") }
    assert_response :success
    assert_includes response.body, access_tokens(:one).name
  end

  test "token detail renders with auth" do
    get admin_token_detail_url(access_tokens(:one)),
        headers: { "HTTP_AUTHORIZATION" => basic_auth("admin", "test_admin_pw_123") }
    assert_response :success
    assert_includes response.body, access_tokens(:one).name
    assert_includes response.body, access_tokens(:one).token
  end

  test "returns 503 when ADMIN_PASSWORD not set" do
    ENV.delete("ADMIN_PASSWORD")
    get admin_url
    assert_response :service_unavailable
  end

  private

  def basic_auth(user, password)
    ActionController::HttpAuthentication::Basic.encode_credentials(user, password)
  end
end
