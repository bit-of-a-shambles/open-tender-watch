# frozen_string_literal: true

require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "privacy page renders successfully" do
    get privacy_url
    assert_response :success
    assert_includes response.body, I18n.t("privacy.title")
  end
end
