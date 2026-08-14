/**
 * run_draft_eval.apex — dry-run the draft pipeline over a random cohort of existing Cases.
 *
 * Enqueues the chained DraftEvalBatchJob, which calls SupportDraftOrchestrator.orchestrate()
 * per case with the SAME three-field mapping the production flow uses (Subject / Description /
 * Product_List__c). It NEVER writes to Cases and NEVER creates draft emails — the only write of
 * the whole run is one ContentVersion CSV report ('Draft Eval <RUN_LABEL>') at completion.
 * Fetch the report with scripts/apex/fetch_draft_eval.apex.
 *
 * Cost note: each case spends 1–3 Models API calls (embedding + optional distill re-pass +
 * generation where the gates pass). Preview the cohort first; smoke-test with COHORT_LIMIT = 3
 * before spending a 100-case run.
 *
 * Run: sf apex run -f scripts/apex/run_draft_eval.apex -o vscodeOrg
 */

// ===================== EDITABLE COHORT =====================
Boolean DRY_PREVIEW  = true;            // true = print the sampled cohort only; false = enqueue the run
Integer COHORT_LIMIT = 100;             // 3 for the smoke test, 100 for the real run
Integer CANDIDATE_POOL = 500;           // random sample is drawn from up to this many matching cases
String  RUN_LABEL    = 'eval-fresh-2026-07-16';
// Wider-window cohort: Email-origin cases from the last 12 months the live pipeline has not
// stamped. Delete the AI_Draft_Status__c line to include already-processed cases (re-run compare).
// Description is a long text area (not filterable in SOQL) — blank ones are skipped client-side.
String  COHORT_SOQL  =
      'SELECT Id, CaseNumber, Subject, Description, Product_List__c, CreatedDate FROM Case '
    + 'WHERE Origin = \'Email\' AND Subject != null '
    + 'AND (NOT Subject LIKE \'%SANDBOX TEST%\') '   // internal test emails skew the stats
    + 'AND AI_Draft_Status__c = null '
    + 'AND CreatedDate = LAST_N_DAYS:365 '
    + 'ORDER BY CreatedDate DESC LIMIT ' + CANDIDATE_POOL;
// ===========================================================

List<Case> pool = new List<Case>();
for (Case c : (List<Case>) Database.query(COHORT_SOQL)) {
    if (!String.isBlank(c.Description)) { pool.add(c); }
}

// SOQL has no random ordering: Fisher-Yates the candidate pool, then take the first COHORT_LIMIT.
for (Integer i = pool.size() - 1; i > 0; i--) {
    Integer j = (Integer) Math.floor(Math.random() * (i + 1));
    Case tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp;
}
List<Case> cohort = new List<Case>();
Map<String, Integer> byProduct = new Map<String, Integer>();
for (Case c : pool) {
    if (cohort.size() >= COHORT_LIMIT) { break; }
    cohort.add(c);
    String p = String.isBlank(c.Product_List__c) ? '(blank)' : c.Product_List__c;
    Integer n = byProduct.get(p);
    byProduct.put(p, (n == null ? 0 : n) + 1);
}

System.debug(LoggingLevel.ERROR, 'Candidate pool: ' + pool.size() + ' cases; sampled cohort: '
    + cohort.size() + ' (target ' + COHORT_LIMIT + ').');
System.debug(LoggingLevel.ERROR, 'Cohort by product: ' + JSON.serialize(byProduct));
for (Integer i = 0; i < Math.min(10, cohort.size()); i++) {
    String subj = cohort[i].Subject;
    if (subj.length() > 60) { subj = subj.substring(0, 60) + '...'; }
    System.debug(LoggingLevel.ERROR, '  sample[' + i + '] ' + cohort[i].CaseNumber + '  ' + subj);
}

if (DRY_PREVIEW) {
    System.debug(LoggingLevel.ERROR, 'DRY_PREVIEW = true: nothing enqueued. Flip to false to run.');
} else if (cohort.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Cohort is empty; nothing to enqueue.');
} else {
    List<Id> ids = new List<Id>();
    for (Case c : cohort) { ids.add(c.Id); }
    Id jobId = System.enqueueJob(new DraftEvalBatchJob(ids, RUN_LABEL));
    System.debug(LoggingLevel.ERROR, 'Enqueued DraftEvalBatchJob ' + jobId + ' over ' + ids.size()
        + ' cases (~' + Math.ceil(ids.size() / 5.0) + ' chained executions). Monitor with:');
    System.debug(LoggingLevel.ERROR, '  SELECT Status, ExtendedStatus, CreatedDate FROM AsyncApexJob '
        + 'WHERE ApexClass.Name = \'DraftEvalBatchJob\' ORDER BY CreatedDate DESC LIMIT 25');
    System.debug(LoggingLevel.ERROR, 'When the chain finishes, run scripts/apex/fetch_draft_eval.apex.');
}
