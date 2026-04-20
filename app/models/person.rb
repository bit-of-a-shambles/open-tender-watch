# frozen_string_literal: true

class Person < ApplicationRecord
  has_many :entity_person_roles, dependent: :destroy
  has_many :entities, through: :entity_person_roles

  validates :name, presence: true
  validates :country_code, presence: true
  validates :tax_identifier, uniqueness: { scope: :country_code }, allow_blank: true
end
