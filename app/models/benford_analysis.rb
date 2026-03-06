# frozen_string_literal: true

# Stores per-entity Benford's Law analysis results.
#
# Populated by Flags::Actions::BenfordLawAction. One row per entity that has
# enough contracts (>= BenfordLawAction::MIN_SAMPLE) to run the chi-square test.
#
# Non-anomalous entities are stored here too (flagged: false) so their digit
# distributions are available for comparison visualizations.
#
# digit_distribution: { "1" => count, "2" => count, … "9" => count }
class BenfordAnalysis < ApplicationRecord
  belongs_to :entity
  belongs_to :representative_contract, class_name: "Contract", optional: true

  validates :sample_size,         presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :chi_square,          presence: true, numericality: true
  validates :flagged,             inclusion: { in: [ true, false ] }
  validates :digit_distribution,  presence: true
  validates :computed_at,         presence: true
end
