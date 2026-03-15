# frozen_string_literal: true

# Represents a director, officer, or administrator of a private company (Entity).
# Tax identifiers are stored as strings to preserve leading zeros.
class CompanyDirector < ApplicationRecord
  belongs_to :entity

  validates :name, presence: true
  validates :country_code, presence: true
end
