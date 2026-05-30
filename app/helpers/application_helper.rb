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
    "A1_REPEAT_DIRECT_AWARD"           => "high",    # OECD bid rigging; TI: HIGH
    "A2_PUBLICATION_AFTER_CELEBRATION" => "low",      # TI/OLAF: process compliance failure; LOW
    "A5_THRESHOLD_SPLITTING"           => "high",    # TI/OLAF/ECA: deliberate circumvention; HIGH
    "A6_LOW_COMPETITION"               => "medium",  # single-bidder award; OECD bid-rigging indicator
    "A7_ABNORMAL_DIRECT_AWARD_RATE"    => "high",    # DIGIWHIST: strongest corruption predictor; HIGH
    "A9_PRICE_ANOMALY"                 => "high",    # OECD: price manipulation; worst case HIGH
    "A9_PRICE_REDUCTION"               => "low",
    "B2_SUPPLIER_CONCENTRATION"        => "high",    # OECD: market concentration = bid rigging risk
    "B3_PRICE_HIGH"                    => "high",    # worst case (z≥3.5)
    "B3_PRICE_LOW"                     => "high",    # worst case
    "B5_BENFORD_DEVIATION"             => "medium",  # DIGIWHIST/Nigrini: supporting indicator only
    "C1_MISSING_WINNER_NIF"            => "medium",  # OLAF: traceability failure; MEDIUM
    "C3_MISSING_MANDATORY_FIELDS"      => "low"      # OLAF: compliance failure; LOW
  }.freeze

  def flag_type_severity(flag_type)
    FLAG_TYPE_SEVERITY.fetch(flag_type.to_s, "medium")
  end

  SEVERITY_STYLES = {
    "critical" => { dot: "bg-[#ff0000]", text: "text-[#ff0000]", bg: "bg-[#ff000015]", border: "border-[#ff000033]" },
    "high"     => { dot: "bg-[#ff4444]", text: "text-[#ff4444]", bg: "bg-[#ff444412]", border: "border-[#ff444433]" },
    "medium"   => { dot: "bg-[#ff8844]", text: "text-[#ff8844]", bg: "bg-[#ff884412]", border: "border-[#ff884433]" },
    "low"      => { dot: "bg-[#c8a84e]", text: "text-[#c8a84e]", bg: "bg-[#c8a84e12]", border: "border-[#c8a84e33]" }
  }.freeze

  SEVERITY_ORDER = { "critical" => 0, "high" => 1, "medium" => 2, "low" => 3 }.freeze

  def severity_rank(severity)
    SEVERITY_ORDER.fetch(severity.to_s, 99)
  end

  def severity_styles(severity)
    SEVERITY_STYLES.fetch(severity.to_s, SEVERITY_STYLES["medium"])
  end

  # Renders a clickable table-header sort link for Turbo Frame navigation.
  # +url+ must already include the correct sort column and next direction.
  def sort_header_link(label, column:, url:, sort_col:, sort_dir:, align_right: false)
    active = sort_col == column
    arrow  = active ? (sort_dir == "asc" ? " ↑" : " ↓") : ""
    css    = "hover:text-[#c8a84e] transition-colors"
    css   += " text-[#c8a84e]" if active
    css   += " text-right" if align_right
    link_to("#{h(label)}#{arrow}".html_safe, url, class: css)
  end

  def next_sort_dir(column, sort_col, sort_dir)
    (sort_col == column && sort_dir == "desc") ? "asc" : "desc"
  end

  def global_nav_items
    [
      { key: :dashboard, path: root_path, label: t("nav.dashboard") },
      { key: :contracts, path: contracts_path, label: t("nav.contracts") },
      { key: :entities, path: entities_path, label: t("nav.entities") },
      { key: :companies, path: companies_path, label: t("nav.companies") },
      { key: :graph, path: graph_path, label: t("nav.graph") },
      { key: :investigations, path: investigations_path, label: t("nav.investigations") }
    ]
  end

  def global_nav_active?(key)
    path = request.path

    case key.to_sym
    when :dashboard
      path == root_path || path.start_with?("/dashboard")
    when :contracts
      path.start_with?("/contracts")
    when :entities
      path.start_with?("/entities")
    when :companies
      path.start_with?("/companies")
    when :graph
      path.start_with?("/graph") || path.start_with?("/api/graph")
    when :investigations
      path.start_with?("/investigations")
    else
      false
    end
  end

  def global_nav_link_classes(active)
    base = "font-mono text-[11px] tracking-[2px] uppercase px-3 py-2 rounded border transition-colors whitespace-nowrap"
    return "#{base} border-[#c8a84e55] bg-[#c8a84e12] text-[#c8a84e]" if active

    "#{base} border-white/8 bg-white/[0.02] text-white/45 hover:text-[#e8e0d4] hover:border-white/20"
  end
end
