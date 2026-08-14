# caseCloser — Support Email Drafting System

A Salesforce DX project that turns inbound Support Cases into **reviewable email drafts**. When a
Case arrives, the system retrieves relevant solutions from a knowledge corpus, drafts a reply with a
native LLM (Einstein Trust Layer), and hands the agent a draft plus its sources and notes. It
**never auto-sends** — a human always reviews.

```
help.sdocs docs → Knowledge store → (Case trigger, Origin=Email) → Retrieve → Draft → Draft email on the Case Feed → Agent review
```

> Triage/assignment is a **separate external system** and is intentionally out of scope here — this
> project is only the parallel AI drafter. It reads triage outputs (e.g. product) but does not perform them.

## Stack constraints

- **LLM access only via `aiplatform.ModelsAPI`** (Einstein Trust Layer) — no raw external LLM callouts.
- **Retrieval is SOSL** (lexical). Embeddings may only re-rank a SOSL-narrowed pool, never the whole corpus.
- **Human-in-the-loop only** — a reviewable draft, never an auto-send. Hard exclusions
  (security / PII / legal / refund) are enforced *before* generation.
- Sandbox is metered (~500 Apex Models calls/hour) → one generation per case, no per-transaction loops.

## Architecture

| Subsystem | Component(s) | Responsibility |
|---|---|---|
| Knowledge store | `Support_Solution__c` (custom object) | Corpus of solutions; trust (`Source_Type__c`), safety (`Visibility__c`), format (`Solution_Type__c`), `Common_Case__c`, and `Embedding__c` axes |
| Store / ingestion | `SupportSolutionStore` | The write subsystem: source-agnostic idempotent upsert (keyed on the `Confluence_Page_Id__c` external id) + markup stripping + soft-delete; the async embedding Queueable that fills `Embedding__c`; and the common-case CSV seed (`ingestCsv`) with its DQ rules |
| Knowledge sync | `HelpSdocsConnector` | help.sdocs.com → `Support_Solution__c`: REST client (enumerate + fetch markdown, anonymous via the `Help_Sdocs` remote site), one-ModelsAPI-call-per-page strict-JSON classifier with a deterministic visibility gate, and the OFFSET-based sync service + chained queueable for callout limits |
| Retrieval | `SupportRetrievalService` | Two-tier SOSL + continuous BM25F-lite lexical ranking blended with embedding cosine; optional RRF fusion + common-case priority (config-gated, default off); HIGH/MEDIUM/LOW/NONE confidence |
| Generation | `SupportDraftingService` | One ModelsAPI call per case; hard guards + grounding checks before/after callout; confidence clamped to retrieval confidence; structured `NO_DRAFT_*` outcomes |
| Orchestration | `SupportDraftOrchestrator` | Single stateless entry point: retrieve → route escalate-only → one gated draft call; returns `{status, draftText, confidence, notes, sourceIds, modelName}` for the Flow to stamp |
| Draft delivery | `CaseDraftEmailPublisher` | On a `DRAFTED` outcome, inserts a **Draft** `EmailMessage` on the Case Feed (recipient/threading from the inbound email; From from `Reply_From_Address__c`) — never auto-sends. Requires the org "Enable Email Drafts" setting |
| Flow | `AutomatedEmailDrafting` | Record-triggered (Origin=Email), async: retrieve → draft → stamp `AI_Draft_*`; `DRAFTED` → publish draft email; `ESCALATE` → Slack; Apex fault → Slack alert |
| Config | `Support_Draft_Setting__mdt` | Thresholds, model name, prompt, retrieval/RRF/grounding knobs, reply-from address — tunable without a deploy |

Design rationale for every field and threshold lives in [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Repo layout

```
force-app/main/default/   Deployable Salesforce metadata (classes, flows, objects, customMetadata, permissionsets)
config/                   Scratch org definition
docs/                     Decision log, build checklist, knowledge-sync plan
scripts/apex/             Operational anonymous-Apex scripts (see scripts/README.md)
```

> Salesforce DX mandates the `force-app/main/default/<metadataType>/` layout: each `.cls` and its
> `.cls-meta.xml` are co-located by the Metadata API and cannot be separated.

## Documentation

- [`docs/DECISIONS.md`](docs/DECISIONS.md) — decision log (D1–D18) with rationale; source of truth for *why*.
- [`docs/build-checklist.md`](docs/build-checklist.md) — scope checklist and system contracts; source of truth for *what*.
- [`docs/helpsdocs-sync-plan.md`](docs/helpsdocs-sync-plan.md) — help.sdocs knowledge-sync architecture.
- [`docs/support-draft-guide.md`](docs/support-draft-guide.md) — agent-facing: how to find, review, and send the AI draft.

## Development

```bash
sf org login web                 # authorize an org
sf project deploy start          # deploy metadata
sf project retrieve start        # retrieve metadata
npm run prettier                 # format
npm test                         # LWC Jest (no LWC yet)
```

Operational scripts (seed corpus, sync help.sdocs, run a live trial) are in
[`scripts/apex/`](scripts/apex) — see [`scripts/README.md`](scripts/README.md).

## Testing

Apex tests mock the ModelsAPI callout and target ≥75% coverage (deploy gate). Test classes:
`SupportSolutionStoreTest`, `HelpSdocsConnectorTest`, `SupportRetrievalServiceTest`,
`SupportDraftingServiceTest`, `SupportDraftOrchestratorTest`, `CaseDraftEmailPublisherTest`.

```bash
sf apex run test --code-coverage --result-format human
```

Retrieval quality (precision@1 / recall@k / MRR, per-bucket and per-confidence-label) is measured
separately against a labeled set via `scripts/apex/eval_retrieval.apex` + the `RetrievalEvalSet` static
resource — this is the gate on flipping `Retrieval_Fusion_Mode__c` to `rrf`.

> **Deploy note:** the `Support_Draft_Setting.Default` custom-metadata *record* sets ~17 fields that are
> new to a fresh org. Deploy in **two phases** — the `objects/` fields first, then classes + the record
> + flow + permission sets — or the single-shot deploy fails with a platform `UNKNOWN_EXCEPTION`
> (a record cannot populate a field created in the same transaction).
