# UC8 — Wire Transfer Data Completeness: Manual (Non-Agentic) End-to-End Process
**Split into three genuinely separate institutional roles: Ordering, Intermediary, Beneficiary — because Regulation 11 assigns different obligations to each.**

---

## Part 1 — Branching Questions for UC8

### Why split by role instead of one generic "field completeness check"?
Because Reg 11 literally structures itself this way — §2 is headed "Responsibility of the Ordering Institution," §5-6 "Responsibility of the Beneficiary Institution," §9 "Responsibility of Intermediary Institution." These are not the same job:
- **Ordering Institution** is the data *source* — it identifies/verifies its own customer (the originator) before a transfer is ever sent. Missing data here means "don't send," not "hold and decide later."
- **Intermediary Institution** never talks to the originator directly — it only *preserves and forwards* what it receives, plus applies a risk-based policy on whether to execute/reject/suspend transfers that arrive already incomplete.
- **Beneficiary Institution** verifies the *receiving* customer's identity (if not already done) and applies its own risk-based policy on incoming incomplete transfers.

**The same bank can play any of these three roles on different transactions** — sending customer money out = Ordering; receiving customer money in = Beneficiary; passing a transfer through to another institution = Intermediary. Role is determined per-transaction, not per-institution.

### Does RE type change the process?
Mostly no, with one exception: **Regulation 11 §8** — for foreign inward remittances processed through a local agency bank on behalf of an MFB, the local bank is treated as the originator, and the MFB itself takes no FX exposure. Since your POC scope is Bank-only, this doesn't get built, but it's worth documenting as a known carve-out for completeness/accuracy.

### Is there a hard exemption from this entire regulation?
**Yes — and it was completely missing from the blueprint.** Reg 11 §1 explicitly excludes: *"transfer and settlement between the SBP REs where both the FIs are acting on their own behalf as originator and the beneficiary of the wire transfer."* Two banks settling their own interbank positions are **not** subject to any of this — this must be the very first gate, before any field-completeness logic runs.

### Does the field requirement differ for batch files?
**Yes.** Reg 11 §4: a batch file of bundled cross-border transfers only needs the **originator's account number or unique reference** (not full name/ID) plus **full, traceable beneficiary information**. This is a lighter requirement than the 5-field standard for individual transfers (§3) — conflating the two, as the blueprint did, overstates what batch files actually need.

---

## Part 2 — Full Manual Process (Phase by Phase)

### Phase 0 — Scope & Exemption Gate (runs first, before any role-specific logic)
1. Determine: is this transaction actually a "wire transfer/fund transfer" under Reg 11's definition (Def #33)?
2. **Interbank exemption check (§1):** if both the sending and receiving institutions are SBP REs, and both are acting on their own behalf (not on a customer's behalf) → **exempt**, process ends here, no further UC8 logic applies.
3. Classify: **individual transfer or batch file**, and **domestic or cross-border** (this affects which of the downstream role-checks are even relevant — domestic straight transfers typically skip the intermediary role entirely).
4. Determine **this bank's role on this specific transaction**: Ordering, Intermediary, or Beneficiary.

### Phase 1 — Ordering Institution Track
5. Customer (originator) initiates a transfer request.
6. **Identify and verify the originator** — if this customer already went through UC1's CDD, reuse that record; otherwise this must happen now (Reg 11 §2a references back to Reg 2).
7. Obtain **beneficial owner details of the funds being transferred** (§2a).
8. Compile the **full record needed to permit reconstruction** of the transaction (§2b) — this is broader than just the 5 message fields: date, currency type and amount, value date, purpose of the transfer, beneficiary details, beneficiary institution, and the **relationship between originator and beneficiary** (a field the blueprint's original list omitted).
9. Populate the **5 mandatory message fields** (§3), all equally required, no tiering: originator name, originator's account number/unique reference, originator's identity document number, beneficiary name, beneficiary's identity document number.
   - **For batch files**, only the originator's account number/unique reference is required (not full name/ID), plus full traceable beneficiary info (§4).
10. **Gate:** if any of the required fields (per whether it's individual or batch) cannot be populated → **the transfer is not sent.** This is preventive, not reactive — unlike the intermediary/beneficiary tracks below, there's no "hold and decide later" state here, because the ordering institution is the data source itself.
11. **Cross-link to UC5:** if a required field is missing specifically because the underlying customer's CDD was incomplete, this is the same situation as UC5's `CDD_FAILURE_OR_TIPOFF_RISK` trigger (AML Act s.7D) — raise it there rather than inventing a separate incomplete-data-suspicion path in UC8.
12. If complete → message assembled and sent, fields attached to travel with the payment throughout the chain.

### Phase 2 — Intermediary Institution Track
13. Bank receives a payment message it's passing onward (not its own customer's transaction on either end).
14. **Preserve and forward all originator/beneficiary fields exactly as received** (§9a) — this role never modifies or re-verifies the underlying identity data, it only relays it.
15. Keep a record of all information received (§9b).
16. Take reasonable measures, consistent with straight-through processing, to identify cross-border transfers that **arrive already lacking** required originator/beneficiary info (§9c) — this is a completeness check on an *incoming* message, not on this bank's own customer data (it has no direct relationship with the originator).
17. **This is where a genuine hold/reject/suspend decision applies** (§9d) — the intermediary institution needs risk-based policies for: (i) when to execute, reject, or suspend a wire transfer lacking required info, and (ii) what follow-up action to take. **Held/rejected/suspended cases require human review** before final action (consistent with the blueprint's own stated approval requirement, which is correct here).

### Phase 3 — Beneficiary Institution Track
18. Bank receives an incoming wire transfer for its own customer.
19. **Verify the beneficiary's identity if not previously verified** (§5) — again, reuse UC1's CDD record if this customer was already onboarded there.
20. Apply a **risk-based policy for incoming transfers lacking complete originator/beneficiary info** (§6) — the incompleteness itself is a factor in two separate decisions: (a) whether to execute or terminate the transaction, and (b) whether the transaction looks suspicious enough to merit STR consideration.
21. **Cross-link to UC5:** if incompleteness plus other signals suggest no apparent lawful purpose, this becomes a UC5 trigger candidate (`CROSS_UC_FINDING` or a new subtype), not a UC8-internal suspicion-decision — UC8 flags it, UC5 investigates and decides.
22. **Correspondent/counterparty pattern tracking** (§7): if a specific correspondent or counterparty institution repeatedly sends incomplete transfers, this should be logged and flagged for relationship review. Note: full relationship-review workflow belongs to UC9 (Correspondent Banking), which is outside your team's assigned scope — UC8 should log/flag this, not attempt to build UC9's approval workflow itself.

### Phase 4 — Record Retention
23. Wire transfer records fall under the same general transaction record-keeping requirement as everything else in this system — minimum 10 years, with the same Act-vs-Regulations anchor-date nuance already documented in UC5 (Act s.7(4): "after reporting"; Reg 8 §3/§4 language ties to "completion of the transaction" for general transaction records — use the later of the two computed dates).

---

## Part 3 — What This Fixes vs. the Blueprint's Original UC8

| Blueprint Element | Problem | Fix Applied |
|---|---|---|
| Single generic "Field Completeness Agent" for all cases | Regulation assigns genuinely different obligations to Ordering/Intermediary/Beneficiary roles | Split into three explicit role-tracks (Phases 1-3) |
| §1 interbank exemption | Completely missing — system would wrongly apply full compliance checks to exempt interbank settlements | Added as the first gate (Phase 0) |
| §8 MFB foreign-remittance carve-out | Missing | Documented as known-but-not-built (Bank-only scope) |
| Step 4 "critical vs non-critical field classification" | Not grounded in the regulation — Reg 11 §3 treats all 5 fields as equally mandatory | Removed, all 5 fields treated equally per your decision |
| Step 3 batch validation | Didn't distinguish the lighter §4 batch requirement (account/ref only) from the full §3 individual-transfer requirement (all 5 fields) | Explicitly differentiated (Phase 1, step 9) |
| Step 2 field list | Missing "relationship between originator and beneficiary" and other §2(b) reconstruction-record fields (value date, purpose, currency type/amount) — only captured the 5 message fields, not the full record-keeping requirement | Added (Phase 1, step 8) |
| Step 5 "Risk-based Rule Engine decides execute/hold/reject" applied uniformly | Doesn't apply to the Ordering role the same way — ordering institution prevents incomplete transfers from being sent at all, it doesn't "hold" its own outgoing payment for later decision | Ordering track is now explicitly preventive (Phase 1, step 10); hold/reject/suspend logic correctly scoped to Intermediary (§9d) and Beneficiary (§6) roles only |
| Step 5 "escalate as suspicious" | No explicit link to how that escalation actually gets investigated | Explicitly routed to UC5 as a trigger, not decided within UC8 itself |

---

Next: PRD (schema + n8n steps) for all three roles.
