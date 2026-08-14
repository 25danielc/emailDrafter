# Codebase Cleanup — Audit & Phased Plan (2026-07-21)

## TL;DR

A full static audit (class call-graph, script references, custom-field usage — three
parallel sweeps) plus a live repo↔org reconciliation found that **the repo source is
already clean and consolidated**. There is essentially no dead code, no duplicate paths,
and no orphaned fields *in the repo*. The symptoms the request described (redundant
classes, conflicting implementations, dead methods, stale fields) describe the **org**,
which still runs the pre-consolidation architecture — the D24 consolidation was validated
but **never deployed**.

- **Done (safe, behavior-neutral):** deleted 1 empty stray file + 7 already-applied
  seed-ingest one-off scripts; corrected one stale doc name.
- **Held (blocked on a decision):** deleting the 3 CMDT config-setter scripts — their
  safety depended on "repo CMDT == org," which the reconciliation **disproved**.
- **Surfaced for a decision:** the repo and the org have diverged in **both directions**
  (details in §5). Resolving that is a deploy/data decision, not a cleanup, and is left to
  the user.

---

## 1. Inventory

### 1a. Apex classes (repo) — all ACTIVE

| Class | Entry point(s) | Callers (evidence) | Verdict |
|---|---|---|---|
| SupportSolutionStore | Queueable inner classes (`SupportSolutionEmbedder`, `HelpSdocsSyncQueueable`); `upsertPages`/`ingestCsv`/`enqueue`/`run`/`stripHtml` | CaseMiningJob, ingest/sync/backfill scripts | ACTIVE |
| SupportRetrievalService | `retrieve`, `retrieveResilient`, `embeddingClient` | Orchestrator (resilient), CaseMiningJob (retrieve), probe script | ACTIVE |
| SupportDraftingService | `draft` (single entry) | SupportDraftOrchestrator:75 | ACTIVE |
| SupportDraftOrchestrator | `@InvocableMethod run` → `orchestrate` | Flow, DraftEvalBatchJob, probe script | ACTIVE |
| CaseIntakeClassifier | `@InvocableMethod run` + `classify` | Flow, CaseMiningJob, DraftEvalBatchJob | ACTIVE |
| CaseDraftEmailPublisher | `@InvocableMethod publish` + `@AuraEnabled getLatestDraft/sendDraft` | Flow (publish), reviewAiDraft LWC (send path) | ACTIVE |
| CaseMiningJob | Queueable | run_case_mining.apex | ACTIVE |
| DraftEvalBatchJob | Queueable (PROTECTED) | run_draft_eval*.apex | ACTIVE |

Every public method has a caller. **No dead methods. No DUPLICATE. No DEAD. No UNKNOWN.**
All 8 have matching test classes (also ACTIVE). `CaseDraftEmailSender` — named in stale
memory as the LWC backend — **does not exist in the repo** (the LWC is wired to
`CaseDraftEmailPublisher`); it *does* still exist in the org (see §5).

### 1b. Scripts (`scripts/apex/`) — 24 audited, 0 dangling symbols

**KEEP — reusable TOOLs / PROBEs (11):** `sync_help_docs`, `seed_sdocs_common_cases`,
`backfill_embeddings`, `fetch_draft_eval`, `fetch_probe`, `rollback_case_mined`,
`run_case_mining`, `run_draft_eval`, `export_corpus` (PROTECTED), `probe_retrieval`,
`probe_draft_regen`.

**KEEP — §6 baseline harness (3):** `run_draft_eval_pinned`, `run_draft_eval_brun`,
`run_draft_eval_labeled21` (frozen cohorts; reproduce the pre-cleanup eval baseline).

**DELETED this pass (7):** `ingest_seed_docs_part1..4`, `ingest_seed_docs_c2_part1..3` —
idempotent upserts already applied to the org corpus; content preserved in the protected
`docs/corpus-snapshot.json`. No inbound references.

**HELD — not deleted (3):** `set_draft_setting_values`, `enable_precision_gates`,
`set_verify_model_gpt4o` — see §4/§5.

### 1c. Custom fields — 0 orphaned

Every `Support_Solution__c` (17), `Case` AI_Draft (6), and `Support_Draft_Setting__mdt`
(34) field is read or written by a live path. Fields that are write-only *by code*
(`AI_Draft_Body/Confidence/Source_Ids/Model`, `Mined_From_Cases__c`, `Confluence_URL__c`)
are intentional human/audit outputs, **not deletion candidates**. No field is deleted
(Salesforce field deletion is destructive; none is unused). `Last_Synced__c` is correctly
excluded from retrieval ranking (D16).

---

## 2. Conflict map — none in the repo

- `retrieve()` vs `retrieveResilient()` — **layered, not duplicate.** Resilient wraps
  retrieve + one distillation retry. Production→resilient; mining→retrieve (wants
  determinism). Intentional two-tier API.
- Drafting: **one** `draft()` entry with three independently config-gated faithfulness
  checks (grounding / claim-check / verify). Not parallel draft paths.
- Intake logic lives only in `CaseIntakeClassifier`; the orchestrator consumes its
  `excluded` flag. No duplication.
- `applyRrfFusion()` is called (SupportRetrievalService:286) — reachable, not dead.

**No latent "fix landed in one twin not the other"** — there are no twins in the repo.
All real mismatches are **repo↔org**, not repo-internal (see §5).

---

## 3. Protected list (not touched)

All 8 source + 8 test classes; the flow `AutomatedEmailDrafting`; the `reviewAiDraft` LWC;
both permission sets; `SDocs_Common_Cases` static resource; the
`customMetadata/Support_Draft_Setting.Default` record; `DraftEvalBatchJob(.cls/Test)`;
`scripts/apex/export_corpus.apex`; the three pinned-eval driver scripts; **all of `docs/`**
(eval CSVs/JSONs, `corpus-snapshot.json`, `eval-drafts-reviewed-2026-07-20b.csv`,
diagnosis files, plans, guides, DECISIONS). No custom field deleted.

---

## 4. Phased plan — status

### Phase 0 — Reconciliation & baseline *(RAN — findings in §5)*
Snapshotted the repo, retrieved the org versions of the 16 classes + CMDT record + flow +
both permission sets, diffed, then **restored the repo** (the retrieve had overwritten repo
files with the older org versions). Result: **major bidirectional divergence** — see §5.

### Phase 1 — Zero-risk deletions *(DONE, partial)*
- ✅ `trial.md` (0 bytes) — deleted.
- ✅ 7 seed-ingest scripts — deleted (evidence in §1b).
- ⛔ 3 CMDT config-setter scripts — **HELD.** The plan gated their deletion on
  "`customMetadata/Support_Draft_Setting.Default.md-meta.xml` == the live org record." The
  reconciliation **disproved** that (the repo file and the org record differ on ~15 fields;
  §5). Deleting them now would remove the only in-repo trace of config edits while the repo
  record itself is not a faithful capture of org config. Revisit after §5 is resolved.

### Phase 2 — Doc-consistency edits *(DONE, partial)*
- ✅ `build-checklist.md` §2 — `HelpSdocsConnector` → `SupportSolutionStore` sync queueable
  (merged per D24), keeping the historical name as a pointer.
- ⛔ `DECISIONS.md` D25 edit — **dropped.** The planned note ("`Priority_Promotion_Log__c`
  was never built") is **false**: the object exists in the org (§5). Writing it would
  introduce an error. The accurate divergence is recorded here in §5 instead.
- ⛔ `README.md` rewrite — **held** pending the §5 decision (what's "true" depends on which
  direction the divergence is resolved).

### Phase 3 — Refactors *(none)*
No class renames, method moves, or field deletions warranted in the repo.

---

## 5. Reconciliation findings (repo ↔ org `vscodeOrg`) — **the real issue**

The repo is **not** a drift-from-a-shared-baseline; it is an **undeployed next-version**
that diverges from the running org in both directions. Evidence gathered 2026-07-21.

### 5a. Org runs the full pre-consolidation class set (D24 never deployed)
Org has **16** project-domain Apex classes; the repo has **8**. Present in the org but
**dropped from the repo** (merged/retired by D24):

| Org-only class | ~size | Repo disposition |
|---|---|---|
| CaseDraftEmailSender (+Test) | 5.0k | send path merged into `CaseDraftEmailPublisher` |
| HelpSdocsConnector | 38.2k | merged into `SupportSolutionStore` inner classes |
| HelpSdocsClient | 6.0k | merged into `SupportSolutionStore` |
| HelpSdocsSyncService | 12.9k | merged into `SupportSolutionStore` |
| SupportSolutionIngestionService | 8.3k | merged into `SupportSolutionStore` |
| SupportSolutionEmbedder | 3.8k | now a `SupportSolutionStore` inner Queueable |
| EinsteinTriageAction | 10.4k | out of scope (triage is external) — retired |
| DispatchAIHandler | 7.3k | out of scope — retired |

Matches D24's own note (2026-07-01): *"the target org still runs the pre-consolidation
classes — the consolidation is validated but not yet deployed."*

### 5b. Repo is AHEAD on the send path
Org `CaseDraftEmailPublisher` (375 lines) has **no** `getLatestDraft`/`sendDraft`; the org
runs the **two-class** send architecture (separate `CaseDraftEmailSender` + `…SenderTest`,
+ the `reviewAiDraft` LWC, all present in org). The repo `CaseDraftEmailPublisher`
(419 lines) folds the send methods in and drops `CaseDraftEmailSender`. **The repo's merge
refactor was never deployed.**

### 5c. Org is AHEAD on retrieval schema (RRF/priority family)
The org's live `Support_Draft_Setting.Default` record has fields the **repo schema does not
define**: `Retrieval_Fusion_Mode__c = rrf`, `Retrieval_RRF_K__c`,
`Retrieval_RRF_Weight_BM25__c`, `Retrieval_RRF_Weight_Dense__c`, `Retrieval_Priority_Weight__c`,
`Retrieval_Priority_Max_Promotions__c`, `Retrieval_Priority_Gate_Mode/Tau_Lex/Tau_Sem__c`,
`Draft_Grounding_Judge_Enabled__c`, `Draft_Min_Corroborating_Docs__c`. The
**`Priority_Promotion_Log__c` object also exists in the org** (with `Common_Case_Admin`
granting FLS on it) but **not in the repo**. The org is running **RRF**; the repo is
linear-blend-only with a simpler internal RRF path.

### 5d. Org CMDT is running on fallbacks where the repo has explicit values
Fields **populated in the repo record but NULL in the org**: `Draft_Call_Offer_Text__c`,
`Reply_From_Address__c`, `Draft_Grounding_Block_Ratio__c`, `Draft_Grounding_Min_Overlap__c`,
`Draft_Max_Retries__c`, `Retrieval_Cluster_Gap__c`, `Retrieval_Select_Abs_Floor__c`,
`Retrieval_Select_Rel_Frac__c`. (Precision-gate fields — verify/claim-check — **match**.)

### 5e. Consequence
Deploying the repo → org would **change org behavior** (drop RRF + `Priority_Promotion_Log__c`,
replace the send architecture, apply the repo's config values). Pulling org → repo would
**regress** the consolidation and the send-path merge. Neither direction is a "cleanup." A
deliberate, component-by-component reconcile + deploy decision is required — **out of scope
for this behavior-neutral pass and left to the user.**

---

## 6. Verification gate

This pass changed **only** non-deployed artifacts: deleted anonymous-Apex scripts + one
empty file, and edited one Markdown doc. **Zero deployed metadata changed** (no class,
field, flow, CMDT record, permission set, LWC). Therefore the runtime pipeline is
unchanged by construction.

- **Repo integrity:** the 16 classes + flow + CMDT + permission sets were restored
  byte-for-byte to their pre-audit state after the reconciliation retrieve (verified: no
  diff vs snapshot; `CaseDraftEmailPublisher` back to 419 lines with the send path).
- **Optional confirmation:** `run_draft_eval_brun.apex` (pinned 100-case cohort) may be
  re-run; deterministic columns (intake, non-distilled status/topScore) will match the last
  baseline within the pipeline's known LLM-sampling noise (distillation/verify are unseeded —
  near-floor scores can flip run-to-run independent of this pass).
- Nothing was deployed, so no test run or deploy validation is required for these changes.

---

## 7. Recommended next decision (for the user)

The cleanup surfaced that the actionable work is **not** repo cruft but the **repo↔org
divergence** (§5). Options to choose from:
1. **Deploy the consolidation** (repo → org): retire the 8 old org classes + reconcile
   config. Behavior-changing (drops org RRF + `Priority_Promotion_Log__c`); needs an eval
   before/after and a go decision. Largest cleanup, highest risk.
2. **Adopt the org as truth** (org → repo): bring the RRF field family, `Priority_Promotion_Log__c`,
   and `CaseDraftEmailSender` back into the repo; abandon the merge/consolidation. Regresses
   prior work.
3. **Reconcile per-component** deliberately (recommended): keep the repo's consolidation +
   send-path merge, port the org's RRF/priority schema decision explicitly (deploy or drop),
   sync the CMDT record to intended values, then deploy once. Then the 3 held config-setter
   scripts + the DECISIONS/README edits can finish safely.
