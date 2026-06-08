# frozen_string_literal: true

module People
  class IdentityMatchService
    SAME_NIF_SCORE = 100
    EXACT_NAME_CONTEXT_HIGH_SCORE = 80
    EXACT_NAME_CONTEXT_MEDIUM_SCORE = 55
    EXACT_NAME_ONLY_SCORE = 20

    def call
      stats = { processed: 0, upserted: 0 }

      same_nif_pairs.each do |public_role, company_role|
        stats[:processed] += 1
        upsert_match(public_role, company_role, "same_nif", "high", SAME_NIF_SCORE)
        stats[:upserted] += 1
      end

      exact_name_pairs.each do |public_role, company_role|
        next if same_person_nif?(public_role, company_role)

        stats[:processed] += 1
        context_score = contextual_score(public_role, company_role)
        match_type = context_score.positive? ? "exact_name_context" : "exact_name_only"
        confidence = confidence_for(context_score)
        score = score_for(confidence, context_score)
        upsert_match(public_role, company_role, match_type, confidence, score, context_score:)
        stats[:upserted] += 1
      end

      stats
    end

    private

    def same_nif_pairs
      public_roles.filter_map do |public_role|
        nif = public_role.person.tax_identifier.presence
        next unless nif

        company_roles_by_nif.fetch(nif, []).map { |company_role| [ public_role, company_role ] }
      end.flatten(1)
    end

    def exact_name_pairs
      public_roles.flat_map do |public_role|
        key = normalized_name(public_role.name)
        company_roles_by_name.fetch(key, []).map { |company_role| [ public_role, company_role ] }
      end
    end

    def public_roles
      @public_roles ||= EntityPersonRole.active.includes(:person, :entity).where(entities: { is_public_body: true }).joins(:entity).to_a
    end

    def company_roles
      @company_roles ||= EntityPersonRole.active.includes(:person, :entity).where(entities: { is_company: true }).joins(:entity).to_a
    end

    def company_roles_by_nif
      @company_roles_by_nif ||= company_roles.group_by { |role| role.person.tax_identifier.presence }.compact
    end

    def company_roles_by_name
      @company_roles_by_name ||= company_roles.group_by { |role| normalized_name(role.name) }
    end

    def same_person_nif?(public_role, company_role)
      public_role.person.tax_identifier.present? &&
        public_role.person.tax_identifier == company_role.person.tax_identifier
    end

    def contextual_score(public_role, company_role)
      score = 0
      score += 2 if procurement_link?(public_role.entity_id, company_role.entity_id)
      score += 1 if same_locality?(public_role.entity, company_role.entity)
      score += 1 if role_dates_overlap?(public_role, company_role)
      score
    end

    def procurement_link?(public_entity_id, company_entity_id)
      Contract.joins(:contract_winners)
        .where(contracting_entity_id: public_entity_id, contract_winners: { entity_id: company_entity_id })
        .exists?
    end

    def same_locality?(left_entity, right_entity)
      left = left_entity.locality.to_s.strip.downcase
      right = right_entity.locality.to_s.strip.downcase
      left.present? && left == right
    end

    def role_dates_overlap?(public_role, company_role)
      return false if [ public_role.start_date, public_role.end_date, company_role.start_date, company_role.end_date ].all?(&:blank?)

      left_start = public_role.start_date || Date.new(1900, 1, 1)
      left_end = public_role.end_date || Date.new(2999, 12, 31)
      right_start = company_role.start_date || Date.new(1900, 1, 1)
      right_end = company_role.end_date || Date.new(2999, 12, 31)

      left_start <= right_end && right_start <= left_end
    end

    def confidence_for(context_score)
      return "high" if context_score >= 2
      return "medium" if context_score == 1

      "low"
    end

    def score_for(confidence, context_score)
      case confidence
      when "high" then EXACT_NAME_CONTEXT_HIGH_SCORE + context_score
      when "medium" then EXACT_NAME_CONTEXT_MEDIUM_SCORE + context_score
      else EXACT_NAME_ONLY_SCORE
      end
    end

    def upsert_match(public_role, company_role, match_type, confidence, score, context_score: nil)
      left_person_id, right_person_id = ordered_person_ids(public_role.person_id, company_role.person_id)
      match = PersonIdentityMatch.find_or_initialize_by(left_person_id:, right_person_id:, match_type:)
      match.confidence = confidence
      match.score = score
      match.evidence = evidence(public_role, company_role, match_type, confidence, context_score)
      match.review_status = "unreviewed" if match.review_status.blank?
      match.save! if match.new_record? || match.changed?
    end

    def ordered_person_ids(left_id, right_id)
      [ left_id, right_id ].sort
    end

    def evidence(public_role, company_role, match_type, confidence, context_score)
      {
        "rule" => match_type,
        "confidence" => confidence,
        "context_score" => context_score,
        "public_role_id" => public_role.id,
        "company_role_id" => company_role.id,
        "public_entity_id" => public_role.entity_id,
        "company_entity_id" => company_role.entity_id,
        "public_source" => public_role.source_name,
        "company_source" => company_role.source_name,
        "public_source_url" => public_role.source_url,
        "company_source_url" => company_role.source_url
      }.compact
    end

    def normalized_name(name)
      I18n.transliterate(name.to_s).downcase.gsub(/[^a-z ]/, " ").squeeze(" ").strip
    end
  end
end
