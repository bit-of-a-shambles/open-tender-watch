# frozen_string_literal: true

require "test_helper"

class TokensControllerTest < ActionDispatch::IntegrationTest
  test "new renders access form" do
    get new_access_token_url
    assert_response :success
    assert_includes response.body, I18n.t("tokens.title")
  end

  test "create with valid token sets session and redirects" do
    token = access_tokens(:one)
    post access_token_url, params: { token: token.token }
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "create with valid token records usage" do
    token = access_tokens(:one)
    assert_difference "AccessTokenUsage.count", 1 do
      post access_token_url, params: { token: token.token }
    end
  end

  test "create with invalid token shows alert" do
    post access_token_url, params: { token: "bogus_token_value" }
    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("tokens.invalid")
  end

  test "create with expired token shows alert" do
    token = access_tokens(:expired)
    post access_token_url, params: { token: token.token }
    assert_response :unprocessable_entity
  end

  test "destroy clears session and redirects" do
    # First authenticate
    token = access_tokens(:one)
    post access_token_url, params: { token: token.token }
    assert_redirected_to root_path

    # Then sign out
    delete destroy_access_token_url
    assert_redirected_to root_path
  end
end
