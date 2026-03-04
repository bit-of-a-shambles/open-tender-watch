# Red Flag Research Blueprint — Portuguese Public Procurement

> Deep research blueprint for flagging corruption and abuse in Portuguese public tendering using open data. Source: practical field research synthesising [OECD "Preventing Corruption in Public Procurement"](https://www.oecd.org/en/publications/preventing-corruption-in-public-procurement_9789264059765-en.html), [OCP "Red Flags for Integrity"](https://www.open-contracting.org/resources/red-flags-for-integrity-giving-green-light-to-open-data-solutions/), Portal BASE, TED, AdC, and [TdC](https://www.tcontas.pt/) documentation.

---

## 1. What Portugal already gives you in open data

### Core source: Portal BASE

Portal BASE is the central public portal for Portuguese public contracts. It publishes contracts, announcements, entities, contract modifications, impugnations, and more — explicitly designed for monitoring and follow-up of public contracts.

Data can be extracted automatically and free of charge via BASE and dados.gov.pt, though direct portal extraction has file and line limits. API access is available for large-volume extraction, subject to registration and prior authorisation.

### OCDS availability

IMPIC published BASE contract data in OCDS format on Portugal's open data platform. This standardises procurement fields and makes red flag logic easier to implement.

### Extra source: TED (EU procurement notices)

TED provides public APIs and bulk downloads for notices. Valuable for cross-checking higher-value tenders and publication patterns, especially where Portuguese entities publish at EU level. TED documents a searchable API, direct download links, and bulk XML packages.

---

## 2. What you can reliably flag with open data

Treat this as **risk scoring, not accusation**. Use open data to surface cases for audit or journalistic review.

### A. Process abuse indicators (highest yield in BASE / OCDS)

| Indicator | OECD reference |
|---|---|
| Repeated direct awards or prior consultation to the same supplier | Repeat awards and concentration of awards by buyer to same bidder over 3 years |
| Contract published after key dates / execution before publication | Contract data earlier than adjudication date; contracts implemented before BASE publication |
| Frequent or large amendments | BASE publishes modifications above thresholds; OECD includes amendment indicators |
| Long execution duration | Contract execution > 3 years is a risk feature |
| Estimated value vs final contract value anomalies | Ratios between estimated value, base price, and contract price |

### B. Competition risk indicators

| Indicator | Notes |
|---|---|
| Supplier concentration by buyer | Share of buyer's spend to one supplier over time — strong collusion/favouritism signal |
| Bid rotation patterns | Model-based; depends on bidder-level data quality |
| Single bidder / low-competition procedures | BASE publishes procedure type and bidder details |
| AdC enforcement overlap | Competition Authority published cases are a corroboration source for cartel / anti-competitive conduct |

### C. Integrity and compliance risk indicators (harder with open data only)

| Indicator | Notes |
|---|---|
| Missing or inconsistent identifiers | VAT number completeness problems directly affect matching and are a quality risk |
| Non-submission / prior control issues | Contracts not communicated or submitted to TdC — requires TdC internal data for full coverage |
| Competition sanctions history | AdC sanction data enriched with NIF for cross-referencing (OECD model) |

---

## 3. Portuguese data limitations

### A. Data integration is the main bottleneck

The challenge is not data existence — it is different formats, structures, and missing values across sources, which complicates joins and weakens indicators.

### B. Some indicators are impossible or weaker

Some indicators could not be developed due to data availability. Some had to be supplemented with additional datasets from dados.gov.pt and Portugal2020.

### C. Beneficial ownership linkage is constrained

Portugal's beneficial ownership register (RCBE) exists, but:
- Access requires authentication; searches are made by legal person number.
- The CJEU ruling on beneficial ownership access heavily constrained planned interconnection of RCBE with procurement data.

This means open data users often cannot fully resolve:
- Hidden ownership links between suppliers
- Conflicts of interest involving politically exposed persons
- Shared ownership across competing bidders

### D. BASE data responsibility sits with contracting authorities

The information is the responsibility of contracting entities. Late, incomplete, or poor-quality entries occur and should be treated as risk signals, not just technical defects.

---

## 4. Best practice method for Portugal

### Layer 1 — Build a clean procurement spine

Use BASE as the core table. Minimum fields to normalise:

| Field | Notes |
|---|---|
| contract ID | `external_id` |
| contracting authority | name + NIF |
| supplier name + NIF | match on NIF first; fuzzy name otherwise |
| procedure type | direct award, prior consultation, open tender, etc. |
| CPV code | 8-digit code |
| base price / estimated value | decimal |
| contract price | `total_effective_price` |
| award date | `celebration_date` |
| signing date | |
| publication date | `publication_date` |
| amendment count and values | |

### Layer 2 — Add external corroboration tables

Enrich the spine with:
- **TED** — EU threshold tenders and publication consistency checks
- **AdC** — competition cases and sanctions; cross-reference supplier NIFs
- **Mais Transparência / Portugal2020** — EU-funded contracts; assess reporting reliability

### Layer 3 — Two-track scoring system

**Track A: Rule-based red flags** (high explainability, easy to audit)

Examples:
- Contract published after execution starts
- Repeat awards to same supplier above threshold within 12–36 months
- Amendment value ratio unusually high
- Contract value just below procedural thresholds
- Buyer uses direct award far above peer median for same CPV

OCP's red flags guidance and Cardinal tool are built for this logic, mapped to OCDS.

**Track B: Pattern-based anomaly flags** (statistical / model)

Examples:
- Bid rotation by supplier set
- Unusual pricing relative to buyer and CPV peers
- Cluster of suppliers who rarely compete except with one authority
- Sudden procedural shifts near budget deadlines

OECD's Portugal work separates indicators into rule-based, inference-based, and model-based categories.

---

## 5. When the data is weak — treat missingness as information

### Turn data quality into flags

Add a data quality risk layer:
- Missing supplier NIF
- Missing CPV
- Impossible date sequences
- Empty fields that should be mandatory for the procedure type
- Contract amendments with missing amendment basis
- Repeated manual text variations for same entity name

This often surfaces the same institutions that need closer scrutiny.

### Use entity resolution aggressively

Because names vary:
- Exact match on NIF when available
- Fuzzy name matching plus address and CPV
- Historical alias tables for suppliers and contracting authorities

Entity resolution is not optional in Portugal.

### Be explicit about confidence

For each flag attach:
- Risk score
- Evidence fields used
- Data completeness score
- Confidence level (low / medium / high)

This stops weak data from producing overconfident conclusions.

---

## 6. Priority red flags for immediate impact

1. Repeat direct awards / prior consultations to same supplier by same authority
2. Late publication or execution before publication
3. Amendment inflation and repeated extensions
4. Supplier concentration by authority and CPV
5. Price anomalies within same CPV and region
6. Buyer-level abnormal use of exceptional or special-measures procedures
7. Cross-match suppliers against AdC competition cases
8. Data quality evasion patterns — missing IDs and dates

---

## 7. Escalation routes in Portugal

| Issue type | Route |
|---|---|
| Financial irregularity, unlawful spending, contract legality, public money misuse | **Tribunal de Contas** complaints channel — anyone can report, including anonymously in justified cases; feeds risk analysis, audits, financial liability cases, or referral to other authorities |
| Cartel or bid rigging | **Autoridade da Concorrência** — report anti-competitive practices and collusion in public procurement; leniency framework available |
| General corruption / whistleblowing | **MENAC** reporting channel; TdC whistleblower protections |

---

## 8. Implementation phases

| Phase | Scope |
|---|---|
| **1** | Clean BASE ingestion pipeline + rule-based red flag dashboard (Track A) |
| **2** | TED and AdC enrichment; concentration and competition pattern indicators (Track B) |
| **3** | Anomaly detection + case triage workflow with confidence scoring |
| **4** | Ownership and conflict checks where legally accessible — constrained layer due to RCBE access limits |
