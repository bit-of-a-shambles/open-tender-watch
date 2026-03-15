class Entity < ApplicationRecord
  has_many :contracts_as_contracting_entity, class_name: "Contract", foreign_key: "contracting_entity_id"
  has_many :contract_winners
  has_many :contracts_won, through: :contract_winners, source: :contract
  has_many :flag_entity_stats
  has_many :company_directors, dependent: :destroy

  validates :tax_identifier, presence: true,
                             uniqueness: { scope: :country_code }
  validates :name,           presence: true
  validates :country_code,   presence: true
end
