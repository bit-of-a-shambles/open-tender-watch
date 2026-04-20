# frozen_string_literal: true

require "test_helper"

class AccessTokenUsageTest < ActiveSupport::TestCase
  test "valid with access_token and path" do
    usage = AccessTokenUsage.new(access_token: access_tokens(:one), path: "/test")
    assert usage.valid?
  end

  test "invalid without path" do
    usage = AccessTokenUsage.new(access_token: access_tokens(:one))
    assert_not usage.valid?
    assert usage.errors.added?(:path, :blank)
  end

  test "belongs to access_token" do
    usage = access_token_usages(:one)
    assert_equal access_tokens(:one), usage.access_token
  end
end
