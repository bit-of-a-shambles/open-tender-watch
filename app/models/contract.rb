class Contract < ApplicationRecord
  belongs_to :contracting_entity, class_name: "Entity"
  belongs_to :data_source, optional: true
  has_many :contract_bidders, dependent: :destroy
  has_many :contract_winners, dependent: :destroy
  has_many :bidders, through: :contract_bidders, source: :entity
  has_many :winners, through: :contract_winners, source: :entity
  has_many :flags, dependent: :destroy

  validates :external_id, presence: true, uniqueness: { scope: :country_code }
  validates :object,       presence: true

  CSV_COLUMNS = %w[
    external_id country_code object procedure_type contract_type cpv_code
    base_price total_effective_price publication_date celebration_date
    location bidder_count bidder_names bidder_nifs contracting_entity_name contracting_entity_nif
    winner_names winner_nifs flag_types max_severity risk_score
  ].freeze

  def to_csv_row
    [
      external_id,
      country_code,
      object,
      procedure_type,
      contract_type,
      cpv_code,
      base_price&.to_f,
      total_effective_price&.to_f,
      publication_date&.iso8601,
      celebration_date&.iso8601,
      location,
      bidder_count,
      bidders.map(&:name).join("; "),
      bidders.map(&:tax_identifier).join("; "),
      contracting_entity&.name,
      contracting_entity&.tax_identifier,
      winners.map(&:name).join("; "),
      winners.map(&:tax_identifier).join("; "),
      flags.map(&:flag_type).join("; "),
      flags.map(&:severity).max_by { |s| %w[low medium high critical].index(s) || 0 },
      flags.sum(&:score)
    ]
  end

  def to_evidence_hash
    {
      id: id,
      external_id: external_id,
      country_code: country_code,
      object: object,
      procedure_type: procedure_type,
      contract_type: contract_type,
      cpv_code: cpv_code,
      base_price: base_price&.to_f,
      total_effective_price: total_effective_price&.to_f,
      publication_date: publication_date&.iso8601,
      celebration_date: celebration_date&.iso8601,
      location: location,
      bidder_count: bidder_count,
      contracting_entity: {
        name: contracting_entity.name,
        tax_identifier: contracting_entity.tax_identifier,
        country_code: contracting_entity.country_code,
        is_public_body: contracting_entity.is_public_body
      },
      bidders: contract_bidders.map { |bidder|
        {
          raw_label: bidder.raw_label,
          name: bidder.entity&.name,
          tax_identifier: bidder.entity&.tax_identifier,
          is_company: bidder.entity&.is_company
        }
      },
      winners: winners.map { |w|
        {
          name: w.name,
          tax_identifier: w.tax_identifier,
          is_company: w.is_company
        }
      },
      flags: flags.sort_by { |f| -f.score }.map { |f|
        {
          flag_type: f.flag_type,
          severity: f.severity,
          score: f.score,
          details: f.details,
          fired_at: f.fired_at&.iso8601
        }
      },
      risk_score: flags.sum(&:score),
      data_source: data_source ? {
        name: data_source.name,
        source_type: data_source.source_type,
        last_synced_at: data_source.last_synced_at&.iso8601
      } : nil,
      exported_at: Time.current.iso8601
    }
  end
end
