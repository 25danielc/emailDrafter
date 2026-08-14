/**
 * run_case_mining_import.apex — kick off CaseMiningJob over the cases that received an imported
 * preprod agent-reply thread (Subject tag '[MINING-IMPORT-2026-07-21]', built by
 * scripts/data/build_mining_import.js and bulk-inserted). Same seed backlog as
 * run_case_mining.apex; the cohort differs: imported-reply parents, with NO IsClosed requirement
 * (the sandbox copies of these preprod-closed cases may not carry a closed status).
 *
 * DRY_PREVIEW=true prints the cohort size + seed list and enqueues NOTHING. Flip to false to run.
 * Accepted docs land with Source_Space_Key__c='case-mined' (rollback:
 * scripts/apex/rollback_case_mined.apex); the imported emails themselves roll back via
 * scripts/apex/rollback_mining_import.apex.
 *
 * Run: sf apex run -f scripts/apex/run_case_mining_import.apex -o vscodeOrg
 */
Boolean DRY_PREVIEW = true;
String RUN_LABEL = 'mining-import-2026-07-21';
String IMPORT_TAG = '[MINING-IMPORT-2026-07-21]%';

// ---- seed topics: identical backlog to run_case_mining.apex (SEED_UNMATCHED costs nothing) ----
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

// ---- cohort: parents of the tagged imported reply threads ----
Set<Id> parents = new Set<Id>();
for (EmailMessage em : [
    SELECT ParentId FROM EmailMessage
    WHERE Incoming = false AND Subject LIKE :IMPORT_TAG
]) {
    if (em.ParentId != null) { parents.add(em.ParentId); }
}
// Description (long text) is not SOQL-filterable — drop blank-description cases client-side
// (harvest needs the customer question; CaseIntakeClassifier still filters junk/billing per case).
List<Id> cohort = new List<Id>();
for (Case c : [SELECT Id, Description FROM Case WHERE Id IN :parents ORDER BY CreatedDate DESC]) {
    if (String.isNotBlank(c.Description)) { cohort.add(c.Id); }
}

System.debug(LoggingLevel.ERROR, 'Cohort: ' + cohort.size() + ' imported-reply cases (of '
    + parents.size() + ' tagged parents). Seeds: ' + SEEDS.size());
if (DRY_PREVIEW) {
    System.debug(LoggingLevel.ERROR, 'DRY_PREVIEW=true — nothing enqueued. Flip to false to run.');
} else {
    System.enqueueJob(new CaseMiningJob(cohort, SEEDS, RUN_LABEL));
    System.debug(LoggingLevel.ERROR, 'Enqueued CaseMiningJob "' + RUN_LABEL + '" over '
        + cohort.size() + ' cases. Watch AsyncApexJob; fetch the report CV when done.');
}
