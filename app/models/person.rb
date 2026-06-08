# frozen_string_literal: true

class Person < ApplicationRecord
  has_many :entity_person_roles, dependent: :destroy
  has_many :entities, through: :entity_person_roles
  has_many :left_identity_matches, class_name: "PersonIdentityMatch", foreign_key: "left_person_id", dependent: :destroy
  has_many :right_identity_matches, class_name: "PersonIdentityMatch", foreign_key: "right_person_id", dependent: :destroy

  validates :name, presence: true
  validates :country_code, presence: true
  validates :tax_identifier, uniqueness: { scope: :country_code }, allow_blank: true
end
