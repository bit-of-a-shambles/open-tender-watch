# frozen_string_literal: true

class EntityPersonRole < ApplicationRecord
  ROLE_TYPES = %w[
    director
    officer
    manager
    administrator
    president
    partner_shareholder
    unknown
  ].freeze

  ROLE_PRIORITY = {
    "president" => 0,
    "director" => 1,
    "administrator" => 2,
    "manager" => 3,
    "officer" => 4,
    "partner_shareholder" => 5,
    "unknown" => 6
  }.freeze

  belongs_to :entity
  belongs_to :person

  scope :active, -> { where(active: true) }

  validates :role_type, presence: true, inclusion: { in: ROLE_TYPES }
  validates :source_name, presence: true

  delegate :name, :tax_identifier, :country_code, to: :person

  def role
    role_label.presence || role_type.humanize
  end

  def sort_priority
    ROLE_PRIORITY.fetch(role_type, ROLE_PRIORITY["unknown"])
  end
end