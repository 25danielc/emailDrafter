/**
 * probe_gap_docs.apex — per-slug retrieval probe for the 19 labeled corpus-gap topics
 * (docs/decline-labels-2026-07-22.csv). Run after each help.sdocs re-sync + re-embed to check
 * whether the user's newly authored pages actually retrieve above the draft floor for the case
 * that exposed the gap — so authoring iterates against measured retrieval, not vibes.
 *
 * Flow-parity input (Subject\nDescription, Product_List__c verbatim), default candidate ceiling.
 * Read-only except one ContentVersion JSON per chunk. SOSL budget caps a chunk at 4 cases —
 * drive the 5 chunks with scripts/run_gap_probe.ps1, which templates __START__/__RUN_LABEL__,
 * merges the chunk outputs, and prints the per-slug pass/fail table.
 */

String RUN_LABEL = '__RUN_LABEL__';
Integer START = __START__;
// 2 per synchronous transaction: 4 retrieveResilient calls over the 442-doc corpus exceed the
// 10s sync CPU limit (the eval job's 3-case chunks run async with a 60s limit).
Integer CHUNK = 2;

// caseNumber -> gap_topic_slug, in docs/decline-labels-2026-07-22.csv order.
List<List<String>> PAIRS = new List<List<String>>{
    new List<String>{ '00033893', 'pdf-accessibility-wcag-support' },
    new List<String>{ '00033790', 'multi-template-dynamic-job-splitter-conflict' },
    new List<String>{ '00033956', 'assign-generated-document-to-content-library' },
    new List<String>{ '00034042', 'certificate-renewal-oauth-warning-message' },
    new List<String>{ '00033908', 's-sign-offline-signing-support' },
    new List<String>{ '00034130', 's-sign-tracking-pixel-script-injection' },
    new List<String>{ '00033910', 'spring-26-pdf-rendering-compatibility' },
    new List<String>{ '00034140', 'live-edit-session-expiration' },
    new List<String>{ '00033799', 'hubspot-completion-notifications' },
    new List<String>{ '00033694', 'sdocs-ssign-object-external-access-requirements' },
    new List<String>{ '00034164', 'blob-topdf-release-update-compatibility' },
    new List<String>{ '00033759', 'ssign-notification-batchable-too-big' },
    new List<String>{ '00034002', 'regex-too-complicated-large-related-list' },
    new List<String>{ '00033722', 'clone-ssign-template-component-signer-profiles' },
    new List<String>{ '00034176', 'ssign-required-field-missing-version-data' },
    new List<String>{ '00033897', 'salesforce-vf-pdf-rendering-update-impact' },
    new List<String>{ '00033716', 'hubspot-signature-reminders' },
    new List<String>{ '00034071', 'deleted-signer-profile-locked-inputs' },
    new List<String>{ '00033815', 'mass-merge-list-of-sobjects-empty' }
};

Set<String> nums = new Set<String>();
for (Integer i = START; i < Math.min(START + CHUNK, PAIRS.size()); i++) { nums.add(PAIRS[i][0]); }
Map<String, Case> byNum = new Map<String, Case>();
for (Case c : [SELECT Id, CaseNumber, Subject, Description, Product_List__c
               FROM Case WHERE CaseNumber IN :nums]) {
    byNum.put(c.CaseNumber, c);
}

List<Object> rows = new List<Object>();
for (Integer i = START; i < Math.min(START + CHUNK, PAIRS.size()); i++) {
    String num = PAIRS[i][0];
    String slug = PAIRS[i][1];
    Case c = byNum.get(num);
    Map<String, Object> row = new Map<String, Object>{ 'caseNumber' => num, 'slug' => slug };
    if (c == null) { row.put('error', 'case not found'); rows.add(row); continue; }

    SupportRetrievalService.RetrievalInput inp = new SupportRetrievalService.RetrievalInput();
    String subject = (c.Subject == null) ? '' : c.Subject;
    String descr = (c.Description == null) ? '' : c.Description;
    inp.searchText = (subject + '\n' + descr).trim();
    inp.product = String.isBlank(c.Product_List__c) ? null : c.Product_List__c.trim();

    try {
        SupportRetrievalService.RetrievalResult r = SupportRetrievalService.retrieveResilient(inp);
        row.put('topScore', r.topScore);
        row.put('confidence', r.confidence);
        row.put('passesFloor', r.topScore != null && r.topScore >= 0.45);
        List<Object> top = new List<Object>();
        for (Integer k = 0; k < Math.min(3, r.candidates.size()); k++) {
            SupportRetrievalService.Candidate cd = r.candidates[k];
            top.add(new Map<String, Object>{
                'name' => cd.name, 'score' => cd.score, 'url' => cd.url,
                'sourceType' => cd.sourceType
            });
        }
        row.put('top3', top);
    } catch (Exception e) {
        row.put('error', e.getTypeName() + ': ' + e.getMessage());
    }
    rows.add(row);
}

ContentVersion cv = new ContentVersion();
cv.Title = 'Gap Probe ' + RUN_LABEL + '-c' + START;
cv.PathOnClient = 'gap-probe-' + RUN_LABEL + '-c' + START + '.json';
cv.VersionData = Blob.valueOf(JSON.serialize(new Map<String, Object>{
    'runLabel' => RUN_LABEL, 'start' => START, 'rows' => rows }));
insert cv;
System.debug(LoggingLevel.ERROR, 'Gap probe chunk ' + START + ': ' + rows.size()
    + ' cases -> ContentVersion ' + cv.Id);
