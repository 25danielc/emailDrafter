# Decision Log — Support Email Drafting System

Traceable record of choices and rationale. Newest decisions appended at the bottom of each section.
Source of truth for scope is `build-checklist.md`.

---

## Environment facts established (2026-06-22)

- The local `force-app` tree was an empty SFDX scaffold. The existing system lives only in the
  connected sandbox `vscodeOrg` (`dchen@sdocs.com.new.sfcr85part`, Enterprise Edition). Existing
  metadata was retrieved locally to extend, not reinvent.
- **Existing triage pattern (to reuse):**
  - `EinsteinTriageAction.cls` — invocable; `aiplatform.ModelsAPI` with model
    `sfdc_ai__DefaultOpenAIGPT4OmniMini`; SOSL via `Search.query` (Tier 1 AND-search in NAME fields,
    Tier 2 candidate pool `LIMIT 40` + LLM-picker fallback); `parseEinsteinJson()` strips ``` fences
    and tolerates malformed JSON; try/catch routes to a safe fallback.
  - `DispatchAIHandler.cls` — same ModelsAPI pattern, stronger model `sfdc_ai__DefaultGPT4Omni`.
  - `Automate_Triage` flow — Case **Create**, `RecordAfterSave` + `AsyncAfterCommit` (async path),
    **fault connector on every Apex action → Slack `Send_Failure_Alert`**. Stamps Case fields
    `Product_List__c` (S-Docs/S-Sign), `Org_ID_s__c`, `AccountId`, `Priority`. Status = Draft.
  - `AutomatedEmailDrafting` flow — a clone of the triage flow with entry filter `Origin = Email`;
    does no drafting yet.
- Named credentials present: `Gemini_API` (legacy; triage already migrated off it onto ModelsAPI),
  `Neverbounce_API`. **No Confluence credential exists.**
- No knowledge store object existed (`Support_Solution__c` is net-new).

## Hard constraints (design within, not around)

- LLM access only via `aiplatform.ModelsAPI` (Einstein Trust Layer). No raw external LLM callouts.
- Retrieval is SOSL (lexical). Embeddings may only re-rank a SOSL-narrowed pool, never whole-corpus.
- Sandbox metered at ~500 Apex Models calls/hour → aim for one generation per case, no generation
  loops per transaction, bulkify safely.
- Apex deploys need >=75% coverage with the ModelsAPI callout mocked.
- Human-in-the-loop only: reviewable draft + sources + notes, never auto-send. Hard exclusions
  (security / PII / legal / refund) enforced before generation.

---

## Decisions

### D1 — Knowledge store = custom object `Support_Solution__c` (§1)
Chosen over Lightning Knowledge. Full control over `Source_Type__c` trust weighting and SOSL-searched
fields; not dependent on unverified Lightning Knowledge licensing. (User decision, 2026-06-22.)

### D2 — Initial corpus = manual seed records (§2)
Seed a handful of representative S-Docs/S-Sign solutions now so retrieval (§3) can be verified on real
data before generation is built. Real Confluence sync (named credential + scheduled job) comes later.
(User decision, 2026-06-22.)

### D3 — Drafting orchestration = build out `AutomatedEmailDrafting` flow (§5)
The org already had a triage-flow clone (`AutomatedEmailDrafting`, entry filter `Origin = Email`).
Decision is to finish that as a separate drafting flow rather than extend `Automate_Triage` in place,
keeping triage and drafting decoupled and avoiding risk to the working triage path. This resolves the
checklist tension between "extend the existing triage flow" (§5) and the open question "same flow or
separate". (User decision, 2026-06-22.)

> **UPDATE 2026-06-24 (repo cleanup):** `AutomatedEmailDrafting` is now the single Case-create flow and
> a superset of the old triage flow (triage → dispatch → Slack → draft → escalate). The redundant
> `Automate_Triage` flow was **deleted**; its unique urgent-case branch (Priority=High + urgent Slack
> notify) was ported into `AutomatedEmailDrafting`. So the two-flow split above is now a one-flow design.

### D4 — Drafting model = `sfdc_ai__DefaultGPT4Omni` (§4)
The stronger model already used by `DispatchAIHandler`, matching §4's "stronger Trust-Boundary model
for drafting". Will be stored in custom metadata so it can change without a deploy. Subject to the
data-governance sign-off on approved models (§0). (User decision, 2026-06-22.)

### D5 — Include optional `Embedding__c` field now (§1/§3)
Added as nullable Long Text JSON at object creation so an embedding re-rank in §3 won't require a
later schema change. Left empty until/if embedding re-rank is built. (Build decision, 2026-06-22.)

### D6 — Permission set `Support_Draft_System` created in Phase 2 (pulled forward from §8)
Apex `Database.upsert` keyed on the `Confluence_Page_Id__c` External Id failed FLS
("field inaccessible") because brand-new custom fields have no field-level security by default.
Created the permission set (object CRUD + field read/edit on all `Support_Solution__c` fields) now
rather than at the §8 deployment step, and assigned it to the running user. This is the access
artifact the ingestion/retrieval/drafting automation users will need anyway. Future automation/
integration users must also be assigned this permission set. (Build decision, 2026-06-22.)

### D8 — Retrieval ranking is deterministic lexical (no LLM call), thresholds in custom metadata (§3)
Ranking = term-coverage (0.70) + Source_Type__c trust weight (0.15, canned&gt;tips&gt;unsorted&gt;query)
+ Tier-1 bonus (0.15), normalized ~0..1. Chosen over an LLM-picker so retrieval stays cheap and
stateless — we reserve the metered Models call for one generation per case. Embedding cosine re-rank
over the SOSL pool (`Embedding__c` exists) is the documented upgrade. Tunables
(`Retrieval_Tier2_Pool_Limit__c`, `Retrieval_Max_Candidates__c`, `Retrieval_Good_Match_Score__c`,
`Retrieval_Medium_Match_Score__c`) live in `Support_Draft_Setting__mdt` (record `Default`), editable
without a deploy. The class also carries identical hard-coded fallbacks so it runs if the record is
absent. (Build decision, 2026-06-22.)

### D9 — Confidence signal: HIGH / MEDIUM / LOW / NONE; HIGH requires Tier 1
`hasGoodMatch = topScore >= goodScore (0.45)` is the "no good match" gate that routes to a human.
HIGH is reserved for a good score reached via the strict Tier-1 AND search; a good score reached only
via the broadened Tier-2 OR search is downgraded to MEDIUM so the orchestration/reviewer treats
broadened matches with more caution. (Build decision, 2026-06-22.)

### D10 — CMT `Default` record created via Apex Metadata API, not the SOAP deploy
Deploying the `Support_Draft_Setting.Default` custom-metadata record through
`sf project deploy` repeatedly returned an opaque server `UNKNOWN_EXCEPTION` (0 component errors) in
this org, independent of value formatting. Created it instead via
`Metadata.Operations.enqueueDeployment` from anonymous Apex, which succeeded. The XML record file is
retained in source for traceability; if it blocks a future full-source deploy, exclude it via
`.forceignore` and manage the record through the API/UI. (Build decision, 2026-06-22.)

### D7 — Ingestion DML uses `allOrNone = false`
`upsertPages` / `deactivatePages` use partial-success DML so a single malformed row can't roll back
a whole load (checklist §2 "partial loads" + contract "keep last good copy"). Per-row failures are
returned in `IngestionResult.errors` for the caller to log/alert. (Build decision, 2026-06-22.)

### D11 — Generation guards BEFORE the Models call; one call per case; injectable model seam (§4)
`SupportDraftingService.draft()` short-circuits to `NO_DRAFT_EXCLUDED` (excluded category) or
`NO_DRAFT_NO_MATCH` (empty retrieval / confidence NONE) **before** any callout, so a metered Models
call is never spent on a case we must not or cannot draft. Exactly one `createChatGenerations` call
per case, on the configurable `sfdc_ai__DefaultGPT4Omni` (D4). Solutions fed are capped in count
(`Draft_Max_Solutions__c`=3) and size (`Draft_Solution_Char_Limit__c`=1200) for token budget. An empty
draft is split by cause (see D11.1): a parseable decline → `NO_DRAFT_LOW_CONFIDENCE`, a blank/garbled/
unparseable response or a callout exception → `NO_DRAFT_ERROR` + confidence LOW → human (never writes
junk back). The callout sits behind a `ModelClient` interface seam (`@TestVisible static client`) so
tests inject a stub and make no real callout — satisfying §8 "mock the Models API callout". (Build
decision, 2026-06-22.)

### D11.1 — A deliberate model decline is its own outcome (`NO_DRAFT_LOW_CONFIDENCE`), not `NO_DRAFT_ERROR`
QA of the live ingest→retrieve→draft path (`scripts/apex/qa_pipeline_report.apex`) found that when the
retrieved docs only topically overlap a case (e.g. a VPN question lexically matching "configure" in a
doc-gen procedure), the model correctly **declines** per prompt rule 3: it returns *valid JSON* with an
empty `draft`, a `LOW` confidence, and an `agent_notes` stating what is missing. The old code collapsed
that into `NO_DRAFT_ERROR` ("empty or unparseable") and discarded the model's reason — making a correct
decline indistinguishable from a genuine garble, and throwing away the single most useful signal for the
human reviewer and the §9 feedback loop. `draft()` now splits the empty-draft branch: a **parseable**
response with a non-blank `agent_notes` → `NO_DRAFT_LOW_CONFIDENCE`, confidence capped at LOW (clamped to
retrieval per D12), with the model's reason + `sources_used` preserved in the notes; anything else (parse
failure, no usable explanation, callout exception) stays `NO_DRAFT_ERROR`. Both still route to a human, so
the Flow's `Route_Draft_Outcome` default branch handles the new status unchanged; the value was added to
the `AI_Draft_Status__c` restricted picklist so the Flow can stamp it. The strictness itself is unchanged
and intentional (D18) — this is an *observability* fix that makes "the gate declined" measurable so the
prompt can later be tuned on real data. (Build decision, 2026-06-25.)

### D12 — Generation confidence is clamped to retrieval confidence
The draft's final confidence = `min(modelConfidence, retrievalConfidence)` on the
HIGH/MEDIUM/LOW/NONE ladder. A draft can never be more confident than the evidence it was built on,
so a model that over-claims HIGH on a Tier-2/MEDIUM retrieval is held to MEDIUM. Verified live: an
S-Docs merge-fields case retrieved MEDIUM, the model returned a HIGH-styled draft, and the result was
correctly clamped to MEDIUM. (Build decision, 2026-06-22.)

### D13 — `Draft_Prompt_Instructions__c` exists in CMT but is left blank; class default is authoritative
The prompt-versioning field (§10) exists on `Support_Draft_Setting__mdt` and is read by the service
when populated, so the prompt **can** be iterated without a deploy (edit the record in Setup). It is
deliberately left blank for now so there is a single maintained copy of the prompt (the `DEFAULT_PROMPT`
constant) rather than two copies that can drift. Populating the CMT field overrides the constant the
moment someone needs to tune the prompt without a deploy. (Build decision, 2026-06-22.)

### D14 — Schema gains a SAFETY axis (`Visibility__c`) separate from the TRUST axis (`Source_Type__c`)
Adversarial schema review established that `Source_Type__c` is a trust-weighting axis and cannot also
serve as a safety gate. Added `Visibility__c` (restricted picklist: `customer_safe` / `agent_only` /
`escalate_only`, **default `agent_only`**), read **deterministically before generation**:
`customer_safe` → draft; `escalate_only` → flip orchestration to the escalation branch (not a silent
drop); `agent_only` → surface to the agent as reference, never draft. Default-to-blocked is the
deliberate asymmetry — a forgotten/ambiguous label costs recall (recoverable by reclassifying), never a
customer-facing leak (not recoverable). Two-layer guard on internal content: `Source_Type__c = query`
is also excluded from the drafting retrieval set entirely. Required verbatim language (e.g. S-Sign
compliance) is carried by `Has_Required_Disclaimer__c` + `Required_Disclaimer_Text__c` and appended
**after** generation so a "be concise" instruction cannot drop it; a validation rule
(`Disclaimer_Text_Required_When_Flagged`) blocks flag-true-with-empty-text. (Design + build, 2026-06-22.)

### D15 — Schema gains a FORMAT/INTENT axis (`Solution_Type__c`), distinct from trust and safety
`Solution_Type__c` (restricted picklist: `template` / `procedure` / `reference` / `explainer`, **default
`explainer`**) controls how Drafting USES a record: template/procedure → reproduce faithfully, do not
truncate; reference/explainer → synthesize, truncatable. Populated by an ingestion body heuristic
(merge tokens, `ac:` macros, tables, step-lists) with a label override and a safe default — the safe
failure mode is "synthesize", never "reproduce prose as a verbatim template". This is also where the
symptom-vs-fix concern lives; it is explicitly NOT a separate `Symptom__c` field. (Design + build,
2026-06-22.)

### D16 — Trust/freshness fields are ranking/display inputs only, never eligibility gates (cold-start rule)
Mirror of the safety asymmetry: a trust/freshness field used as a hard eligibility gate would default
to "untrusted" and draft **nothing** (cold-start to zero). So such fields may only inform ranking or
agent-review display until the §9 feedback loop earns the data. The only v1 addition is
`Source_Last_Modified__c` (the Confluence `version.when` edit date, distinct from the `Last_Synced__c`
sync timestamp), **display-only** — edit-date is a poor proxy for truth, so no age gate or decay in v1.
`Last_Synced__c` is recategorized as an ops/sync-health field; retrieval ranking must not read it.
Deprecation reuses `Active__c` (no new field). Provenance fields `Source_Space_Key__c` /
`Source_Labels__c` (raw, as fetched) are kept so derived fields can be re-classified without re-fetching
Confluence. (Design + build, 2026-06-22.)

### D17 — Fields explicitly CUT and DEFERRED in the schema review
**Cut:** `Error_Code__c` (exact rare tokens are already matched by SOSL in `Body__c`/`Keywords__c`; an
exact-match boost is a scoring change, not a column); `Symptom__c` (a body/format concern owned by
`Solution_Type__c`, not a populatable scalar); `Review_Status__c` for v1 (no committed SME reviewer, so
it would default to a lie either direction; `Source_Type__c` is the v1 trust proxy). **Deferred, with a
coupling trigger (not a calendar):** `Version__c` and `Feature_Area__c` ship only when
`EinsteinTriageAction` emits the matching Case-side value (a filter field with no Case-side input is
dead weight); usage/`Acceptance_Rate__c` ships only when §9 writes per-solution accept/reject with an
attribution model (rate, not count); `Superseded_By__c` ships only when a runtime reader exists;
`Review_Status__c` returns only with `Last_Reviewed__c` + an owner and a committed reviewer.
(Design decision, 2026-06-22.)

### D18 — Accepted risk: v1 has no situational-applicability gate
**"v1 will produce version- and feature-mismatched drafts that are topically correct; the human reviewer
is the sole guard against situational wrongness, and that is accepted for v1."** Recorded here and in
the build checklist's accepted-risk section because it is the line a postmortem will quote. The path off
this risk is D17's deferred `Version__c` / `Feature_Area__c`, coupled to triage extraction. (User
decision, 2026-06-22.)

### D19 — Orchestration is one thin Apex invocable (`SupportDraftOrchestrator`), not chained Flow actions (§5/§6)
The Flow does **not** chain the retrieve and draft invocables itself. `AutomatedEmailDrafting` makes one
call to `SupportDraftOrchestrator.run(...)` (inputs: `$Record.Subject`, `$Record.Description`, and the
triage topic as `product` — blank Product = search both) and stamps the returned outcome onto the Case.
All branching lives in Apex so it is unit-testable; the Flow stays a trivial action + stamp + one
ESCALATE decision. `SupportRetrievalService.retrieve` and `SupportDraftingService.draft` are called as-is
and **untouched** — the orchestrator only builds the query, routes an escalate-only top match to
`ESCALATE` before paying for generation (D14), maps retrieval `Candidate`s to drafting `SolutionContext`s
(object-to-object, no JSON round-trip), and makes the one gated `draft()` call (which still owns the
hard-exclusion gate D11 and the customer-safe safety gate D14 — not duplicated in the orchestrator). The
`excluded` input is a §7 passthrough, default false, structured now and left for the real classifier later.
Outcome statuses: `DRAFTED` / `ESCALATE` / `NO_DRAFT_NO_MATCH` / `NO_DRAFT_EXCLUDED` /
`NO_DRAFT_LOW_CONFIDENCE` (D11.1) / `NO_DRAFT_ERROR`.
The draft lands on six new **Case** fields (`AI_Draft_Status__c`, `AI_Draft_Body__c`,
`AI_Draft_Confidence__c`, `AI_Draft_Notes__c`, `AI_Draft_Source_Ids__c`, `AI_Draft_Model__c`), with FLS
added to the `Support_Draft_System` permission set. Tests mock both services the way each is mocked in its
own suite: retrieval via inserted records + `Test.setFixedSearchResults`, drafting via the
`SupportDraftingService.ModelClient` stub — and assert the model is **not** called on the escalate /
no-match / excluded routes. (Build decision, 2026-06-24.)

**Fix (2026-06-24, live trial):** the first live trial returned `NO_DRAFT_ERROR` ("empty or unparseable
draft") on a good `customer_safe` match. Root cause was in `mapCandidates`, not retrieval/drafting:
it fed `Candidate.snippet` (Body truncated to 300 chars by retrieval) as the solution body. Given a
truncated `"..."` stub, the model obeys the prompt's "reproduce procedures faithfully / don't force a
draft if the solutions don't answer" rules and returns an **empty** `draft` field → `draft()` routes to
`NO_DRAFT_ERROR`. Confirmed by reproducing the exact prompt (empty draft, valid JSON) vs. the same prompt
with full bodies (clean draft). Fix: `mapCandidates` now fetches the full `Body__c` by Id (one SOQL;
bodies aren't on the lightweight candidate payload) and feeds that, falling back to the snippet only when
no record resolves. `retrieve()`/`draft()` remain untouched. Re-trial: `STATUS=DRAFTED`, confidence
`MEDIUM` (model HIGH correctly clamped to the MEDIUM retrieval per D12). 11/11 orchestrator tests pass.

### D20 — Semantic re-rank: `Embedding__c` cosine blended with the lexical score (§3, supersedes part of D8)
The lexical score measured vocabulary overlap, not whether a doc answers the question. We now blend an
embedding-cosine signal: `score = (1-w)·lexical + w·semantic`, `w` default 0.55, renormalized to pure
lexical whenever the semantic signal is N/A (doc has no vector / query embed failed / embeddings off) — the
blend can only **add** signal, never break the legacy path. Doc vectors are generated at ingest by a chained
Queueable (`SupportSolutionEmbedder`, batched within the callout governor; `backfill_embeddings.apex` seeds
the existing corpus) and stored in `Embedding__c`; the query is embedded once at retrieval (the one new
metered callout — retrieval was callout-free, an accepted change to the D8 pledge, gated OFF by default).
Model: `sfdc_ai__DefaultOpenAITextEmbeddingAda_002` (1536-dim — the strongest model that actually answers
in this org; `3-large`/`3-small`/Gecko are not enabled). **ada-002 cosines compress into a high band**
(~0.70 even for unrelated text), so the raw cosine is affinely rescaled from `[simFloor, simCeil]`
(defaults 0.70/0.90) onto [0,1]; the raw cosine is emitted in `ScoreBreakdown.semanticRaw` for calibration.
All knobs in `Support_Draft_Setting__mdt`. **ENABLED LIVE 2026-06-25** after the probe + backfilling all 246
active non-query rows; measured OFF→ON lift (8-pair eval, directional): precision@1 37.5%→50%, recall@k
62.5%→75%, MRR 0.431→0.594. Flip `Retrieval_Embedding_Enabled__c` back to false for the lexical baseline.
Perf note: with embeddings on, retrieval JSON-parses up to 40×1536 doubles/query (~2.3s CPU on a full pool;
safe at 1 case/txn, lower the pool limit for headroom). `Embedding_Synced__c` (Checkbox) was added because
`Embedding__c` is a Long Text Area and can't be filtered in SOQL — the embedder needs a queryable backlog
marker. **Honest ceiling:** SOSL still gates recall (a doc sharing zero tokens is never pooled, never
embedded-against); cosine measures topical similarity of *text*, not factual correctness. (Build decision,
2026-06-25.)

### D21 — Trust counted in ONE stage: the drafting prompt (supersedes the ±15% score tilt in D8)
The Source_Type__c trust signal was compounding across stages (a ±15% score tilt in retrieval **and** a
prompt statement). The score tilt is **removed** — relevance is no longer polluted by a reliability prior.
Trust now influences the answer in exactly one place, the drafting prompt (conflict arbitration + per-source
trust label), where it is actually actionable. It survives in retrieval only as a deterministic **tie-break**
in `Candidate.compareTo` (acts only when relevance is exactly equal, so it cannot compound). `trust01` is
still emitted in `ScoreBreakdown` as telemetry. (Build decision, 2026-06-25.)

### D22 — Retrieval scores + confidence flow into generation; explicit insufficiency signal (§4)
The ranking separation used to die at the drafting boundary (hard re-cap at 3, scores invisible, decline
inferred from an empty draft). Now: each fed solution carries `relevance: <score> (rank k of n)` and the
retrieval confidence is stated in the prompt; drafting feeds the docs retrieval's adaptive selection chose
(`Draft_Max_Solutions__c` 3→5, bounded by a total-char budget) instead of re-truncating to 3; and the model
emits an explicit `can_answer` (+ `missing`) — a structured decline honoured even if a draft string came
back, replacing the heuristic empty-draft inference (which stays as a fallback). The min-clamp of D12 is
kept but the two signals are no longer both called "confidence." **Closing the loop** (recording per-draft
outcomes for calibration) needs a storage decision (new `Draft_Outcome__c` SObject vs. existing fields) and
is deferred pending that call; the signals are all surfaced and ready to persist. (Build decision, 2026-06-25.)

### D23 — Labeled eval set + IDF honesty (§2/§3)
HIGH/MEDIUM/LOW were eyeballed; they are now **measurable**. `RetrievalEvalSet` (StaticResource JSON,
case→correct-page-id) + `eval_retrieval.apex` report precision@1 / recall@k / MRR and **per-confidence-label
precision@1** against the live corpus — run OFF then ON to quantify the embedding lift. Bootstrap baseline
(8 labeled pairs, lexical-only): precision@1 37.5%, recall@k 62.5%, **HIGH-label precision@1 50%**, 0/8
no-pool — i.e. every miss is a *ranking* failure (embeddings' target), not a SOSL recall ceiling. (Small N →
directional; expand to 30–50+ real resolved-case pairs.) On **IDF**: it stays POOL-RELATIVE (computed over
the ≤40 SOSL hits, not the corpus) and is now documented in-code as an explicit approximation, NOT treated
as cross-query comparable. We did not build corpus-IDF because cosine — pool-independent by construction —
carries the dominant weight of the absolute HIGH/MEDIUM bar when embeddings are on, mitigating the
comparability problem where it matters. Corpus-IDF remains a documented follow-up. (Build decision, 2026-06-25.)

### D24 — Codebase consolidation: 5 source classes on the drafter path (supersedes the multi-class layout of D1)
The scope of this project is **only the parallel AI drafter**; triage/assignment is a separate external
system that must not be interfered with. The build had accreted ~30 classes (many triage/dispatch and a
split ingestion/sync/classifier/embedder chain). Consolidated to the current set: **`SupportSolutionStore`**
(all writes — ingestion upsert + `stripHtml` + the async embedder + the common-case `ingestCsv` seed),
**`HelpSdocsConnector`** (help.sdocs REST client + per-page ModelsAPI classifier + sync service + chained
queueable), **`SupportRetrievalService`**, **`SupportDraftingService`**, **`SupportDraftOrchestrator`**, and
the delivery class **`CaseDraftEmailPublisher`** (D26). **Dropped** from this repo: `EinsteinTriageAction`,
`DispatchAIHandler` (triage is external), and the old `SupportSolutionIngestionService` /
`HelpSdocsClient` / `HelpSdocsSyncService` / `HelpSdocsSyncQueueable` / `SolutionClassifier` /
`SupportSolutionEmbedder` (merged into the two classes above). Earlier D-entries that name those classes
describe the pre-consolidation design and are historical. NOTE (2026-07-01): the target org still runs the
pre-consolidation classes — the consolidation is validated but **not yet deployed**. (Build decision, 2026-06-30.)

### D25 — Optional RRF fusion + common-case priority for the curated common cases (extends D20/D22)
For the curated "most common support cases" (`Common_Case__c = true`, seeded from the S-Docs case sheet),
retrieval can fuse the lexical and dense rankings with **Reciprocal Rank Fusion** —
`rrf(d) = w_bm25/(k + rank_lex) + w_dense/(k + rank_sem)` — and then apply a **gate-then-weight** priority
boost: a common case is boosted only if it clears a relevance gate (so priority never floats an off-topic
case onto a query it shouldn't win), capped at `Retrieval_Priority_Max_Promotions__c`. Every promotion is
recorded (`PriorityPromotion` → the `Priority_Promotion_Log__c` audit object) with base vs boosted rank so
the false-promotion rate is measurable. **Opt-in and inert by default**: `Retrieval_Fusion_Mode__c` =
`linear_blend`, so production behavior is unchanged (D20 path) until the per-bucket eval clears RRF. The
flip gate is `scripts/apex/eval_retrieval.apex` against the `RetrievalEvalSet` **common** bucket: flip to
`rrf` only if the common bucket's precision@1 improves without regressing the general bucket and with a low
false-promotion rate. Knobs all live on `Support_Draft_Setting__mdt`. (Build decision, 2026-06-29; eval
harness rebuilt + common-bucket labels added 2026-07-01.)

**EVAL RESULT (2026-07-01, vscodeOrg, embeddings ON, 51 labeled pairs) — KEEP `linear_blend`.** Measured
precision@1 (recall@5): common bucket **94.7% (94.7%) under BOTH modes** — priority adds nothing because the
common cases already rank #1 on merits; general bucket **53.1% (65.6%) under linear_blend vs 21.9% (28.1%)
under rrf** — RRF's normalized fused scores push correct docs out of the adaptively-selected set, a large
regression. Net: RRF gives zero common-case lift and badly regresses general retrieval, so the default
stays `linear_blend`. The RRF/priority code remains in place, inert and config-gated, for future revisiting
(e.g. per-bucket score normalization or a common-case-only code path) but is not enabled.

### D26 — Draft delivery as a reviewable EmailMessage, never an auto-send (§6)
On a `DRAFTED` outcome, `CaseDraftEmailPublisher` inserts an `EmailMessage` in **Draft** status
(`Status = '5'`) parented to the Case, with recipient/threading resolved from the inbound email and From
from `Support_Draft_Setting__mdt.Reply_From_Address__c` (blank → the running user; the agent picks one in
the composer). It **never sends** — a human reviews/edits/sends from the Case Feed. It is a separate class
from the orchestrator to preserve the orchestrator's stateless/no-DML contract; the Flow calls it on the
`DRAFTED` branch only. **Prerequisite:** the org "Enable Email Drafts" setting (Setup → Support Settings).
(Build decision, 2026-06-30.)

### D27 — Two-phase deploy: fields before the Default custom-metadata record
The `Support_Draft_Setting.Default` custom-metadata **record** populates ~17 fields (all the RRF/priority
knobs + `Reply_From_Address__c`) that are new to an org that predates them. Deploying the record in the same
transaction as the field definitions makes the platform throw a non-attributable
`UNKNOWN_EXCEPTION` (a record cannot set a field created in the same deploy). Deploy in **two phases**:
`force-app/main/default/objects` first (validated clean 2026-07-01), then classes + the customMetadata
record + flow + permission sets + static resources. (Build/ops decision, 2026-07-01.)

### D28 — Resilient retrieval for customer-phrasing recall misses (§3)
**Problem (case 00034467).** A customer describes a template error / PDF-not-attaching in prose + symptom
vocabulary ("standard template error", "failing to attach the PDF", "service agreement", "Work Order
#84920"); the fix docs are written in admin/schema vocabulary ("Fixing Template Errors After Template
Migration", `SDOC__Has_Error__c`). Measured root cause (two compounding failures, NOT the blend
"compressing" a pooled doc): **(1) recall** — `extractTerms` keeps only the first ~10 non-stopword tokens
in document order, so the greeting/boilerplate + generic SETUP terms ("automated document generation flow")
consume the whole budget and the discriminative SYMPTOM terms are truncated → SOSL never retrieves the fix
doc into the pool. **(2) scoring** — once pooled, the fix doc gets a STRONG lexical match (0.54–0.68) but its
embedding sits at ada-002's noise floor (raw cosine ~0.70–0.78 → rescaled ~0), and the semantic-LED blend
(weight 0.55) craters its content to ~0.45·lexical, below the 0.45 floor. With semantic≈0 no query change
alone can reach the floor.

**Fix (both OPT-IN via `Support_Draft_Setting__mdt`, default OFF = legacy behavior byte-for-byte):**
- **`retrieveResilient()`** — runs the normal pass; if `topScore < Retrieval_Distill_Trigger_Score__c`
  (default 0.45 = the draft floor) AND `Retrieval_Query_Distill_Enabled__c`, makes ONE Models chat call to
  distil the raw case into a focused search query, re-retrieves, and keeps **whichever pass is stronger**.
  Distillation can only help; any callout failure falls back to the lexical pass. The extra call is spent
  ONLY on cases that would otherwise miss the floor. `SupportDraftOrchestrator` now calls this instead of
  `retrieve()`; the core `retrieve()` is untouched (byte-for-byte, same callout profile).
- **Lexical-floor blend** (`Retrieval_Lexical_Floor_Frac__c`, default 0) — `content = max(blend,
  frac·lexical)`, so a weak/absent semantic signal can ADD but never SUBTRACT below a strong lexical match
  (fixing the asymmetry where a noise-floor embedding scored a doc WORSE than having no embedding at all). A
  high-semantic doc (blend > lexical) is untouched.

**Mode interaction (measured).** In `linear_blend` the floor reorders (content drives the score), so the fix
docs rank near the top and the case drafts. In `rrf` (current org default) the floor changes
`breakdown.content`/`topScore` but NOT the RRF rank, so it can't reorder — distillation still fixes recall
(the fix doc enters the returned candidate set, was absent), and the floor is a **no-op on ranking with no
spurious drafts** (`eval_resilient.apex`: no pair crosses the draft floor from the lexical floor), but a
generic page can still hold RRF rank-1 for this intent-split query. Getting a dead-semantic/strong-lexical
doc to RRF rank-1 is a deeper fusion change, out of scope. Validate + tune `frac` on `eval_resilient.apex`
before raising it. (Build decision, 2026-07-07.)

### D29 — Batch draft evaluation is a dry-run chained Queueable with a ContentVersion report
To measure the pipeline on real historical cases (drafted rate, status mix, confidence) without touching
them, **`DraftEvalBatchJob`** runs a fixed cohort of Case Ids through `SupportDraftOrchestrator.orchestrate()`
using the flow's exact three-field mapping (Subject / Description / Product_List__c) and writes one CSV
report to a ContentVersion — its only DML. Shape decisions: **chained Queueable** (embedder pattern, 5
cases/execution) because ~100 cases × 1–6 Models calls blows the 100-callout transaction limit and a prior
synchronous report harness died on CPU; **per-case try/catch** records an `ERROR` row so one failure never
kills the run; rows carry a 200-char draft excerpt, never full draft text (keeps serialized chain state
small). `Result.retrievalTopScore` was added (additive `@InvocableVariable`, ignored by the flow) so the
report gets a numeric score distribution instead of only the categorical confidence tag. Distillation
fired/won is parsed from the two stable audit phrasings in the orchestrator notes. Kickoff samples the
cohort randomly (Fisher-Yates over a 500-case pool, 365-day window) since SOQL has no random ordering.
Known accepted risk: an uncatchable `LimitException` in a chunk kills the chain and its accumulated rows —
mitigated by the small chunk; re-run with a smaller `CHUNK_SIZE` recovers. (Build decision, 2026-07-15.)

### D30 — Scoring fixes + deterministic intake pre-guards (2026-07-16 diagnosis follow-through)
Two measured retrieval defects fixed: **multi-select product values** (`'S-Docs;S-Sign'`) now split on `;`
into an `IN` filter in `soslSearch` (they previously matched nothing — 7/100 eval cases hard-zeroed to
NO_DRAFT_NO_MATCH), and **`topScore` reads content-max across the fed candidate set** (`contentMax()`)
instead of the RRF-rank-1 doc, since RRF ranks on reciprocal lexical+semantic rank, not the calibrated
content signal. Intake is now classified BEFORE the orchestrator by **`CaseIntakeClassifier`** — pure
regex/keyword, zero callouts, shared verbatim by the flow, `DraftEvalBatchJob`, and `CaseMiningJob` so
production and every measurement use the same denominator. JUNK (auto-replies, bounces, "Ticket received:"
ack loops, newsletters, invites) is stamped NO_DRAFT_EXCLUDED by the flow without calling the orchestrator;
BILLING rides the existing dormant `excluded`/`excludedReason` Request inputs and short-circuits in
`orchestrate()` before retrieval (both confirmed false-positive drafts in the 07-16 audit were billing
threads). Billing rules are precision-first with a troubleshooting veto (`error|invalid|fail...`) so
"invalid license key error" stays draftable. The headline metric is now **legit draft rate** =
DRAFTED / (intake == LEGIT) from the eval CSV's new `intake` column. (Diagnosis-driven, 2026-07-16.)

### D31 — Corpus mining: docs are generated ONLY from what agents actually sent (grounding rule)
**`CaseMiningJob`** (chained Queueable: HARVEST 5 cases/link → CLUSTER single link → GENERATE 3
clusters/link) turns closed, replied Email cases into `customer_safe` docs. Quality is mechanical because
ingestion is auto (no human review): extraction and generation prompts are grounded strictly in outbound
agent replies (drop when non-substantive / SKIP when incomplete), an adversarial second model call rejects
docs with claims unsupported by the sources (fail-closed on parse failure), a dedupe gate skips clusters
the existing non-mined corpus already answers at the draft floor (deterministic `retrieve()`, run BEFORE
generation is paid for), and PII/URL scrubbing + size/shape gates run last. Mined docs carry
`sourceSpaceKey='case-mined'` (outside the four help.sdocs reconcile sections — sync-safe, and the
one-command rollback key for `rollback_case_mined.apex`), `sourceType='tribal'`, deterministic pageIds
(seeds: `case-mined:seed:<slug>`; organic: SHA1 of member CaseNumbers), and `Mined_From_Cases__c`
provenance. **Discovered blocker:** the sfcr85part sandbox has no EmailMessage corpus (69 rows org-wide vs
9,761 Email cases) — the harvest phase can only run against production data; the 2026-07-16 seed backlog
docs were instead web-researched from public sources and ingested through the same path. (Build decision,
2026-07-16.)

---

## Open items awaiting supervisor sign-off (block go-live, not Phase 1)

- Einstein Requests budget + overage approver.
- Trust-Layer masking / zero-retention confirmed for `sfdc_ai__DefaultGPT4Omni`.
- Exact do-not-auto-draft exclusion categories + in-scope channels.
- Support-lead sign-off on draft-only / never-auto-send.
- Success metrics to instrument (acceptance rate, edit distance, FRT, CSAT, cost/draft).
- "Same issue" matching definition (topic + product + keywords).
- Both existing flows are Status = Draft (inactive); activation is the user's call.
