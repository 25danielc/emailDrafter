/*
 * seed_sdocs_common_cases.apex — seed the curated "most common support cases" into Support_Solution__c.
 *
 * Reads the SDocs_Common_Cases Static Resource (the case sheet exported as CSV) and runs it through
 * CaseSeedImporter.ingestCsv, which applies the agreed data-quality rules:
 *   - normalizes the glued/truncated Issue text; flags ambiguous rows to re-export
 *   - uses the JUNE Gitbook answer as the Body (the April column is ignored / retired)
 *   - no-answer rows ('--', blank, "No resolution recorded") -> agent_only + empty Body (never reply fuel)
 *   - marks every row Common_Case__c = true (priority-eligible)
 *
 * Idempotent: upsert is keyed on Confluence_Page_Id__c ('sdocs-case-<n>'), so re-running UPDATES in place.
 * After seeding it enqueues the SupportSolutionStore embedder so the new rows get embedding vectors (the
 * dense half of RRF).
 *
 * Run:  sf apex run --target-org vscodeOrg --file scripts/apex/seed_sdocs_common_cases.apex
 *
 * To seed the FULL set: replace force-app/main/default/staticresources/SDocs_Common_Cases.resource with the
 * full re-exported sheet (same columns), deploy it, and re-run this script.
 */

List<StaticResource> srs = [SELECT Body FROM StaticResource WHERE Name = 'SDocs_Common_Cases' LIMIT 1];
if (srs.isEmpty()) {
    System.debug(LoggingLevel.ERROR, '\nSDocs_Common_Cases static resource not found. Deploy it first:'
        + '\n  sf project deploy start -d force-app/main/default/staticresources/SDocs_Common_Cases.resource-meta.xml -o vscodeOrg');
} else {
    String csv = srs[0].Body.toString();
    CaseSeedImporter.SeedResult res = CaseSeedImporter.ingestCsv(csv);

    System.debug(LoggingLevel.ERROR, '\n=== SDocs common-case seed ==='
        + '\n  processed : ' + res.processed
        + '\n  failed    : ' + res.failed
        + '\n  no-answer (agent_only) : ' + res.noAnswer
        + '\n  rows needing re-export (DQ-2 ambiguous): ' + res.needsReview);
    for (String e : res.errors) { System.debug(LoggingLevel.ERROR, '  ingest error: ' + e); }

    // Body__c changed for every re-seeded common case, so their stored vectors are stale. Reset the sync
    // flag + clear the vector so the embedder re-embeds them from the new June text (not the old April text).
    List<Support_Solution__c> stale = [SELECT Id FROM Support_Solution__c WHERE Common_Case__c = true];
    for (Support_Solution__c s : stale) { s.Embedding_Synced__c = false; s.Embedding__c = null; }
    update stale;
    System.debug(LoggingLevel.ERROR, 'Reset embeddings on ' + stale.size() + ' common cases for re-embed.');

    // Embed the new rows (dense channel for RRF). Safe/resumable: only un-embedded active rows are picked up.
    Id embedJob = SupportSolutionStore.enqueue();
    System.debug(LoggingLevel.ERROR, '\nEmbedding backfill ENQUEUED: ' + embedJob);
}
