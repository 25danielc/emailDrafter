# Precision Plan — Drive KB-Draft False Positives Toward Zero

**Status:** planning only — no code changes in this document.
**Baseline:** `docs/eval-drafts-reviewed-2026-07-20b.csv` (21 drafted: 11 good / 10 FP),
`docs/eval-run-2026-07-20b.csv`, `docs/eval-detail-2026-07-20b.json`.

## Context

The 2026-07-20b pinned eval drafted 21 of 100 cases: **11 good / 10 false-positive = 52%
precision**. A wrong or fabricated answer sent to a customer costs trust; a declined draft costs
a little human time. Operating principle: **precision over recall — when any check is uncertain,
DECLINE. Zero hallucinated specifics is a hard requirement, not a target.**

The 10 FPs split into two mechanisms the current pipeline structurally cannot catch:

1. **Ungrounded fabrication (4):** `00034050, 00034226, 00033958, 00034122`. The model
   invents concrete specifics (limit numbers, merge-field/attribute syntax, field names)
   that *reuse source vocabulary*, so the deterministic lexical grounding check
   (`checkGrounding`, token-overlap ratio) passes them.
2. **Topical-but-wrong (6):** `00033778, 00033698, 00033788, 00034062, 00033976, 00033996`.
   On-topic, grounded, above the 0.50 floor, but never answers the customer's *specific*
   error — frequently because the real error lives in a screenshot the pipeline cannot read
   (the pipeline ingests only Subject + Description + Product; **no attachment bytes at all**).

**Proof that threshold tuning is exhausted:** among drafted cases, FPs score
`00034050 HIGH/0.807`, `00033788 HIGH/0.8145` while good drafts score `00033913 LOW/0.5369`,
`00034068 LOW/0.7212`. Confidence and `topScore` do not separate good from FP. The only
remaining lever is a *semantic* check of whether the draft actually answers the question
using only supported claims.

### Verified pipeline facts (from the repo, not assumed)

- Decision method: `SupportDraftingService.draft(DraftInput)`. Ordered gates: null → exclusion →
  draft-trust (customer_safe) → empty-retrieval → **score floor 0.50** (`Draft_Min_Top_Score__c`,
  pre-model) → retry/model-error → `can_answer=false` decline → empty-draft → URL scrub →
  **grounding gate** (`NO_DRAFT_UNGROUNDED` when ratio < 0.34) → **accept (`DRAFTED`)**.
- **Clean insertion seam:** the accept block, `SupportDraftingService.cls:258–280`, *after*
  grounding passes and *before* `appendReplyFooter`/`appendDisclaimers` mutate the text. In
  scope: `String draftText` (model-authored, pre-footer), `List<SolutionContext> fed` (the cited
  docs, each with full `body`, `name`, `product`, `url`), `String sourcesUsed`, `String
  modelConfidence`, `DraftInput input` (has `caseSubject`, `caseDescription`).
- **Model call:** injectable `ModelClient client` (`@TestVisible`), impl `EinsteinModelClient`
  wrapping `aiplatform.ModelsAPI`; `generate(String modelName, String prompt)` already takes an
  arbitrary model id. Response parsing: reuse `parseJson()` (`:685`, tolerates bare/fenced/embedded
  JSON, empty map on failure). Drafting model = `sfdc_ai__DefaultGPT4Omni`; a cheaper sibling
  `sfdc_ai__DefaultOpenAIGPT4OmniMini` exists (used by the legacy triage classes) — **text-only**.
- Config: one CMDT `Support_Draft_Setting__mdt.Default`. `AI_Draft_Status__c` is a **restricted**
  picklist — a new value must be deployed to the field *before* the flow references it, or the
  whole interview rolls back (documented failure mode).
- Eval: `scripts/apex/run_draft_eval_pinned.apex` (hardcoded 100 Case Ids) → `DraftEvalBatchJob`
  → reviewer CSV + detail JSON. Distillation is sampled (no temperature control), so ±3–4 cases
  flip between runs — **compare aggregates, not individual cases.**

---

## Phase 1 — LLM verification gate  *(approved; primary precision lever)*

A second, cheap, metered model call on **every would-be draft** (only cases that reach the
accept block — ~20% of cases, not all 100). Fail closed.

### Placement & control flow
Insert at `SupportDraftingService.cls:258`, immediately after the grounding gate and before
`out.status = 'DRAFTED'`. New order at the seam:

1. grounding gate (existing)
2. **claim-level fabrication check (Phase 2, deterministic, free) — runs first, fail-fast**
3. **LLM verification gate (this phase, one metered mini call)**
4. accept → footer/disclaimer

Gate off behind `Draft_Verify_Enabled__c` (default true); model id from `Draft_Verify_Model__c`
(default `sfdc_ai__DefaultOpenAIGPT4OmniMini`). Reuse the injected `client` and `parseJson`.

### Prompt design
Single user message, three inputs — the customer's own words, the model's draft, and the
verbatim cited sources (the same `fed` bodies, already ≤8000 chars):

```
You are a strict support-QA reviewer. Decide whether a drafted reply may be sent.
Approve ONLY if BOTH are true:
  (1) The draft addresses the customer's SPECIFIC problem/question as stated — not merely
      the general topic. If the specific error/question is not actually present in the
      CASE text (e.g. it appears to live in an unshown screenshot/attachment), you cannot
      confirm the draft answers it → do not approve.
  (2) Every concrete claim in the draft (steps, causes, field/setting names, values, syntax,
      limits) is supported by the SOURCES below. Anything not supported → do not approve.
When uncertain, DO NOT APPROVE. Reply with JSON only.

CASE SUBJECT: ...
CASE DESCRIPTION: ...
DRAFT REPLY: ...
SOURCES (the only permissible basis for claims):
[1] <name>: <body>
[2] ...

Output strictly: {"answers_specific_question": true|false, "all_claims_supported": true|false,
"verdict": "approve"|"decline", "reason": "<one sentence>"}
```

### Structured output & fail-closed parsing
`verify(draftText, input, fed, cfg)` returns a decline unless the parse yields
`verdict == "approve"` **and** `answers_specific_question == true` **and**
`all_claims_supported == true`. **Any** other outcome → decline:
- `parseJson` returns empty / missing keys / non-boolean → decline (parse error fails closed)
- callout throws or returns blank → decline (do **not** silently draft; unlike the drafting
  retry loop, an unverifiable draft must not ship)
- any `false` / `"decline"` → decline

On decline: `out.status = 'NO_DRAFT_UNVERIFIED'` (new picklist value), confidence
`clampConfidence('LOW', input.retrievalConfidence)`, note `"[verification gate DECLINED: <reason>]"`
appended via `buildNotes`. **No retry** (a retry loop would just resample until it passes,
defeating the gate).

### Cost
Cost unit here is **metered ModelsAPI requests** (sandbox budget ~500/hr), not dollars.
- **+1 request per would-be draft only** — ~21 per 100-case eval; in production ≈ +0.2
  requests/case at the current ~20% draft rate. Negligible against the meter and against the
  1–3 GPT-4o calls already spent per case.
- Model = GPT-4o-**mini**: ~15–20× cheaper per token than the GPT-4o generation call it guards.
  Input ≈ case (≤1k) + draft (≤2k) + sources (≤8k) ≈ 3–4k tokens; output ≈ 30 tokens. Async, so
  the ~1–2 s added latency is invisible to reviewers.
- Escalation lever: if mini's judgment proves unreliable against the 21 labeled cases (below),
  point `Draft_Verify_Model__c` at full GPT-4o — still one call per would-be draft, one CMDT edit.

---

## Phase 2 — Claim-level fabrication check  *(deterministic; runs before the LLM gate)*

The lexical grounding check measures *aggregate* token overlap, so a fabricated `SSIC_Policy__c`
or an invented "500 documents/month" limit — built from source vocabulary — passes. This adds a
**per-token** requirement: every *concrete, verifiable* token in the draft must appear in a cited
source **or in the customer's own case text** (echoing the customer is not fabrication).

### What counts as a "concrete claim" (extract these; ignore prose)
| Type | Pattern | Example |
|---|---|---|
| API names | `\w+__(c|r|mdt|e|b|x)` | `SDOC__Has_Error__c`, `SSIC_Policy__c` |
| CamelCase identifiers | ≥2 humps, not sentence-start | `GenerateDocumentInvocable`, `ContentDistribution` |
| Quoted UI labels / menu paths | `"..."`, or `A > B > C` chains | `"Company Information > Feature Licenses"` |
| Code / attributes / syntax | back-ticked spans, `attr='...'`, `{{!...}}` | `` `format-number` ``, `autoopen='newtab'` |
| Numbers / versions / limits | quantities, thresholds, `v?\d+\.\d+` | `500`, `v6.1.10`, `200 documents` |
| URLs | absolute links | (already partly handled by `scrubUngroundedUrls`) |

Prose, generic verbs, product names ("S-Docs"), stopwords, and tokens already present in the
grounding stopword set are **not** claims.

### Algorithm (new `checkClaims(draftText, fed, input, cfg)`, deterministic Apex, 0 model calls)
1. Build `allowed` = normalized token set from every `fed` body+name **∪** `input.caseSubject`
   + `input.caseDescription` (case-insensitive, punctuation-normalized; keep exact API/CamelCase
   forms, don't over-stem — fabrication hides in the exact string).
2. Extract concrete tokens from `draftText` via the patterns above.
3. Any extracted token not in `allowed` → **decline**: `out.status = 'NO_DRAFT_UNGROUNDED'`
   (reuse existing value — this *is* an ungroundedness), note
   `"[claim check: unverifiable specifics: <tokens>]"`.

Runs **before** the metered LLM gate so fabrications are caught for free and never spend a call.
Gate off behind `Draft_Claim_Check_Enabled__c` (default true). Refinement knob
`Draft_Claim_Check_Max_Unverified__c` (default 0 — zero-tolerance, per the hard requirement;
exists only to loosen if a benign false-decline pattern emerges in eval).

**False-decline guard:** faithfully-reproduced drafts keep their concrete tokens in-source; the
`∪ case text` union prevents penalizing the model for echoing the customer's own field/error
names. This is why the check is safe to run at zero tolerance under precision-over-recall.

---

## Phase 3 — The screenshot problem  *(recommendation: (c) both, phased)*

6 FPs trace to errors visible only in attachments. The pipeline currently loads **no attachment
data whatsoever**, and `aiplatform.ModelsAPI` is used here as text-only (a multimodal request
shape is unproven in this managed package).

**Recommendation: (c) both, phased — (a) first for precision now, (b) later for recall.**
This directly serves precision-over-recall: the deterministic decline (a) removes the screenshot
FPs immediately and cheaply; vision (b) is the *recall-recovery* follow-up, gated on a spike.

- **Phase 3a — attachment-aware pre-generation decline (ship with Phases 1–2).**
  Detect image attachments on the case (`ContentDocumentLink`/`ContentVersion` with image
  `FileType`, plus inbound `EmailMessage` image attachments). If an image is present **and** the
  case text contains no concrete error/question token (reuse the Phase-2 extractor over
  Subject+Description), decline **before** the GPT-4o generation call — saving that call too.
  Requires plumbing a `hasImageOnlyError` boolean from the Flow/orchestrator (the Flow today
  passes only Subject/Description/Product). New status `NO_DRAFT_NEEDS_HUMAN_IMAGE` (or reuse
  `NO_DRAFT_LOW_CONFIDENCE` to avoid a picklist change — pick during execution). The Phase-1 LLM
  gate is the backstop for image cases that *do* carry some text.
- **Phase 3b — vision ingestion (later, gated on a spike).** Scope: (1) spike whether
  `aiplatform.ModelsAPI` (or a vision-capable Einstein model id) accepts image parts / a
  base64/`VersionData` payload — **unknown today**; if unsupported, no raw-LLM fallback is
  permitted (hard constraint: LLM access only via ModelsAPI). (2) Read attachment `VersionData`,
  send to a vision/OCR model, fold extracted error text into `caseDescription` before retrieval.
  Cost: +1 vision call per image case (heavier than mini). Defer until 3a's precision win is
  banked and the spike confirms feasibility.

---

## Phase 4 — Verification against the 21 labeled cases

### Re-eval procedure
- Re-run `scripts/apex/run_draft_eval_pinned.apex` (same 100 Case Ids) → `DraftEvalBatchJob` →
  new reviewer CSV; re-label the drafted subset; recompute precision on drafted cases.
- **Targets:** ≥90% precision on drafted cases · **0 fabricated specifics** (hard) · declines
  never regress · report the draft-rate lost (losing good drafts is acceptable; shipping bad
  ones is not).
- **Determinism caveat:** distillation *and* the new mini gate are sampled. Compare **aggregate**
  precision, not case-by-case flips. Because both new checks fail closed, sampling variance can
  only cost recall, never precision — safe direction. Optional hardening: run the LLM gate twice
  and require both approve (2×cost on would-be drafts) if a single-call gate proves jittery.
- **Fabrication assertion:** Phase-2 claim check is deterministic → assert 0 unverifiable
  specifics across all drafted cases as a pass/fail independent of the LLM.

### Predicted label-by-label outcome (all 21)
Mechanism: **CC**=claim check, **VG**=LLM verify gate, **IMG**=attachment guard.

| Case | Now | conf/score | Predicted | By | Note |
|---|---|---|---|---|---|
| 00034184 | good | HIGH/0.807 | **keep** | — | doc-limit error stated in text, faithfully grounded |
| 00033734 | good | HIGH/0.578 | **keep** | — | ContentDistribution fix, specific + grounded |
| 00034232 | good | MED/0.743 | keep* | — | next-signer HTML; at-risk if VG finds the ask thin |
| 00033725 | good | MED/0.634 | **keep** | — | Unicode-font bold fix, grounded |
| 00034155 | good | HIGH/0.528 | decline* | VG | "S-Sign Error" is vague; flipped FP↔good across runs — acceptable loss |
| 00034037 | good | HIGH/0.632 | **keep** | — | UI-sort-in-template, specific + grounded |
| 00034124 | good | HIGH/0.817 | **keep** | — | doc-limit error stated, grounded |
| 00033772 | good | HIGH/0.680 | **keep** | — | migrator `SDOC__Has_Error__c`; CC passes (token in source) |
| 00033913 | good | LOW/0.537 | keep* | — | doc-limit; subject vague but error string in body |
| 00034068 | good | LOW/0.721 | **keep** | — | `format-number` aliases; CC passes |
| 00033709 | good | HIGH/0.658 | **keep** | — | Pending File Creation steps, grounded |
| 00034050 | FP-ungr | HIGH/0.807 | **decline** | CC/VG | fabricated free-plan limit numbers not in source |
| 00034226 | FP-ungr | MED/0.743 | decline | CC/VG | near-twin of 00034232 but fabricates next-signer syntax — **residual risk** |
| 00033958 | FP-ungr | LOW/0.539 | **decline** | VG/IMG | flow error detail in screenshot; generic perms guidance |
| 00034122 | FP-ungr | LOW/0.626 | **decline** | CC | invented DOCX repeating-table/merge syntax → unverifiable tokens |
| 00033778 | FP-topi | HIGH/0.544 | **decline** | VG | answers a related config, not the actual ask |
| 00033698 | FP-topi | HIGH/0.570 | **decline** | IMG/VG | "Error when generating a doc" — error in screenshot; generic steps |
| 00033788 | FP-topi | HIGH/0.815 | decline* | VG | doc-limit answer topically strong but wrong for Quote-PDF — **hardest residual** |
| 00034062 | FP-topi | LOW/0.837 | **decline** | VG/CC | generic recordId advice vs `SSIC_Policy__c` SObjectException |
| 00033976 | FP-topi | HIGH/0.663 | **decline** | VG | speculative "typically configured…" cause, unsupported |
| 00033996 | FP-topi | LOW/0.510 | **decline** | IMG/VG | sandbox error in screenshot; generic Save-&-Refresh steps |

`*` = confidence-flip / residual-risk case.

**Predicted aggregate:**
- FPs: 10 → **decline ~9–10**. Residual risk on `00033788` (grounded, topically strong 0.815)
  and `00034226` (near-twin of a good draft) — target ≤1 surviving FP.
- Good: 11 → **retain ~8–9**, lose ~2–3 (`00034155` which was itself FP-adjacent, plus 1–2
  thin-specificity borderlines). All losses are declines, not wrong sends.
- **Result: ~9 good / ≤1 FP ≈ ≥90% precision** (up from 52%), **0 fabricated specifics**
  (enforced deterministically), at a **draft-rate cost of roughly one-half** (21 → ~10 on the
  100-set). Acceptable under precision-over-recall.

---

## Files to change (execution)

- `force-app/main/default/classes/SupportDraftingService.cls` — add `checkClaims` + `verify`
  (private, `@TestVisible`), a `VerifyResult`/`ClaimResult` struct, and the two calls at the
  accept seam (`:258`); extend `Config`/`loadConfig` for the new fields; add `NO_DRAFT_UNVERIFIED`
  to the status doc-comment/enumeration.
- `force-app/main/default/objects/Case/fields/AI_Draft_Status__c.field-meta.xml` — add
  `NO_DRAFT_UNVERIFIED` (and, if chosen for 3a, `NO_DRAFT_NEEDS_HUMAN_IMAGE`) **before** the flow
  references them.
- `force-app/main/default/flows/AutomatedEmailDrafting.flow-meta.xml` — map the new status(es);
  for 3a, plumb the image-attachment/no-concrete-error boolean into the orchestrator inputs.
- `force-app/main/default/objects/Support_Draft_Setting__mdt/fields/` + the `Default` record —
  new fields: `Draft_Verify_Enabled__c`, `Draft_Verify_Model__c`, `Draft_Claim_Check_Enabled__c`,
  `Draft_Claim_Check_Max_Unverified__c` (and a 3a toggle).
- `SupportDraftOrchestrator.cls` — Phase 3a only: attachment query + pre-generation guard.
- Tests: `SupportDraftingServiceTest` — mock the second `ModelClient` call; cover verify
  approve/decline/parse-error/throw (fail-closed) and claim-check verified/fabricated/case-echo.

## Verification (end-to-end)

1. **Unit:** `sf apex run test -l RunSpecifiedTests -t SupportDraftingServiceTest` (per the
   repo's RunSpecifiedTests convention — RunLocalTests is tanked by pre-existing broken Apex).
   Assert: fabricated-token draft → `NO_DRAFT_UNGROUNDED`; verify-decline / parse-error / callout
   throw → `NO_DRAFT_UNVERIFIED`; faithful draft echoing a customer field → `DRAFTED`.
2. **Deploy** picklist value first, then classes + CMDT + flow (two-phase deploy per the repo's
   platform-exception gotcha).
3. **Re-eval:** `sf apex run -f scripts/apex/run_draft_eval_pinned.apex -o vscodeOrg`, wait for
   the chain, `fetch_draft_eval.apex`, re-label the drafted subset. Confirm ≥90% precision, the
   claim-check 0-fabrication assertion, declines held, and record the draft-rate delta.
4. **Rollback:** all three checks are CMDT-gated — flip `Draft_Verify_Enabled__c` /
   `Draft_Claim_Check_Enabled__c` false to disable without a deploy.
