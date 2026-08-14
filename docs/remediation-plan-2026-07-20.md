# Remediation Plan — 2026-07-20 100-Case KB Draft Eval

**Status:** analysis & planning only — no code changes in this document.
**Baseline artifacts:** `docs/eval-run-2026-07-20.csv`, `docs/eval-detail-2026-07-20.json`, `docs/corpus-snapshot.json` (335 docs).
**Eval result:** 12 good drafts · 7 false positives · 54 correct declines · 17 corpus gaps · 10 retrieval misses.

---

## Executive summary

Two data findings reframe the whole remediation and resolve the apparent tension
between recovering misses and cutting false positives:

1. **The 0.45 draft floor is not the recall lever, and it should move *up*, not down.**
   `good-draft` topScores start at **0.503**; three false-positives sit at **0.458 /
   0.478 / 0.492**. Raising the floor 0.45→0.50 removes 3 FPs at **zero** good-draft
   cost. The recoverable retrieval-misses are mostly *below* floor because the
   answering doc never entered the candidate pool — lowering the floor would not help
   them and would admit the 8 corpus-gaps + 10 correct-declines that sit in the
   0.40–0.50 band. **Recall is fixed at pooling/ranking; precision at the floor +
   grounding. The two goals do not conflict under this plan.**

2. **The misses are query-term starvation, not the known semantic-band defect.**
   `extractTerms` (`SupportRetrievalService.cls:388-403`) takes terms in *document
   order* and caps at 10. Email preambles, forwarded headers, and metadata blocks eat
   the entire budget before the actual error string. Case 00034002's real query is
   `[customer, access, support, don, know, answer, here, wherefoodcomesfrom, name,
   long]` — 100% signature preamble; "Regex too complicated" never enters. The
   answering docs **exist and contain the exact error strings** (the Math Tags doc's
   keyword field literally reads "ending position out of bounds").

**Targets:** retrieval-miss 10→≤3, false-positive 7→≤2, correct-decline 54 held,
drafted-rate up. Achieved via a metadata floor bump (near-free FP cut), a query
term-selection rework + error-string pooling channel (recall), a product-mismatch
guard and per-claim grounding (precision), plus corpus sanitization of ingested
prompt-injection content.

### Pipeline facts (established from the repo, not assumed)

- One config CMDT: `Support_Draft_Setting__mdt` record `Default`. Draft floor =
  `Draft_Min_Top_Score__c` = 0.45, compared at `SupportDraftingService.cls:150`
  against the calibrated `contentMax` (`SupportRetrievalService.cls:282-286`).
- Product filter is a **hard SOSL pre-filter** (`soslSearch` … `Product__c IN
  :products`, `SupportRetrievalService.cls:351`); skipped entirely when the case
  product is blank. Per-doc `product` is **dropped** in
  `SupportDraftOrchestrator.mapCandidates` (never reaches `SolutionContext`) and
  **never appears in the drafting prompt** — the model cannot tell an S-Docs doc from
  an S-Sign doc.
- Grounding (`checkGrounding` `SupportDraftingService.cls:457-499`) is a **whole-draft
  lexical overlap against a pooled token bag from all docs** — no per-claim /
  per-source binding; hard-blocks only at ratio < 0.34, else caps confidence to LOW.
- `isHighSignal` (`SupportRetrievalService.cls:646-654`) already identifies
  error-code / API-name tokens, but is used **only in scoring — not in pooling or term
  selection**, so a doc that isn't pooled is never scored.
- The distill accept-margin is hardcoded `DISTILL_ACCEPT_MARGIN_DEFAULT = 0.10`; the
  `Retrieval_Distill_Accept_Margin__c` field referenced in prior notes **does not
  exist**. There is also **no `fusion_mode` toggle** — RRF always ranks; the linear
  `content` blend always feeds confidence.
- Ingestion write seam: `SupportSolutionStore.upsertPages` → `stripHtml` (`:148`);
  connector markdown also passes `cleanMarkdown` (`:691`). Neither neutralizes
  directive content. `docText` (the embed source) reads `Body__c` directly, so
  sanitization must run **before** the body write at `SupportSolutionStore.cls:77`.

---

## 1. Root-cause tables (all 27 misses + 7 false positives)

### 1a. Retrieval misses (10)

| Case | Prod | topScore | Answering doc (exists) | Root cause | Class | Fix |
|---|---|---|---|---|---|---|
| 00034002 | S-Docs | 0.192 | Job Splitters (u8xi) | 10-term budget 100% consumed by "customer has access…WhereFoodComesFrom" preamble; "Regex too complicated" never queried | term starvation | 1,2 |
| 00033941 | S-Docs | 0.531 | Math Tags Null Value (u8o8) | query = pkg/version/avanan-URL header; "Ending position out of bounds" never queried; a *different* doc scored 0.53 and the model correctly declined | term starvation + verbatim error | 1,2 |
| 00033950 | S-Sign | 0.165 | Configure Global Settings §5C (u8fe) | "not a valid Org Wide Email" never queried; the answer is buried deep in a long multi-topic doc | term starvation + chunking | 1,2,8 |
| 00033783* | S-Docs | — | (no doc — corpus gap) | query = "client/optum/aarp/package…" metadata header; EMAIL_ADDRESS_BOUNCED never queried, and no doc exists | term starvation + gap | 1,2 + doc |
| 00033777 | S-Docs | 0.497 | Upload PDF "Render If" (u8kV) | correct doc not pooled; generic button-code docs surfaced instead | pooling/ranking | 2 |
| 00033807 | S-Sign | 0.625 | Configure E-Sig Template (u8mW) + Create/Send Sig Requests | multi-doc answer; only the perm-set doc surfaced | recall breadth | 2 |
| 00033821 | S-Docs | 0.326 | External Client Apps / S-Sign Connected App (wXlE) | vocabulary: case "external app / run as" vs doc "External Client Apps"; distill tried, lost by the 0.10 margin | vocab alias + distill margin | 1,3 |
| 00033743 | S-Sign | 0.247 | Customize S-Sign Fields & Inputs (u8xu) | answer (Text Preformat `## - ####`) buried in a broad doc; case says "MM-YYYY" | chunking + vocab | 3,8 |
| 00033962 | S-Docs | 0.539 | Translating Document Content (u8oJ) | sibling-doc confusion: the UI-translation doc outranked the document-translation doc | ranking (near-miss) | 1,5(topic) |
| 00033704 | S-Sign | 0.713 | latest upgrade links (ugTA) | **not a retrieval miss** — correct doc retrieved & HIGH; drafting fabricated a link → whole draft grounding-blocked | drafting/grounding | 6 |
| 00034158 | S-Docs | excluded | Use Bar Codes & QR Codes (u8pj) | **not retrieval** — a genuine buried QR-code question wrongly stamped `NO_DRAFT_EXCLUDED` as billing | intake misclassification | 7 |

\* 00033783 is labelled a retrieval-miss but is truly a corpus gap (no doc exists);
it appears here and in the §3 backlog. **Net of the 10: 8 genuine retrieval, 1
grounding, 1 intake.**

### 1b. False positives (7)

| Case | Prod | topScore | Defect | Class | Fix |
|---|---|---|---|---|---|
| 00034044 | S-Docs | 0.492 | generic PDF-UPLOAD config; ignores the "mttm…refused to connect" VF-domain error; no doc covers it | over-eager near-floor | **4** (floor→0.50 removes) |
| 00034062 | S-Docs | 0.478 | generic "pass recordId" advice; ignores "Invalid field SSIC_Policy__c" SObjectException | over-eager near-floor | **4** (floor→0.50 removes) |
| 00033890 | S-Docs | 0.458 | fallback template-error steps; error is record-specific (works on other records) | over-eager near-floor | **4** (floor→0.50 removes) |
| 00033884 | S-Docs | 0.541 | S-Sign "license key expired" answered with **S-Docs** License Key template steps | cross-product confusion | 5,6 |
| 00034155 | S-Docs;S-Sign | 0.573 | fabricated wrong menu path "Company Information > Feature Licenses"; correct doc (u8mY) not retrieved; grounding only capped LOW, still drafted | ungrounded fabrication + product | 5,6,2 |
| 00033953 | S-Docs | 0.702 | answers the exact question with an unsupported specific: "signed doc **automatically attaches** to record" | grounding gap (per-claim) | 6 |
| 00033675 | S-Docs | 0.542 | conflates server-side `{{!SDOCS_JAVASCRIPT}}` (works) with browser JS (doesn't); no doc covers the directive | topical-but-wrong | 6,5(topic) |

### 1c. Threshold-tension evidence (why floor moves up, not down)

topScore distributions per label (from `eval-run-2026-07-20.csv`):

- **good-draft** (min→max): 0.503, 0.520, 0.550, 0.610, 0.630, 0.655, 0.668, 0.678, 0.713, 0.768, 0.773, 0.875
- **false-positive:** 0.458, 0.478, 0.492, 0.541, 0.542, 0.573, 0.702
- **retrieval-miss:** 0.165, 0.192, 0.247, 0.326, 0.497, 0.531, 0.539, 0.625, 0.713
- Cases in the **[0.40, 0.50)** band by label: corpus-gap 8, correct-decline 10, false-positive 3, retrieval-miss 1.

The good-draft floor (0.503) sits just above three FPs — a 0.50 cutoff is a clean
separator. Lowering the floor would admit 18 gap/decline cases from the 0.40–0.50
band for the sake of one retrieval-miss (0.497); it is the wrong lever.

---

## 2. Ranked fix list (with expected eval impact)

"Metric" = which target the fix moves. Recommended sequencing top-to-bottom: the
near-free, low-risk wins (4, 9) first; then the recall rework (1–3) gated on re-eval;
then precision guards (5, 6); the intake and chunking items last.

| # | Fix | What / where | Metric | Est. impact | Risk |
|---|---|---|---|---|---|
| **4** | **Raise draft floor 0.45→0.50** | `Draft_Min_Top_Score__c` (metadata-only) | FP↓ | −3 FP (00034044, 00034062, 00033890); **0 good-draft loss** (min good-draft 0.503) | none — decline-only strengthening. Keep ≤0.50 to protect the 0.503 good draft |
| **9** | **Corpus sanitization** (§4) | strip GitBook trailer in `cleanMarkdown`; re-ingest + re-embed; recurrence guard | security | removes the injection surface on ~225/335 docs; may slightly denoise embeddings | low — deterministic strip + validator |
| **1** | **Query term-selection rework** (full, user-chosen) | pre-strip email signatures / legal footers / forwarded headers / `cid:` refs / quoted-reply chains, then rank high-signal tokens (quoted error strings, error codes, CamelCase / API names via `isHighSignal` `:646`) ahead of prose within the 10-term budget; reuse `tokenize` `:656` | miss↓ | recovers 00034002, 00033941, 00033950; net +3–4 | **hot path** → the re-eval decline gate is mandatory |
| **2** | **Verbatim error-string pooling channel** | extract quoted strings / error-code substrings and run a dedicated SOSL pass so the answering doc enters the pool even when the generic query wouldn't surface it (today `isHighSignal` boosts scoring only — unpooled docs are never scored) | miss↓ | recovers 00033777, 00033807; reinforces 00033941/00033950 | med — widens pool; watch precision via re-eval |
| **3** | **Make distill accept-margin tunable + lower** | replace hardcoded `DISTILL_ACCEPT_MARGIN_DEFAULT=0.10` with a real `Support_Draft_Setting__mdt` field; accept a distilled pass when it surfaces a *new* high-signal doc | miss↓ | recovers 00033821, 00033743 | low — additive, metadata-gated |
| **5** | **Product-mismatch guard** | carry `Support_Solution__c.Product__c` onto `SolutionContext` (dropped today in `mapCandidates` `:118-131`); down-rank/exclude docs whose product ≠ known case product; add a per-doc `product:` line to `buildPrompt` so the model can distinguish S-Docs vs S-Sign | FP↓ | removes 00033884; helps 00034155 and the topic side of 00033962/00033675 | med — must stay permissive when case product is blank/multi so legit cross-product docs aren't excluded |
| **6** | **Per-claim / direct-answer grounding** | beyond the pooled-bag block: verify the sentence that answers the customer's question is supported by a *specific* source; **block** fabricated specifics/links instead of only capping LOW; on a fabricated *link*, strip + regenerate rather than block the whole draft | both | removes 00033953; mitigates 00034155/00033675; **recovers miss 00033704** | med — tune to avoid over-blocking good drafts |
| **7** | **Intake billing-exclusion re-scope** | don't fire the billing exclusion when a genuine product/how-to question is also present in the thread | miss↓ | recovers 00034158 | low — narrows an over-broad gate |
| **8** | **Doc chunking (Phase 3, optional)** | split long multi-topic docs into retrievable sections so buried answers (e.g. Global Settings §5C) match | miss↓ | helps 00033950, 00033743 | larger effort; defer behind the re-eval of fixes 1–3 |

**Projected outcome:** retrieval-miss 10 → ~2–3 residual (00033962 sibling-confusion,
00033743 deep-chunk); false-positive 7 → ~≤2 residual (00033675 / 00033953 hardest);
correct-decline 54 held by the re-eval gate (the floor raise only strengthens
declines); drafted-rate rises — the floor removes 3 wrong drafts while fixes 1–3/6
recover ~6–7 correct drafts.

---

## 3. Corpus-gap doc backlog (17 cases, clustered & ranked)

Priority = frequency × severity; resolutions sourced from case text where present.

### P1 — Generation/runtime error troubleshooting (4)
Reproducible errors, high volume, resolutions partly in-thread.
- **S-Docs RENDER expression syntax errors** → 00033838 ("RENDER expression has unbalanced parentheses").
- **SDTemplateController parse errors** → 00033690 ("Invalid integer: inherit").
- **SDTranslate signer-field default-value error** → 00033872 ("missing value at 'mmmmm'").
- **SendEmail EMAIL_ADDRESS_BOUNCED / IsEmailBounced interaction** → 00033783.

### P2 — S-Sign advanced / data-model / security (3)
- **Identify the source template of a completed S-Sign Envelope** (drives routing/approval) → 00033879.
- **S-Sign guest-user security architecture alternative** (Varonis flag) → 00033721. ⚠ *product/architecture question — may be a "known limitation" answer, not a how-to.*
- **Re-enable the "disable email verification code requirement" checkbox** → 00034159. ⚠ *likely a product bug (checkbox disappears after being checked).*

### P2 — XLSX / component formatting (2)
- **XLSX Long Text Area renders only the last paragraph** (`<br>` handling) → 00034200.
- **Component-template CSS / related-list formatting lost in a parent template** → 00033964.

### P3 — Permissions / run-as (2)
- **Minimum permissions to generate SDoc PDFs** (remove the View Setup & Config requirement) → 00034010.
- **Run an S-Doc Job as a chosen user** (opportunity owner vs approver) → 00034207.

### P3 — HubSpot edition (2)
- **Send/attach a template from a HubSpot ticket** → 00033714.
- **Completion notifications in HubSpot** → 00033799.

### P3 — Feature how-to gaps (4)
- **Related-list runtime-prompt writeback to the base object** → 00033793.
- **Embed a generated-doc preview (prefilled) inside a custom flow** → 00033963.
- **Org-wide From address behavior in Mass Merge** → 00033843.
- **Live Edit LWC frame-ancestors CSP block in sandbox** → 00034166. ⚠ *config/environment issue, not purely a doc gap.*

**Flag — really product/config, not documentation:** 00034159, 00033721, 00034166
→ route to Eng/PM rather than the KB authoring backlog.

---

## 4. Corpus sanitization plan (security)

**Threat.** Several ingested KB bodies carry prompt-injection-style directive content
that the live drafting pipeline reads. The dominant shape is a **templated GitBook
trailer** appended to every connector-sourced page — present on **~225 of 335 docs**.
It ends the body with:

```
---

# Agent Instructions
This documentation is published with GitBook. GitBook is the documentation platform
designed so that both humans and AI agents can read, navigate, and reason over
technical content effectively. …

## Querying This Documentation
… Perform an HTTP GET request on the current page URL with the `ask` query parameter …

```
GET https://help.sdocs.com/…/<page>.md?ask= &goal=
```
```

This instructs a reading agent to make **live HTTP calls** to help.sdocs.com. It is
ingested verbatim into `Body__c`, embedded (via `docText`), and fed to the drafting
model. The trailer is always the tail of the body and is structurally uniform, so a
deterministic strip is safe and complete.

**Chosen approach: surgical strip + recurrence guard** (re-ingest + re-embed).

1. **Surgical strip** in `SupportSolutionStore.cleanMarkdown` (`:691`), which every
   connector body already passes through: cut from the `^---\s*#\s*Agent Instructions`
   marker to end-of-body. Add a fallback strip for any fenced `GET
   https://help.sdocs.com/…?ask=` directive block. This runs before the body write at
   `SupportSolutionStore.cls:77`, so it precedes embedding.
2. **Re-ingest + re-embed** the affected corpus — the current bodies and
   `Embedding__c` vectors already contain the trailer. Sequence: dry-run → verify
   strip on a sample → purge/re-upsert connector docs → `scripts/apex/backfill_embeddings.apex`.
3. **Recurrence guard** at the upsert seam: a validator that detects residual directive
   markers (`# Agent Instructions`, `Perform an HTTP GET request`, fenced `GET
   https://…`, "AI agents can read"). On a hit — strip if it matches the known shape;
   otherwise withhold `customer_safe` visibility (route to human review) and log, so a
   novel injection cannot silently reach the drafting model.
4. **Regression coverage:** an Apex test / corpus assertion that **no** `customer_safe`
   doc body contains the directive markers.

No eval-metric regression is expected (the trailer is retrieval noise); a minor
denoise upside on lexical + embedding signals is possible.

---

## 5. Re-eval procedure (measure each fix against this same 100-case set)

- **Harness.** Re-run `scripts/apex/run_draft_eval_pinned.apex` (the pinned 100
  caseIds) → `DraftEvalBatchJob`; regenerate the merged CSV + `eval-detail` JSON.
  Baseline = `docs/eval-run-2026-07-20.csv` + `docs/eval-detail-2026-07-20.json`.
- **Deterministic retrieval probe** (bypasses distillation non-determinism): use
  `scripts/apex/probe_retrieval.apex` PROBE mode to assert, per miss case, that the
  target doc **(a) enters the candidate pool** and **(b) clears rank/floor** — a
  pass/fail independent of the drafting LLM. This is the primary gate for the recall
  fixes because the draft-level metric is noisy.
- **Per-fix gates:**
  - *Fixes 1–3, 8 (recall, hot path):* ship only if the **54 correct-declines do not
    regress** (individual swaps allowed only if net non-negative and reviewed) and the
    named miss cases now pool + rank their target doc.
  - *Fix 4 (floor):* confirm the 12 good-drafts still clear 0.50 (min observed 0.503)
    and that 00034044 / 00034062 / 00033890 now decline.
  - *Fixes 5–6 (precision):* confirm the named FPs drop to NO_DRAFT / blocked without
    knocking out any of the 12 good-drafts; watch specifically for over-blocking by the
    per-claim grounding check.
  - *Fix 9 (sanitization):* corpus assertion (no directive markers in `customer_safe`
    bodies); eval metrics unchanged within noise.
- **Scorecard per iteration:** label counts (targets: miss ≤3, FP ≤2, declines = 54),
  per-case topScore deltas vs baseline, and the miss/FP case-level pass table.

---

## Appendix — corrected assumptions

Investigation corrected two items carried in prior notes; update downstream references:

- **`Retrieval_Distill_Accept_Margin__c` does not exist.** The distill accept-margin is
  a hardcoded Apex constant (`DISTILL_ACCEPT_MARGIN_DEFAULT = 0.10`). Fix 3 introduces
  the real metadata field.
- **There is no `fusion_mode` toggle.** RRF always ranks; the linear `content` blend
  always feeds topScore/confidence. Any "linear_blend vs rrf" switching described
  elsewhere is not present in the current code.
