/**
 * run_case_mining_import2.apex — kick off CaseMiningJob over the widened 2026-07-22 preprod
 * reply import (build_mining_import2.js; Subject tag '[MINING-IMPORT-2026-07-22]'). Cohort matches
 * BOTH import tags so cases only present in the 07-21 import still mine (their threads now benefit
 * from the tail-preserving reply cap).
 *
 * Seeds: the 2026-07-22 decline-label gap topics (docs/decline-labels-2026-07-22.csv) FIRST —
 * specific error strings claim their cases before the broader legacy terms — then the original
 * 22-topic backlog. SEED_UNMATCHED costs nothing.
 *
 * DRY_PREVIEW=true prints the cohort size and enqueues NOTHING. Flip to false to run.
 * Rollback docs: scripts/apex/rollback_case_mined.apex (mined docs) /
 * rollback_mining_import.apex (imported emails; update its tag for 07-22).
 *
 * Run: sf apex run -f scripts/apex/run_case_mining_import2.apex -o vscodeOrg
 */
Boolean DRY_PREVIEW = true;
String RUN_LABEL = 'mining-import-2026-07-22';
String IMPORT_TAG = '[MINING-IMPORT-2026-07-2%';

List<CaseMiningJob.SeedTopic> SEEDS = new List<CaseMiningJob.SeedTopic>{
    // ---- 2026-07-22 decline-label gap topics (specific first) ----
    new CaseMiningJob.SeedTopic('regex-too-complicated-large-related-list',
        '"Regex too complicated" on large related-list queries',
        new List<String>{ 'regex too complicated' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('ssign-required-field-missing-version-data',
        'REQUIRED_FIELD_MISSING [Version Data] when sending for signature',
        new List<String>{ 'required_field_missing', 'version data' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('ssign-notification-batchable-too-big',
        'S-Sign Notifications Job: Batchable instance is too big',
        new List<String>{ 'batchable instance is too big', 'notificationemailschedulable' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('clone-ssign-component-signer-profiles',
        'Cloning S-Sign templates with component signer profiles',
        new List<String>{ 'signer profile that is not defined', 'signer profile' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('mass-merge-list-of-sobjects-empty',
        'Mass merge: "List of SObjects is empty"',
        new List<String>{ 'list of sobjects is empty', 'mass merge', 'mail merge' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('live-edit-session-expiration',
        'Live Edit: "page you submitted was invalid for your session"',
        new List<String>{ 'invalid for your session', 'live edit' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('vf-pdf-rendering-update',
        'Salesforce VF PDF rendering service update: S-Docs impact',
        new List<String>{ 'pdf rendering service', 'blob.topdf', 'sans serif', 'sans-serif' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('pdf-accessibility-wcag',
        'Generated-PDF accessibility / WCAG support',
        new List<String>{ 'accessibility', 'wcag', 'tagged pdf' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('assign-generated-document-content-library',
        'Routing generated documents into a content library',
        new List<String>{ 'content library' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('sdocscert-oauth-warning',
        'SDocsCert renewal: connected-app OAuth warning',
        new List<String>{ 'connected apps with oauth', 'deleting a parent org' }, 'S-Docs'),
    new CaseMiningJob.SeedTopic('ssign-offline-signing',
        'Offline / disconnected signing support in S-Sign',
        new List<String>{ 'offline signing', 'sign offline' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('ssign-tracking-pixel',
        'Custom scripts / tracking pixels in the S-Sign signing page',
        new List<String>{ 'tracking pixel' }, 'S-Sign'),
    new CaseMiningJob.SeedTopic('object-external-access',
        'S-Docs/S-Sign objects requiring public external access',
        new List<String>{ 'external access', 'public read' }, null),
    // ---- original 22-topic backlog ----
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
    new CaseMiningJob.SeedTopic('skip-version-upgrade', 'Skip-version upgrades (e.g. v8 to v11)',
        new List<String>{ 'upgrade from version 8', 'skip version upgrade', 'upgrade to the latest version' }, null),
    new CaseMiningJob.SeedTopic('external-client-apps-migration', 'External Client Apps migration',
        new List<String>{ 'external client app' }, null),
    new CaseMiningJob.SeedTopic('docx-pdf-fidelity', 'DOCX-to-PDF output fidelity differences',
        new List<String>{ 'docx to pdf', 'pdf looks different' }, 'S-Docs'),
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

Set<Id> parents = new Set<Id>();
for (EmailMessage em : [
    SELECT ParentId FROM EmailMessage
    WHERE Incoming = false AND Subject LIKE :IMPORT_TAG
]) {
    if (em.ParentId != null) { parents.add(em.ParentId); }
}
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
        + cohort.size() + ' cases.');
}
