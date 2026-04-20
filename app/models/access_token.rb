# frozen_string_literal: true

class AccessToken < ApplicationRecord
  ACCESS_LEVELS = %w[journalist auditor].freeze

  has_many :access_token_usages, dependent: :destroy

  validates :token, presence: true, uniqueness: true
  validates :name, presence: true
  validates :access_level, presence: true, inclusion: { in: ACCESS_LEVELS }

  before_validation :generate_token, on: :create

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def active?
    !expired?
  end

  def record_usage!(path:, ip_address:)
    increment!(:usage_count)
    update_column(:last_used_at, Time.current)
    access_token_usages.create!(path: path, ip_address: ip_address)
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
