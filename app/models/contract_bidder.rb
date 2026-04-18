class ContractBidder < ApplicationRecord
  belongs_to :contract
  belongs_to :entity, optional: true

  validates :raw_label, presence: true, uniqueness: { scope: :contract_id }
end