/*
 * sync_help_docs.apex — ingest help.sdocs.com into Support_Solution__c.
 *
 * DRY_RUN = true  : previews a sample of what WOULD be written (synchronous callout budget:
 *                   1 fetch + 1 classify per page), writes nothing.
 * DRY_RUN = false : enqueues the async chain that enumerates the corpus, fetches + classifies +
 *                   upserts across slices, and finally deactivates stale records. Review a dry run
 *                   first. After the chain drains, run backfill_embeddings.apex to embed new rows.
 *
 * Verify a commit with:
 *   SELECT Product__c, Visibility__c, COUNT(Id) FROM Support_Solution__c
 *   WHERE Source_Space_Key__c IN ('quick-start','sdocs','s-sign','developer-hub')
 *   GROUP BY Product__c, Visibility__c
 */
Boolean DRY_RUN = true;

HelpSdocsConnector.SyncOptions o = new HelpSdocsConnector.SyncOptions();
o.sections = new List<String>{ 'quick-start', 'sdocs', 's-sign', 'developer-hub' }; // skip changelog
o.defaultProduct = 'S-Docs';
o.dryRun = DRY_RUN;
o.classify = true;     // run the AI classifier (audience/topic/format); visibility is forced customer_safe
o.sampleSize = 25;     // dry-run sample cap — keeps fetch+classify callouts under the 100/transaction ceiling

if (!DRY_RUN) {
    Id jobId = System.enqueueJob(new HelpSdocsConnector.HelpSdocsSyncQueueable(o));
    System.debug('Enqueued help.sdocs sync job: ' + jobId
        + ' — watch Setup > Apex Jobs (the chain re-enqueues per slice), then query Support_Solution__c.');
    return;
}

HelpSdocsConnector.SyncResult r = HelpSdocsConnector.run(o);

Map<String, Integer> bySection = new Map<String, Integer>();
Map<String, Integer> byProduct = new Map<String, Integer>();
Map<String, Integer> byType = new Map<String, Integer>();
Map<String, Integer> byAudience = new Map<String, Integer>();
for (HelpSdocsConnector.Preview p : r.previews) {
    bySection.put(p.section, (bySection.containsKey(p.section) ? bySection.get(p.section) : 0) + 1);
    byProduct.put(p.product, (byProduct.containsKey(p.product) ? byProduct.get(p.product) : 0) + 1);
    byType.put(p.solutionType, (byType.containsKey(p.solutionType) ? byType.get(p.solutionType) : 0) + 1);
    byAudience.put(p.audience, (byAudience.containsKey(p.audience) ? byAudience.get(p.audience) : 0) + 1);
}

System.debug('=== DRY RUN (sample ' + o.sampleSize + '): ' + r.pagesFetched + ' pages -> '
    + r.recordsBuilt + ' records ===');
System.debug('By section:  ' + bySection);
System.debug('By product:  ' + byProduct);
System.debug('By type:     ' + byType);
System.debug('By audience: ' + byAudience);
if (!r.errors.isEmpty()) { System.debug('ERRORS: ' + r.errors); }

System.debug('--- sampled records ---');
for (HelpSdocsConnector.Preview p : r.previews) {
    System.debug(p.section + ' | ' + p.product + ' | vis=' + p.visibility
        + ' | type=' + p.solutionType + ' | aud=' + p.audience + ' | ' + p.key);
}
