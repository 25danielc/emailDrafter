# help.sdocs knowledge-sync plan

How the public **help.sdocs.com** documentation corpus is ingested into `Support_Solution__c`. This
replaced the original Confluence connector: the source is now PUBLIC, sectioned product documentation,
which removes the multi-product split, the visibility gate, and the label-precedence layer the old
connector needed.

## Pipeline

```
HelpSdocsClient.listUrls(sections)        enumerate per-section sitemaps  -> List<UrlRef>
  -> HelpSdocsClient.fetchPage(ref)       GET <url>.md, clean markdown     -> DocPage
  -> SolutionClassifier.classify(...)     one ModelsAPI call per page      -> Classification
  -> SupportSolutionIngestionService.upsertPages(...)   idempotent upsert  -> Support_Solution__c
```

## Components

| Class | Responsibility |
|---|---|
| `HelpSdocsClient` | Thin REST layer over the public site (anonymous, behind the `Help_Sdocs` remote site). Two endpoints: per-section `sitemap-pages.xml` enumeration, and `<url>.md` markdown fetch. Callout sits behind a `Transport` seam so tests use a fake. |
| `HelpSdocsSyncService` | Orchestrates enumerate → fetch → classify → (preview \| upsert). `dryRun` (default) samples and writes nothing; a committing run flushes in chunks. Section → `Product__c` mapping; visibility forced `customer_safe`. Timestamp reconciliation deactivates pages removed from the site. |
| `HelpSdocsSyncQueueable` | Commits the full corpus by chaining: the first link enumerates once and carries the URL list down the chain; each link fetches/classifies/commits one offset window; the final link reconciles. Keeps every transaction within async callout/CPU/heap limits. |
| `SolutionClassifier` | Source-agnostic AI classification layer (shared seam). One strict-JSON ModelsAPI call per page across six axes; deterministic visibility gate; heuristic fallback when out of callout budget / in tests. |
| `SupportSolutionIngestionService` | Source-agnostic idempotent upsert keyed on the `Confluence_Page_Id__c` external id (named for the original source; now holds the help.sdocs URL path). Markup stripping, safe defaults, soft-delete. |

## Design notes

- **Sections** (`HelpSdocsClient.DEFAULT_SECTIONS`): `quick-start`, `sdocs`, `s-sign`, `developer-hub`.
  The changelog section is intentionally excluded (release notes, low drafting value).
- **Product** comes from the section: `s-sign` → S-Sign, `sdocs` → S-Docs; cross-cutting sections defer
  to the classifier's product call, then the default.
- **Visibility** is forced `customer_safe` — the corpus is already published to customers, so the
  classifier's deterministic gate does not apply. (To re-enable gating later, swap the forced value in
  `HelpSdocsSyncService.toPageInput()` for `cls.visibility`.) The classifier still runs: its audience /
  topic / format / trust / keyword outputs feed retrieval weighting and the audit trail.
- **Callout budget**: each page = 1 markdown fetch + 1 classify callout; the slice size (40) plus the
  per-slice sitemap reads stay under the 100-callout per-transaction ceiling.

## Running it

See [`../scripts/README.md`](../scripts/README.md). Order:
`helpsdocs_dryrun` → `purge_confluence_corpus` (one-time legacy purge) → `helpsdocs_commit`.
