/**
 * probe_draft_regen.apex — re-run the FULL draft pipeline (SupportDraftOrchestrator.orchestrate)
 * for a short list of Cases and capture the complete draftText + notes for quality auditing (the
 * eval CSV keeps only 200-char excerpts). Dry: no Case writes, no draft emails — one ContentVersion
 * JSON ('Draft Regen Probe <RUN_LABEL>') is the only write.
 *
 * CAVEAT for auditors: generation is sampled, so a regenerated draft is a fresh artifact, not the
 * one produced in a prior eval run — it answers "does the system write a sendable reply for this
 * case," not "was that specific prior draft sendable."
 *
 * Budget: generation is the slow call (~5-15s/case) — MAX 4 CASES PER RUN.
 *
 * Run: sf apex run -f scripts/apex/probe_draft_regen.apex -o vscodeOrg
 */

String RUN_LABEL = '__RUN_LABEL__';
List<Id> CASE_IDS = new List<Id>{ __CASE_ID_LIST__ };

Map<Id, Case> cases = new Map<Id, Case>([
    SELECT Id, CaseNumber, Subject, Description, Product_List__c FROM Case WHERE Id IN :CASE_IDS
]);

List<Object> caseOut = new List<Object>();
for (Id cid : CASE_IDS) {
    Case c = cases.get(cid);
    Map<String, Object> row = new Map<String, Object>{
        'caseId' => String.valueOf(cid),
        'caseNumber' => c == null ? null : c.CaseNumber
    };
    if (c == null) { row.put('error', 'case not found'); caseOut.add(row); continue; }

    SupportDraftOrchestrator.Request req = new SupportDraftOrchestrator.Request();
    req.subject = c.Subject;
    req.description = c.Description;
    req.product = c.Product_List__c;

    Long t0 = System.currentTimeMillis();
    try {
        SupportDraftOrchestrator.Result r = SupportDraftOrchestrator.orchestrate(req);
        row.put('status', r.status);
        row.put('confidence', r.confidence);
        row.put('retrievalTopScore', r.retrievalTopScore);
        row.put('modelName', r.modelName);
        row.put('sourceIds', r.sourceIds);
        row.put('draftText', r.draftText);   // FULL text on purpose — this probe exists for auditing
        row.put('notes', r.notes);
    } catch (Exception e) {
        row.put('error', e.getTypeName() + ': ' + e.getMessage());
    }
    row.put('elapsedMs', System.currentTimeMillis() - t0);
    caseOut.add(row);
}

ContentVersion cv = new ContentVersion();
cv.Title = 'Draft Regen Probe ' + RUN_LABEL;
cv.PathOnClient = 'draft-regen-probe-' + RUN_LABEL + '.json';
cv.VersionData = Blob.valueOf(JSON.serialize(new Map<String, Object>{
    'runLabel' => RUN_LABEL, 'cases' => caseOut
}));
insert cv;
System.debug(LoggingLevel.ERROR, 'Draft regen probe ' + RUN_LABEL + ': ' + caseOut.size()
    + ' cases -> ContentVersion ' + cv.Id);
