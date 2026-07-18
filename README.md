# Genos POC Sandbox - SBP Compliance Engine

A scalable local sandbox environment for implementing and verifying State Bank of Pakistan (SBP) AML/CFT and CDD regulations across 5 compliance use cases.

---

## 📂 Repository Directory Structure

To support multi-use-case development, the repository is organized into distinct, self-contained directories:

```
genos-poc-v2/
├── .env                              # Environment variables (credentials, SMTP, etc.)
├── docker-compose.yml                # Multi-container orchestration (n8n, Postgres)
├── SBP_AML_CFT_Regulations.pdf       # Reference SBP regulation manual
│
├── docs/                             # SBP compliance mapping & technical execution docs
│   ├── uc1_onboarding_cdd.md         # Compliance & Technical Docs for UC1
│   └── uc3_pep_lifecycle.md          # Compliance & Technical Docs for UC3
│
├── db/
│   └── init/                         # Database schema and seed data SQL files
│
├── n8n/
│   └── workflows/                    # n8n workflow JSON canvas files
│       ├── uc1_onboarding_cdd.json   # Use Case 1 workflow
│       └── uc3_pep_lifecycle.json    # Use Case 3 workflow
│
├── manual_build_guides/              # n8n canvas manual step-by-step instructions
│   ├── uc1_onboarding.md             # Guide for Onboarding & CDD
│   ├── uc2_transaction_monitoring.md # (Placeholder)
│   ├── uc3_pep_lifecycle.md          # Guide for PEP Lifecycle Monitoring
│   ├── uc3_sanctions_screening.md    # (Placeholder)
│   ├── uc4_regulatory_reporting.md   # (Placeholder)
│   ├── uc5_str_ctr.md                # Guide for STR/CTR Pipeline & Suspicious Investigation
│   ├── uc8_wire_transfers.md         # Guide for Wire Transfer Data Completeness & Compliance
│   └── uc13_governance.md            # Guide for IRAR Auto-Generation & Board Governance
│
└── tests/                            # Automated test runners and JSON payloads
    ├── uc1_onboarding/
    │   ├── test_onboarding.sh        # Intake & Asynchronous callback test script
    │   └── payloads/                 # SBP edge-case test payloads
    │       ├── 01_individual_low_risk.json
    │       ├── 05_ngo_mandatory_edd.json
    │       └── ...
    ├── uc2_transaction_monitoring/
    ├── uc3_pep_lifecycle/            # UC3 test runner and payloads
    │   ├── test_pep_lifecycle.sh     # PEP Lifecycle test automation script
    │   └── payloads/                 # SBP compliance edge-case payloads
    │       ├── 01_foreign_pep_full_path.json
    │       ├── 02_junior_middle_exclusion.json
    │       └── ...
    ├── uc3_sanctions_screening/
    ├── uc4_regulatory_reporting/
    ├── uc5_audit_logs/
    ├── uc5_str_ctr/                  # UC5 test runner and payloads
    │   ├── test_uc5_ctr.sh           # CTR Pipeline test runner script
    │   ├── test_uc5_str.sh           # STR Pipeline test runner script
    │   └── payloads/                 # SBP compliance edge-case payloads
    │       ├── 01_cash_above_threshold.json
    │       ├── 03_tms_alert_close.json
    │       └── ...
    ├── uc8_wire_transfers/           # UC8 test runner and payloads
    │   ├── test_uc8_wire_transfers.sh # Wire transfer completeness test runner script
    │   └── payloads/                 # SBP compliance edge-case payloads
    └── uc13_governance/              # UC13 test runner and payloads
        ├── test_uc13_governance.sh   # IRAR & Board governance test runner script
        └── payloads/                 # SBP compliance edge-case payloads
```

---

## 🚀 Getting Started

### 1. Start Services
Run the docker container services in detached mode:
```bash
docker compose up -d
```

### 2. Configure & Run Use Cases
- **Use Case 1 (Customer Onboarding & CDD):**
  - Refer to the setup guide: [manual_build_guides/uc1_onboarding.md](file:///mnt/c/Important/Git_Folder/genos-poc-v2/manual_build_guides/uc1_onboarding.md)
  - Import the workflow from [n8n/workflows/uc1_onboarding_cdd.json](file:///mnt/c/Important/Git_Folder/genos-poc-v2/n8n/workflows/uc1_onboarding_cdd.json) in your n8n instance at `http://localhost:5678`.

- **Use Case 3 (PEP Lifecycle Monitoring & EDD):**
  - Refer to the setup guide artifact: [n8n_manual_build_guide_uc3.md](file:///home/shazan/.gemini/antigravity-ide/brain/43dae19e-0d9e-4363-bd3d-166abbbe8dca/n8n_manual_build_guide_uc3.md) (Local backup: [uc3_pep_lifecycle.md](file:///mnt/c/Important/Git_Folder/genos-poc-v2/manual_build_guides/uc3_pep_lifecycle.md))
  - Build the 4-flow n8n canvas using the step-by-step build guide, or import the workflow from [n8n/workflows/uc3_pep_lifecycle.json](file:///mnt/c/Important/Git_Folder/genos-poc-v2/n8n/workflows/uc3_pep_lifecycle.json) in your n8n instance at `http://localhost:5678`.

- **Use Case 5 (STR/CTR Pipeline & Suspicious Investigation):**
  - Refer to the setup guide: [uc5_str_ctr.md](file:///mnt/c/Important/Git_Folder/genos-poc-v2/manual_build_guides/uc5_str_ctr.md)
  - Follow the manual build guide step-by-step to construct both workflows on your n8n canvas at `http://localhost:5678`.

- **Use Case 8 (Wire Transfer Data Completeness & Compliance):**
  - Refer to the setup guide: [uc8_wire_transfers.md](file:///mnt/c/Important/Git_Folder/genos-poc-v2/manual_build_guides/uc8_wire_transfers.md) (Backup: [n8n_manual_build_guide_uc8.md](file:///home/shazan/.gemini/antigravity-ide/brain/43dae19e-0d9e-4363-bd3d-166abbbe8dca/n8n_manual_build_guide_uc8.md))
  - Follow the manual guide step-by-step to construct both workflows on your n8n canvas at `http://localhost:5678`.

- **Use Case 13 (IRAR Auto-Generation & Board Governance):**
  - Refer to the setup guide: [uc13_governance.md](file:///mnt/c/Important/Git_Folder/genos-poc-v2/manual_build_guides/uc13_governance.md) (Backup: [n8n_manual_build_guide_uc13.md](file:///home/shazan/.gemini/antigravity-ide/brain/43dae19e-0d9e-4363-bd3d-166abbbe8dca/n8n_manual_build_guide_uc13.md))
  - Follow the manual guide step-by-step to construct the 5 flows on your n8n canvas at `http://localhost:5678`.

### 3. Running Automated Tests

#### Use Case 1 Onboarding
```bash
cd tests/uc1_onboarding/
# Run a Low Risk immediately approved test
./test_onboarding.sh payloads/01_individual_low_risk.json
# Run an NGO mandatory EDD test requiring manager approval
./test_onboarding.sh payloads/05_ngo_mandatory_edd.json
```

#### Use Case 3 PEP Lifecycle
```bash
cd tests/uc3_pep_lifecycle/
# Run a Foreign PEP match full path test (screens, creates designation, SOW, senior approval, enhanced flag)
./test_pep_lifecycle.sh payloads/01_foreign_pep_full_path.json
# Run a junior official match (excludes at Phase 5 seniority gate per Def #52(d))
./test_pep_lifecycle.sh payloads/02_junior_middle_exclusion.json
```

#### Use Case 5 STR/CTR Pipeline
```bash
cd tests/uc5_str_ctr/
# Run CTR above threshold test (triggers cash reporting flag, verification, and filing)
./test_uc5_ctr.sh payloads/01_cash_above_threshold.json
# Run STR manual observation filing test (case creation, analyst narrative draft, officer signoff, filing)
./test_uc5_str.sh payloads/04_manual_observation.json
```

#### Use Case 8 Wire Transfer Data Completeness
```bash
cd tests/uc8_wire_transfers/
# Run compliant outgoing transfer test
./test_uc8_wire_transfers.sh payloads/01_outgoing_compliant.json
# Run incomplete outgoing transfer test (preventively blocked)
./test_uc8_wire_transfers.sh payloads/02_outgoing_missing_originator_id.json
# Run intermediary hold and analyst release test
./test_uc8_wire_transfers.sh payloads/03_intermediary_hold_release.json
# Run beneficiary hold and analyst STR escalation test (interoperates with UC5)
./test_uc8_wire_transfers.sh payloads/04_beneficiary_escalate_str.json
# Run interbank own-behalf settlement test (auto-exempted)
./test_uc8_wire_transfers.sh payloads/05_interbank_settlement_exempt.json
```

#### Use Case 13 IRAR & BoD Governance
```bash
cd tests/uc13_governance/
# Run scheduled cycle end-to-end test (intake, metrics aggregator, narrative edit, gap, action validation, prereview, BoD vote, SOP text, archive)
./test_uc13_governance.sh payloads/01_scheduled_complete_path.json
```

---

## 🛠 Scalability Plan (Use Cases 2 - 15)

When adding subsequent use cases:
1. **Workflows:** Store exported `.json` workflows in `n8n/workflows/`.
2. **Build Guides:** Author the canvas configurations in `manual_build_guides/`.
3. **Tests & Payloads:** Create a test runner script and folder inside `tests/uc[X]_[name]/payloads/`.
