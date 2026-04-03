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
end
