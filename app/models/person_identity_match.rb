# frozen_string_literal: true

class PersonIdentityMatch < ApplicationRecord
  MATCH_TYPES = %w[
    same_nif
    exact_name_context
    exact_name_only
  ].freeze

  CONFIDENCES = %w[
    low
    medium
    high
  ].freeze

  REVIEW_STATUSES = %w[
    unreviewed
    confirmed
    rejected
  ].freeze

  belongs_to :left_person, class_name: "Person"
  belongs_to :right_person, class_name: "Person"

  scope :actionable, -> { where(review_status: %w[unreviewed confirmed], confidence: "high") }

  validates :match_type, presence: true, inclusion: { in: MATCH_TYPES }
  validates :confidence, presence: true, inclusion: { in: CONFIDENCES }
  validates :review_status, presence: true, inclusion: { in: REVIEW_STATUSES }
  validates :score, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
