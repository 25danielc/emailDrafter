# Operational scripts

Anonymous Apex run on demand against a connected org. Execute with:

```bash
sf apex run --target-org <alias> --file scripts/apex/<file>.apex
```

(or in VS Code: *SFDX: Execute Anonymous Apex with Editor Contents*).

| Script | Purpose | Writes? |
|---|---|---|
| `sync_help_docs.apex` | help.sdocs ingestion. `DRY_RUN = true` (default) previews counts + sampled per-record classification; `DRY_RUN = false` enqueues the async `HelpSdocsConnector.HelpSdocsSyncQueueable` chain that writes `Support_Solution__c` and deactivates stale rows | Only when `DRY_RUN = false` — review a dry run first |
| `seed_sdocs_common_cases.apex` | Seed the curated most-common support cases from the `SDocs_Common_Cases` static resource via `CaseSeedImporter.ingestCsv` (JUNE Gitbook answer → Body, no-answer→agent_only, `Common_Case__c=true`), then enqueue the embedder | Yes (idempotent upsert, keyed on `sdocs-case-<n>`) |
| `backfill_embeddings.apex` | Enqueue `SupportSolutionStore.enqueue()` to fill `Embedding__c` on active rows missing a vector (the dense half of retrieval / RRF) | Yes (writes `Embedding__c`) |
| `run_draft_eval.apex` | Dry-run batch eval: enqueue the chained `DraftEvalBatchJob` over a random cohort of existing Cases (flow-parity field mapping). `DRY_PREVIEW = true` (default) prints the sampled cohort only | Two ContentVersions at completion — a `Draft Eval …` CSV (reviewer-spec column order) and a `Draft Eval Detail …` full-text JSON — zero Case writes, no draft emails |
| `fetch_draft_eval.apex` | List recent `Draft Eval …` report ContentVersions and print the REST download command | No |
| `export_corpus.apex` | Snapshot every active `Support_Solution__c` (Id/Name/Body/product/visibility) to a `Support Corpus Snapshot` ContentVersion — the ground-truth doc set the post-run reviewer agents label the eval against | One disposable ContentVersion |
| `set_gate_mode_demote.apex` | Flip `Draft_Gate_Mode__c` to `demote` (failed verify/claim/grounding gates stamp `[NEEDS REVIEW]` + LOW confidence but still DRAFT) via the Apex Metadata API; edit to `block` for the fail-closed rollback | CMDT record (async — verify with a read) |
| `set_phase2_settings.apex` | Lower `Retrieval_Distill_Accept_Margin__c` 0.10 → 0.05 via the Apex Metadata API | CMDT record (async) |
| `run_case_mining_import.apex` | `run_case_mining.apex` variant whose cohort is the cases holding imported preprod reply threads (Subject tag `[MINING-IMPORT-2026-07-21]`, built by `scripts/data/build_mining_import.js` + `sf data import bulk`) | Same as `run_case_mining.apex` when `DRY_PREVIEW = false` |
| `rollback_mining_import.apex` | Delete the imported preprod reply EmailMessages by Subject tag (`DRY_PREVIEW` first); mined docs roll back separately via `rollback_case_mined.apex` | Yes when `DRY_PREVIEW = false` |

Typical order (fresh corpus): `sync_help_docs` (dry run) → `sync_help_docs` (`DRY_RUN = false`) →
`seed_sdocs_common_cases` → `backfill_embeddings` → (let SOSL index catch up).
