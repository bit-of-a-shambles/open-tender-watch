# frozen_string_literal: true

module PeopleDisplayHelper
  # Display a person's name — pseudonymised for public, full for journalists/auditors
  def display_person_name(role)
    if journalist_access?
      role.name
    else
      pseudonymised_name(role)
    end
  end

  # Display a person's NIF — hidden for public, visible for journalists/auditors
  def display_person_nif(role)
    if journalist_access?
      role.tax_identifier
    end
  end

  private

  # Generate deterministic pseudonym: initials + stable short ID
  # e.g. "J.S. [P-a3f2]"
  def pseudonymised_name(role)
    initials = role.name.split(/\s+/).filter_map { |w|
      w[0]&.upcase if w.length > 1
    }.first(2).join(".")
    initials = "?" if initials.blank?

    pid = pseudonym_id(role)
    "#{initials}. [P-#{pid}]"
  end

  # HMAC-SHA256 deterministic ID — works with both EntityPersonRole and CompanyDirector
  def pseudonym_id(role)
    secret = Rails.application.secret_key_base
    if role.respond_to?(:person) && role.person
      OpenSSL::HMAC.hexdigest("SHA256", secret, "person-#{role.person.id}")[0, 4]
    else
      OpenSSL::HMAC.hexdigest("SHA256", secret, "director-#{role.id}")[0, 4]
    end
  end
end
