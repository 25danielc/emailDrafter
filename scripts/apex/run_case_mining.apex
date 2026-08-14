/**
 * run_case_mining.apex — kick off CaseMiningJob over closed Email cases with outbound agent
 * replies, seeded with the 2026-07-16 diagnosis doc backlog (docs/eval-diagnosis-2026-07-16.md §
 * "What the 31 corpus-gap cases actually need").
 *
 * DRY_PREVIEW=true prints the cohort size + seed list and enqueues NOTHING. Flip to false to run.
 * Outputs: 'Case Mining <RUN_LABEL> harvest' / '... cluster' checkpoint ContentVersions and a final
 * 'Case Mining <RUN_LABEL>' JSON report; accepted docs land in Support_Solution__c with
 * Source_Space_Key__c='case-mined' (rollback: scripts/apex/rollback_case_mined.apex). The job
 * chains SupportSolutionStore.enqueue() at the end for the embedding backfill.
 *
 * Run: sf apex run -f scripts/apex/run_case_mining.apex -o vscodeOrg
 */
Boolean DRY_PREVIEW = true;
String RUN_LABEL = 'mining-2026-07-16';
Integer COHORT_CAP = 300;            // first-run cap; raise on later cycles
Integer WINDOW_DAYS = 365;           // widen to 550 on later cycles if yield is short

// ---- seed topics: the named doc backlog (verbatim error strings / distinctive phrases) ----
List<CaseMiningJob.SeedTopic> SEEDS = new List<CaseMiningJob.SeedTopic>{
    // Cluster 1 — known-error docs (9)
    new CaseMiningJob.SeedTopic('docx-invalid-field-id', 'DOCX upload fails with "invalid field ID"',
        new List<String>{ 'invalid field id' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('sdtemplate-not-supported',
        'SDTemplate__c sObject type not supported (flow-created jobs)',
        new List<String>{ 'sdtemplate__c sobject type', 'sobject type \'sdoc__sdtemplate__c\'' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('sstemplateeditor-missing',
        'SSTemplateEditor page does not exist (fresh sandbox install)',
        new List<String>{ 'sstemplateeditor' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('generatedocumentinvocable-null',
        'GenerateDocumentInvocable null-object error (v6.1.10)',
        new List<String>{ 'generatedocumentinvocable' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('ending-position-out-of-bounds',
        '"Ending position out of bounds" during generation',
        new List<String>{ 'ending position out of bounds' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('contentdistribution-invalid-type',
        'Invalid type: ContentDistribution (Content Deliveries disabled)',
        new List<String>{ 'invalid type: contentdistribution', 'contentdistribution' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('zqu-quote-missing',
        'zqu_Quote__c missing-object error (Zuora not installed)',
        new List<String>{ 'zqu_quote__c', 'zqu__quote__c' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('invalid-ssign-license-key',
        'Invalid S-Sign license key: causes and fixes',
        new List<String>{ 'invalid license key', 'license key is invalid' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('multi-template-job-splitter',
        'Multi-template job-splitter limitation',
        new List<String>{ 'job splitter', 'multiple templates in one job' }, 'S-Docs'),
    // Cluster 2 — upgrade / installation paths (3)
    new CaseMiningJob.SeedTopic('skip-version-upgrade', 'Skip-version upgrades (e.g. v8 to v11)',
        new List<String>{ 'upgrade from version 8', 'skip version upgrade', 'upgrade to the latest version' }, null),
    new CaseMiningJob.SeedTopic('external-client-apps-migration', 'External Client Apps migration',
        new List<String>{ 'external client app' }, null),
    new CaseMiningJob.SeedTopic('docx-pdf-fidelity', 'DOCX-to-PDF output fidelity differences',
        new List<String>{ 'docx to pdf', 'pdf looks different' }, 'S-Docs'),
    // Cluster 3 — capability / how-to gaps (7+)
    new CaseMiningJob.SeedTopic('jpg-in-pdf-rendering', 'JPG image rendering support in PDFs',
        new List<String>{ 'jpg', 'jpeg image' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('per-user-usage-reporting', 'Per-user document usage reporting',
        new List<String>{ 'usage per user', 'documents generated per user', 'usage report' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('merge-field-truncation', 'Merge-field truncation attribute',
        new List<String>{ 'truncate', 'character limit in merge field' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('next-signer-email-template', 'Customizing the next-signer email template',
        new List<String>{ 'next signer email', 'signer notification template' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('ssign-signing-view-hyperlinks', 'Hyperlinks in the S-Sign signing view',
        new List<String>{ 'hyperlink', 'clickable link' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('logo-positioning', 'Logo positioning in generated documents',
        new List<String>{ 'logo position', 'logo placement', 'move the logo' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('ui-sort-persistence-tables', 'UI sort persistence in generated tables',
        new List<String>{ 'sort order', 'table sorting' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('hubspot-edition-access', 'HubSpot-edition feature access',
        new List<String>{ 'hubspot' }, null)
};

// ---- cohort: closed Email cases in the window that HAVE an outbound agent reply ----
List<Case> raw = [
    SELECT Id, Description FROM Case
    WHERE Origin = 'Email' AND IsClosed = true
      AND Subject != null
      AND (NOT Subject LIKE '%SANDBOX TEST%')
      AND CreatedDate = LAST_N_DAYS:365
    ORDER BY CreatedDate DESC
    LIMIT 2000
];
// Description (long text) is not SOQL-filterable — drop blank-description cases client-side.
List<Case> candidates = new List<Case>();
for (Case c : raw) {
    if (String.isNotBlank(c.Description)) { candidates.add(c); }
}
Set<Id> replyParents = new Set<Id>();
for (AggregateResult ar : [
    SELECT ParentId pid FROM EmailMessage
    WHERE Incoming = false AND ParentId IN :candidates
    GROUP BY ParentId
]) {
    replyParents.add((Id) ar.get('pid'));
}
List<Id> cohort = new List<Id>();
for (Case c : candidates) {
    if (replyParents.contains(c.Id)) { cohort.add(c.Id); }
    if (cohort.size() >= COHORT_CAP) { break; }
}

System.debug(LoggingLevel.ERROR, 'Cohort: ' + cohort.size() + ' closed replied Email cases (cap '
    + COHORT_CAP + ', window ' + WINDOW_DAYS + 'd). Seeds: ' + SEEDS.size());
if (DRY_PREVIEW) {
    for (CaseMiningJob.SeedTopic s : SEEDS) {
        System.debug(LoggingLevel.ERROR, '  seed ' + s.slug + ' [' + s.product + '] terms=' + s.searchTerms);
    }
    System.debug(LoggingLevel.ERROR, 'DRY_PREVIEW=true — nothing enqueued. Flip to false to run.');
} else {
    System.enqueueJob(new CaseMiningJob(cohort, SEEDS, RUN_LABEL));
    System.debug(LoggingLevel.ERROR, 'Enqueued CaseMiningJob "' + RUN_LABEL + '" over '
        + cohort.size() + ' cases. Watch AsyncApexJob; fetch the report CV when done.');
}
