# frozen_string_literal: true

require "test_helper"

class AccessTokenTest < ActiveSupport::TestCase
  test "valid with name and access_level" do
    token = AccessToken.new(name: "Test", access_level: "journalist")
    assert token.valid?
  end

  test "generates token before validation" do
    token = AccessToken.new(name: "Test", access_level: "journalist")
    token.valid?
    assert token.token.present?
    assert token.token.length >= 32
  end

  test "does not overwrite existing token" do
    token = AccessToken.new(name: "Test", access_level: "journalist", token: "custom_token_value")
    token.valid?
    assert_equal "custom_token_value", token.token
  end

  test "invalid without name" do
    token = AccessToken.new(access_level: "journalist")
    assert_not token.valid?
    assert token.errors.added?(:name, :blank)
  end

  test "invalid with bad access_level" do
    token = AccessToken.new(name: "Test", access_level: "admin")
    assert_not token.valid?
    assert token.errors.added?(:access_level, :inclusion, value: "admin")
  end

  test "token must be unique" do
    existing = access_tokens(:one)
    dup = AccessToken.new(name: "Dup", access_level: "journalist", token: existing.token)
    assert_not dup.valid?
    assert_includes dup.errors.details[:token].map { |e| e[:error] }, :taken
  end

  test "active scope excludes expired tokens" do
    active_ids = AccessToken.active.pluck(:id)
    assert_includes active_ids, access_tokens(:one).id
    assert_includes active_ids, access_tokens(:two).id
    assert_not_includes active_ids, access_tokens(:expired).id
  end

  test "expired? returns true for expired token" do
    assert access_tokens(:expired).expired?
  end

  test "expired? returns false for active token" do
    assert_not access_tokens(:one).expired?
  end

  test "expired? returns false for token without expiry" do
    assert_not access_tokens(:one).expired?
    assert_nil access_tokens(:one).expires_at
  end

  test "active? returns true for non-expired token" do
    assert access_tokens(:one).active?
  end

  test "active? returns false for expired token" do
    assert_not access_tokens(:expired).active?
  end

  test "record_usage! increments usage_count and updates last_used_at" do
    token = access_tokens(:one)
    assert_equal 0, token.usage_count
    assert_nil token.last_used_at

    token.record_usage!(path: "/test/usage", ip_address: "1.2.3.4")
    token.reload

    assert_equal 1, token.usage_count
    assert_not_nil token.last_used_at
    assert_equal 1, token.access_token_usages.where(path: "/test/usage").count
  end

  test "record_usage! creates AccessTokenUsage record" do
    token = access_tokens(:one)
    assert_difference "AccessTokenUsage.count", 1 do
      token.record_usage!(path: "/test", ip_address: "10.0.0.1")
    end

    usage = token.access_token_usages.last
    assert_equal "/test", usage.path
    assert_equal "10.0.0.1", usage.ip_address
  end

  test "has many access_token_usages" do
    assert_respond_to access_tokens(:one), :access_token_usages
  end
end
