# Public-Official Conflict-Link System

## Summary

Build a conservative v1 that links Portuguese public-officeholder roles to supplier/company roles for conflict-of-interest triage. The system must not accuse or infer nepotism automatically. It will ingest public-officeholder names/roles, create candidate identity matches, and only flag contracts when evidence reaches a defensible confidence threshold.

## Key Changes

- Add a public-officeholder ingestion layer using existing `Person` and `EntityPersonRole`.
  - Primary source: DRE appointment acts.
  - Enrichment source: Entidade Transparência declarations where accessible.
  - SIOE/public-entity registries are used to normalize public-body `Entity` records, not as the main person source.
- Add a `person_identity_matches` review layer.
  - Stores candidate links between two `Person` records without merging them.
  - Fields: left/right person, match type, confidence, score, evidence JSON, source names/URLs, review status.
  - Never auto-merge people on name-only evidence.
- Add a new flag action: `C7_POTENTIAL_CONFLICT_OF_INTEREST`.
  - Flags contracts where the contracting public body has an active officeholder who matches an active supplier director/officer/shareholder.
  - High-confidence automatic flags only:
    - same NIF, when available; or
    - exact normalized full name plus strong context, such as same municipality/entity geography, overlapping dates, and source-backed role evidence.
  - Low-confidence name-only matches are stored for review but do not create contract flags.
- Extend privacy behavior.
  - Public users see aggregate/pseudonymised individual links only.
  - Journalist/auditor token users can see names, NIFs where available, source links, and match evidence.
  - UI copy should say "potential conflict of interest" or "shared individual link," not "nepotism."

## Implementation Details

- Create source services under a public-officials namespace, separate from procurement adapters.
  - `PublicOfficials::PT::DreClient`: fetch/search appointment acts and return normalized role hashes.
  - `PublicOfficials::PT::RoleImportService`: upsert people and `EntityPersonRole` records.
  - `PublicOfficials::PT::EntidadeTransparenciaClient`: optional enrichment for declared interests and source links.
- Normalized public-official role shape:
  - `person_name`
  - `person_tax_identifier`, optional
  - `public_entity_tax_identifier`, optional but preferred
  - `public_entity_name`
  - `role_type`
  - `role_label`
  - `start_date`
  - `end_date`
  - `source_name`
  - `source_url`
  - `source_publication_date`
- Add `PersonIdentityMatch` model.
  - Confidence values: `low`, `medium`, `high`, `confirmed`, `rejected`.
  - Review statuses: `unreviewed`, `confirmed`, `rejected`.
  - Matching service creates candidates from public-body roles vs supplier/company roles.
  - Exact NIF match creates `high`.
  - Exact normalized full-name plus context creates `medium` or `high`.
  - Name-only creates `low`.
- Add flag action and rake task.
  - `flags:run_c7`
  - Include it in `flags:run_all` after enrichment-dependent flags.
  - Flag details include matched role IDs, match ID, confidence, supplier entity, public entity, source names, and rule.
- Add investigation/dashboard support.
  - Add C7 to lead classification as `potential_conflict`.
  - Case reports should include the person-link evidence excerpt.
  - Graph views can reuse existing individual-link rendering, with match confidence added where available.

## Test Plan

- Unit tests for public-official role normalization and import.
- Unit tests for identity matching:
  - NIF match creates high confidence.
  - exact rare name plus contextual evidence creates match.
  - common name-only match remains low confidence and does not flag.
  - rejected match is ignored by flag action.
- Flag action tests:
  - flags contracts where public-officeholder and supplier role overlap.
  - does not flag when dates do not overlap.
  - does not flag low-confidence unreviewed matches.
  - removes stale flags when match evidence disappears.
- Privacy tests:
  - public users see pseudonyms/aggregates.
  - journalist/auditor users see full evidence.
- Run full suite with `bundle exec rails test`.

## Assumptions

- V1 prioritizes defensibility over coverage.
- DRE is the authoritative appointment source.
- Entidade Transparência is enrichment, not the only source.
- Personal NIFs for public officials will often be unavailable.
- Name-only overlap is a review lead, not a contract flag.
- The system must preserve the project’s "risk scoring, not accusation" framing.
