module ApplicationHelper
  # Translates a raw FLAG_TYPE constant (e.g. "A2_PUBLICATION_AFTER_CELEBRATION")
  # into a prefixed human-readable label (e.g. "A2 · Late Publication").
  # Falls back to a humanised version of the suffix when no translation key exists.
  def flag_type_label(flag_type)
    code = flag_type.to_s.split("_").first  # e.g. "A2", "B3"
    key = "flags.types.#{flag_type.to_s.downcase}"
    fallback = flag_type.to_s.sub(/\A[A-Z]\d_/, "").tr("_", " ").strip.titleize
    label = t(key, default: fallback)
    "#{code} · #{label}"
  end

  # Returns the canonical severity for a given flag_type.
  # Fixed-severity types map directly; variable-severity types use the worst-case level.
  FLAG_TYPE_SEVERITY = {
    "A1_REPEAT_DIRECT_AWARD"         => "high",
    "A2_PUBLICATION_AFTER_CELEBRATION" => "high",
    "A5_THRESHOLD_SPLITTING"         => "medium",
    "A7_ABNORMAL_DIRECT_AWARD_RATE"  => "medium",
    "A9_PRICE_ANOMALY"               => "high",    # medium or high; show worst case
    "A9_PRICE_REDUCTION"             => "low",
    "B2_SUPPLIER_CONCENTRATION"      => "high",
    "B3_PRICE_HIGH"                  => "high",    # medium or high
    "B3_PRICE_LOW"                   => "high",    # medium or high
    "B5_BENFORD_DEVIATION"           => "high",    # medium or high
    "C1_MISSING_WINNER_NIF"          => "medium",
    "C3_MISSING_MANDATORY_FIELDS"    => "low",
  }.freeze

  def flag_type_severity(flag_type)
    FLAG_TYPE_SEVERITY.fetch(flag_type.to_s, "medium")
  end

  SEVERITY_STYLES = {
    "critical" => { dot: "bg-[#ff0000]", text: "text-[#ff0000]", bg: "bg-[#ff000015]", border: "border-[#ff000033]" },
    "high"     => { dot: "bg-[#ff4444]", text: "text-[#ff4444]", bg: "bg-[#ff444412]", border: "border-[#ff444433]" },
    "medium"   => { dot: "bg-[#ff8844]", text: "text-[#ff8844]", bg: "bg-[#ff884412]", border: "border-[#ff884433]" },
    "low"      => { dot: "bg-[#c8a84e]", text: "text-[#c8a84e]", bg: "bg-[#c8a84e12]", border: "border-[#c8a84e33]" },
  }.freeze

  def severity_styles(severity)
    SEVERITY_STYLES.fetch(severity.to_s, SEVERITY_STYLES["medium"])
  end
end
