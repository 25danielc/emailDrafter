/**
 * backfill_embeddings.apex — generate Support_Solution__c.Embedding__c for the existing corpus.
 *
 * Embedding vectors are the corpus half of the retrieval semantic re-rank (#1). This kicks off the
 * chained SupportSolutionStore embedder Queueable, which embeds every Active, non-query row whose
 * Embedding__c is null (batched per callout, chaining until the backlog drains). Safe to re-run:
 * already-embedded rows are skipped, so it resumes where it left off.
 *
 * To FORCE a full re-embed (after changing the embedding model, or a large body edit), uncomment the
 * null-out block below FIRST, run once to clear, then run again to regenerate. Clearing and regenerating
 * are separate runs on purpose (the null-out is a DML you should see the count of before spending callouts).
 *
 * Prereq: an approved embedding model must answer in this org. The model is read from
 * Support_Draft_Setting__mdt.Retrieval_Embedding_Model__c (blank -> ada-002 default).
 *
 * Run: sf apex run -f scripts/apex/backfill_embeddings.apex -o vscodeOrg
 */

// --- OPTIONAL: force a full re-embed by clearing the sync flag first (uncomment, run, then re-run) ---
// List<Support_Solution__c> clear = [SELECT Id FROM Support_Solution__c WHERE Embedding_Synced__c = true];
// for (Support_Solution__c s : clear) { s.Embedding__c = null; s.Embedding_Synced__c = false; }
// update clear;
// System.debug(LoggingLevel.ERROR, 'Cleared ' + clear.size() + ' existing embeddings.');

Integer pending = [
    SELECT COUNT() FROM Support_Solution__c
    WHERE Active__c = true AND Embedding_Synced__c = false AND Source_Type__c != 'query'
];
Integer total = [SELECT COUNT() FROM Support_Solution__c WHERE Active__c = true];
System.debug(LoggingLevel.ERROR, 'Embedding backfill: ' + pending + ' of ' + total
    + ' active rows need an embedding.');

if (pending == 0) {
    System.debug(LoggingLevel.ERROR, 'Nothing to do. All active rows are embedded.');
} else {
    Id jobId = SupportSolutionStore.enqueue();
    System.debug(LoggingLevel.ERROR, 'Enqueued SupportSolutionStore embedder job ' + jobId
        + '. It chains until the backlog drains. Re-run this script to check remaining count / resume.');
}
