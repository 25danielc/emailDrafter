# Support Email Drafting System — Build Checklist

**Goal:** When a Case arrives, retrieve relevant past solutions / product-documentation content, draft a reply with a native LLM, and hand a *reviewable draft* to an agent — never auto-send.

**One-line data flow:**
`help.sdocs docs → Knowledge store → (Case trigger) → Retrieve → Draft → Review by agent`, with agent edits feeding back to improve the store.

**Stack reality (your org):** LLM via Apex `aiplatform.ModelsAPI` through the Einstein Trust Layer; retrieval via SOSL (lexical, no native vector index); orchestration via record-triggered Flow + async Apex invocable. Metered by Einstein Requests. You're in a sandbox (500 Apex Models calls/hour).

---

## Accepted risks (v1) — read before a postmortem

- **No situational-applicability gate.** *"v1 will produce version- and feature-mismatched drafts that
  are topically correct; the human reviewer is the sole guard against situational wrongness, and that is
  accepted for v1."* Path off the risk: ship the deferred `Version__c` / `Feature_Area__c` corpus fields
  once the (external) triage system extracts the matching Case-side value (see DECISIONS D17/D18).

---

## 0. Foundations — decisions to lock before building

- [ ] Confirm Einstein / Models API entitlement and the **Einstein Requests** allocation; identify who owns that budget
- [ ] Decide model per step (e.g. cheap mini for any classification, a stronger Trust-Boundary model for drafting); record the `modelName` values
- [x] Knowledge source: the PUBLIC help.sdocs.com docs (anonymous, via the `Help_Sdocs` remote site — no credential); pick which sections are in scope
- [ ] Lock the **human-in-the-loop policy**: draft only, never auto-send — get the support lead to sign off
- [ ] Define what "same issue" means for matching (topic + product + keywords); write it down
- [ ] Define the **do-not-auto-draft** categories (security incidents, data/PII exposure, legal/compliance, refunds/credits)
- [ ] Get data-governance / PII sign-off (Trust Layer keeps data in-boundary, but confirm it covers your chosen models)
- [ ] Pick success metrics now so you can instrument for them (draft acceptance rate, agent edit distance, first-response time, CSAT, cost per draft)

---

## 1. Knowledge store (the corpus)

- [x] Create custom object `Support_Solution__c`
- [x] Core fields: `Body__c` (Long Text), `Source_Type__c` (picklist: canned / tips / unsorted / query), `Product__c` (S-Docs / S-Sign), `Keywords__c`, `Confluence_Page_Id__c` (External ID, unique), `Confluence_URL__c`, `Last_Synced__c` (ops/sync-health, not freshness), `Active__c` (checkbox; also serves deprecation)
- [x] Safety axis (DECISIONS D14): `Visibility__c` (picklist: customer_safe / agent_only / escalate_only, default agent_only), `Has_Required_Disclaimer__c` (checkbox), `Required_Disclaimer_Text__c` (Long Text) + validation rule `Disclaimer_Text_Required_When_Flagged`
- [x] Format/intent axis (D15): `Solution_Type__c` (picklist: template / procedure / reference / explainer, default explainer)
- [x] Freshness + provenance (D16): `Source_Last_Modified__c` (DateTime, display-only), `Source_Space_Key__c`, `Source_Labels__c` (raw, for re-classification without re-fetch)
- [x] Field-level security for all of the above added to the `Support_Draft_System` permission set
- [x] `Embedding__c` (Long Text, JSON) wired as a cosine re-rank signal (D20); `Embedding_Synced__c` (Checkbox) added as the queryable backfill marker; both have FLS on the permission set
- [ ] CUT/DEFERRED per D17: `Error_Code__c`, `Symptom__c` cut; `Version__c`, `Feature_Area__c`, usage/`Acceptance_Rate__c`, `Superseded_By__c`, `Review_Status__c` deferred to their coupling triggers
- [ ] (Optional) child object `Solution_Chunk__c` if source pages are too long to embed/feed whole
- [ ] Verify org data-storage headroom (Setup → Storage Usage)

> **Contract:** produced by Ingestion (§2), consumed by Retrieval (§3). `Source_Type__c` is what lets the drafter weight trust (canned > tips > unsorted).

---

## 2. Ingestion pipeline (help.sdocs → store)

- [x] Bulk load via the `SupportSolutionStore` sync queueable chain (inner `SyncOptions` / `HelpSdocsSyncQueueable`, entry `SupportSolutionStore.run`; the standalone `HelpSdocsConnector` was merged in per D24): enumerate per-section sitemaps, fetch each page's markdown, classify, upsert
- [x] Normalize content: clean the GitBook markdown and strip residual markup to text (`SupportSolutionStore.stripHtml`); `Source_Type__c` set by the classifier's trust axis
- [x] Make upsert **idempotent** keyed on `Confluence_Page_Id__c` (the external-id field; holds the help.sdocs URL path) so re-runs update, not duplicate
- [ ] Ongoing sync: schedule the queueable (scheduled Apex) for new/changed pages
- [ ] Handle removals: archived/deleted pages set `Active__c = false` (don't draft from stale content)
- [ ] Account for **SOSL search-index lag** — freshly loaded records aren't instantly searchable; don't test retrieval immediately after a load
- [x] Generate + store `Embedding__c` per record at ingest via `createEmbeddings` (D20): the chained embedder Queueable in `SupportSolutionStore`, batched within the callout governor; `scripts/apex/backfill_embeddings.apex` seeds the existing corpus

> **Failure modes to handle:** API token expiry, partial loads, malformed HTML. Log every run; alert on failure.

---

## 3. Retrieval subsystem

- [x] Apex method: input = case context (topic, product, keywords); output = ranked candidate solutions + a coverage/confidence signal (`SupportRetrievalService.retrieve`)
- [x] Tier 1: SOSL AND-search over `Body__c`/`Keywords__c`, **pre-filtered by `Product__c`/topic**
- [x] Tier 2: broaden to a candidate pool (first-word / OR search, `LIMIT ~40`) when Tier 1 misses
- [x] Ranking: continuous BM25F-lite lexical score **blended with embedding cosine** (D20), config-gated; no LLM-picker (retrieval stays one deterministic pass + one embed callout). Optional **RRF fusion + common-case priority** (D25), opt-in behind `Retrieval_Fusion_Mode__c`. Eval: `eval_retrieval.apex` + `RetrievalEvalSet` measure precision@1 / recall@k / MRR, **per-bucket** (common vs general) and per-label precision (D23)
- [x] Define a **"no good match" threshold** that triggers the fallback path (confidence NONE/LOW → escalate/human)
- [x] Stay within SOSL limits (≤2,000 records/query, ≤20 SOSL/transaction)

> **Ceiling to accept:** SOSL gates *recall* — if the customer's wording shares no keywords with a solution, it's never surfaced. Embeddings only improve *ranking* of what SOSL found. Whole-corpus semantic search would require Data Cloud.

---

## 4. Generation subsystem

- [ ] Apex method `draftReply()`: assemble prompt = drafting instructions + case fields + retrieved solutions
- [ ] Use the structured drafting prompt: output **draft / sources used / agent notes**, with source-type trust weighting and escalation rules
- [ ] Set `modelName` to a stronger Trust-Boundary model for this step (quality matters more here than in triage)
- [ ] Robust parsing: strip markdown code fences and tolerate malformed JSON (reuse your triage parser approach)
- [ ] Return invocable outputs: `draftText`, `sourceIds`, `confidence`/`notes`
- [ ] Keep to **one generation per case** where possible (Apex callout + timeout limits)
- [ ] Cap the number/size of solutions fed in to stay within token budget

> **Failure mode:** empty or garbled generation → set confidence low → route to human (don't write junk to the Case).

---

## 5. Orchestration (Flow)

- [x] Record-triggered Flow on Case create (`AutomatedEmailDrafting`, separate from triage per D3)
- [x] Run the AI work on the **async** path (`AsyncAfterCommit`, as the triage flow does)
- [x] Reuse triage outputs (topic / account / urgency) as retrieval filters — `product` = triage topic, not re-derived
- [x] Add the drafting invocable action — one `SupportDraftOrchestrator` call, not chained retrieve+draft (D19)
- [x] Decision: confident draft? → orchestrator returns `DRAFTED`/`ESCALATE`/`NO_DRAFT_*`; ESCALATE branch pings Slack, all outcomes stamp the Case
- [x] **Fault path on the Apex action** → `Send_Failure_Alert` (Slack), never a silent failure
- [ ] Entry conditions: skip drafting for excluded categories/channels from §0 (`excluded` input wired, default false; real classifier is §7)

---

## 6. Output & human-in-the-loop

- [x] Decide where the draft lands: six `AI_Draft_*` Case fields (status / body / confidence / notes / source ids / model), stamped by the Flow (D19)
- [x] Surface **sources used + agent notes** next to the draft so the agent can verify before sending (`AI_Draft_Notes__c` + `AI_Draft_Source_Ids__c`)
- [ ] Make accept / edit / reject one click for the agent
- [ ] Enforce "never auto-send" in the flow
- [ ] Low-confidence / no-match → route to a human queue with a short holding note

---

## 7. Guardrails & safety

- [ ] Enforce hard exclusions *before* generation (security / legal / refund / PII categories)
- [ ] Confirm Trust Layer masking + zero-retention is active for the chosen models
- [ ] Prompt rule: no customer-specific claims unless present in the case data
- [ ] Cost/rate guard: cap drafts per time window; circuit-breaker that stops drafting on repeated errors or 429s
- [ ] Audit trail: record which solutions + which model produced each draft

---

## 8. Testing & deployment

- [ ] Apex test classes ≥75% coverage; **mock the Models API callout**
- [ ] Bulk test (many Cases created at once) to catch callout/timeout/governor limits
- [ ] Budget test runs against the **sandbox limit of 500 Apex Models calls/hour**
- [ ] Retrieval quality test on a labeled set of past cases (does it surface the right solution?)
- [ ] Explicitly test the no-match and escalation paths
- [ ] Deployment plan: named credentials, permission sets, change set / package, sandbox → prod

---

## 9. Observability & feedback loop *(this is what makes it improve)*

- [ ] Per-case log: retrieved IDs, chosen solution, model, draft, agent action (accepted/edited/rejected), edit diff
- [ ] Dashboard: draft acceptance rate, agent edit distance, first-response time, cost per draft
- [ ] **Close the loop:** agent edits + rejections flag weak/missing solutions → improvements flow back to the corpus (§1)
- [ ] Alerting: ingestion failures, callout errors, 429 rate limits, cost spikes
- [ ] Periodic human eval: sample drafts for quality and safety

---

## 10. Ops & maintenance

- [ ] Ingestion sync cadence + monitoring
- [ ] Einstein Requests consumption tracked against budget
- [ ] Model-version management (providers update models — re-test on change)
- [ ] **Prompt versioning:** store prompt text in custom metadata / custom setting so you can iterate without a code deploy
- [ ] Failure runbook (who fixes ingestion vs. flow vs. Apex)

---

## System contracts (the systems-thinking capstone)

For each subsystem, know its input, output, where state lives, and what happens when it fails. If any row's "on failure" is blank, that's an unhandled failure mode.

| Subsystem | Consumes | Produces | State lives in | On failure |
|---|---|---|---|---|
| Ingestion | Source pages (help.sdocs) | Solution records | `Support_Solution__c` | Log + alert; keep last good copy |
| Retrieval | Case context | Ranked candidates + confidence | (stateless) | Low confidence → human queue |
| Generation | Case + candidates | Draft + sources + notes | (stateless) | Low confidence → human queue |
| Orchestration | Case event | Routed outcome | Flow / Case | Fault path → human queue |
| Output | Draft + sources | Reviewable draft | Case / EmailMessage | Surface "no draft", assign human |
| Feedback | Agent actions | Corpus improvements | Logs → back to Ingestion | Metrics gap → review |

---

## Open questions to resolve with your supervisor

- [ ] Einstein Requests budget and who approves overages
- [ ] Lightning Knowledge included in your licenses? (would replace the custom object and add built-in search)
- [ ] Hard line on case data + models: which models are approved for support content
- [ ] Drafting in the same flow as triage, or a separate flow
- [ ] Which excluded categories must route straight to a human, no draft
