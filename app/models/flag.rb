class Flag < ApplicationRecord
  belongs_to :contract

  enum :severity, {
    low: "low",
    medium: "medium",
    high: "high",
    critical: "critical"
  }, default: "medium"

  # Returns a SQL fragment that maps the max severity across rows to a string.
  # Used by dashboard and entity controllers to aggregate severity from the DB.
  MAX_SEVERITY_CASE = <<~SQL.squish
    CASE MAX(CASE severity WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END)
      WHEN 4 THEN 'critical' WHEN 3 THEN 'high' WHEN 2 THEN 'medium' ELSE 'low' END
  SQL

  def self.max_severity_sql
    MAX_SEVERITY_CASE
  end

  validates :flag_type, presence: true, uniqueness: { scope: :contract_id }
  validates :severity, presence: true
  validates :score, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :fired_at, presence: true
end
