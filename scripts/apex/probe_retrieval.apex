/**
 * probe_retrieval.apex — per-case retrieval diagnostics: dump the per-candidate score breakdown
 * (lexical / semantic / semanticRaw / content) that production discards, plus a replication of the
 * raw SOSL pool, so declines can be attributed to calibration vs recall vs corpus gaps.
 *
 * Calls SupportRetrievalService.retrieveResilient() with the production flow's exact input mapping
 * (Subject\nDescription, Product_List__c verbatim) and maxCandidates=40 so selectAdaptive truncates
 * as little as possible. Reads only public fields — no production class is modified. The ONLY write
 * is one ContentVersion JSON ('Retrieval Probe <RUN_LABEL>') per run; Cases are never touched.
 *
 * The pool replication rebuilds the winning pass's SOSL FIND from RetrievalResult.queryTerms + tier
 * (mirrors soslSearch, SupportRetrievalService.cls:335-358) — membership tells "pooled but cut by
 * selection" apart from "never retrieved".
 *
 * Budget: up to 5 SOSL per case (tier fallback x2 passes + replication) — MAX 4 CASES PER RUN
 * (20-SOSL transaction limit). Edit RUN_LABEL + CASE_IDS per batch; a driver script templates this.
 *
 * Run: sf apex run -f scripts/apex/probe_retrieval.apex -o vscodeOrg
 */

String RUN_LABEL = '__RUN_LABEL__';
List<Id> CASE_IDS = new List<Id>{ __CASE_ID_LIST__ };

Support_Draft_Setting__mdt cfg = Support_Draft_Setting__mdt.getInstance('Default');
Map<String, Object> configEcho = new Map<String, Object>{
    'goodScore' => cfg.Retrieval_Good_Match_Score__c,
    'mediumScore' => cfg.Retrieval_Medium_Match_Score__c,
    'embeddingWeight' => cfg.Retrieval_Embedding_Weight__c,
    'simFloor' => cfg.Retrieval_Embedding_Sim_Floor__c,
    'simCeil' => cfg.Retrieval_Embedding_Sim_Ceil__c,
    'lexicalFloorFrac' => cfg.Retrieval_Lexical_Floor_Frac__c,
    'distillEnabled' => cfg.Retrieval_Query_Distill_Enabled__c,
    'embeddingEnabled' => cfg.Retrieval_Embedding_Enabled__c
};

Map<Id, Case> cases = new Map<Id, Case>([
    SELECT Id, CaseNumber, Subject, Description, Product_List__c FROM Case WHERE Id IN :CASE_IDS
]);

List<Object> caseOut = new List<Object>();
for (Id cid : CASE_IDS) {
    Case c = cases.get(cid);
    Map<String, Object> row = new Map<String, Object>{
        'caseId' => String.valueOf(cid),
        'caseNumber' => c == null ? null : c.CaseNumber,
        'product' => c == null ? null : c.Product_List__c
    };
    if (c == null) { row.put('error', 'case not found'); caseOut.add(row); continue; }

    // Exact flow-parity input (SupportDraftOrchestrator.buildRetrievalInput), ceiling raised to 40.
    SupportRetrievalService.RetrievalInput inp = new SupportRetrievalService.RetrievalInput();
    String subject = (c.Subject == null) ? '' : c.Subject;
    String descr = (c.Description == null) ? '' : c.Description;
    inp.searchText = (subject + '\n' + descr).trim();
    inp.product = String.isBlank(c.Product_List__c) ? null : c.Product_List__c.trim();
    inp.maxCandidates = 40;
    row.put('searchTextChars', inp.searchText.length());

    SupportRetrievalService.RetrievalResult r;
    try {
        r = SupportRetrievalService.retrieveResilient(inp);
    } catch (Exception e) {
        row.put('error', e.getTypeName() + ': ' + e.getMessage());
        caseOut.add(row);
        continue;
    }

    row.put('tier', r.tier);
    row.put('distilled', r.distilled);
    row.put('distilledQuery', r.distilledQuery);
    row.put('queryTerms', r.queryTerms);
    row.put('topScore', r.topScore);
    row.put('confidence', r.confidence);

    List<Object> cands = new List<Object>();
    Double contentMax = null; Integer contentMaxRank = null;
    String contentMaxDocId = null, contentMaxDocName = null;
    Integer rank = 0;
    for (SupportRetrievalService.Candidate cd : r.candidates) {
        rank++;
        Double content = (cd.breakdown == null) ? null : cd.breakdown.content;
        if (content != null && (contentMax == null || content > contentMax)) {
            contentMax = content; contentMaxRank = rank;
            contentMaxDocId = String.valueOf(cd.solutionId); contentMaxDocName = cd.name;
        }
        if (rank <= 10) {
            String snip = (cd.snippet == null) ? null
                : (cd.snippet.length() > 150 ? cd.snippet.substring(0, 150) : cd.snippet);
            cands.add(new Map<String, Object>{
                'rank' => rank,
                'solutionId' => String.valueOf(cd.solutionId),
                'name' => cd.name,
                'sourceType' => cd.sourceType,
                'visibility' => cd.visibility,
                'commonCase' => cd.commonCase,
                'rrfScore' => cd.score,
                'lexical' => (cd.breakdown == null) ? null : cd.breakdown.lexical,
                'semantic' => (cd.breakdown == null) ? null : cd.breakdown.semantic,
                'semanticRaw' => (cd.breakdown == null) ? null : cd.breakdown.semanticRaw,
                'content' => content,
                'snippet' => snip,
                'url' => cd.url
            });
        }
    }
    row.put('candidates', cands);

    Double top1Content = (r.candidates.isEmpty() || r.candidates[0].breakdown == null)
        ? null : r.candidates[0].breakdown.content;
    row.put('derived', new Map<String, Object>{
        'returnedCount' => r.candidates.size(),
        'contentMax' => contentMax,
        'contentMaxRank' => contentMaxRank,
        'contentMaxDocId' => contentMaxDocId,
        'contentMaxDocName' => contentMaxDocName,
        'contentMaxMinusRank1' => (contentMax == null || top1Content == null) ? null : contentMax - top1Content,
        'wouldCrossFloorAtContentMax' => contentMax != null && contentMax >= 0.45,
        'rank1Visibility' => r.candidates.isEmpty() ? null : r.candidates[0].visibility
    });

    // Pool replication for the WINNING pass (queryTerms/tier belong to whichever pass was kept).
    if (r.tier > 0 && !r.queryTerms.isEmpty()) {
        List<String> wild = new List<String>();
        for (String t : r.queryTerms) { wild.add(t + '*'); }
        String expr = String.join(wild, r.tier == 1 ? ' AND ' : ' OR ');
        // Mirrors soslSearch's multi-select handling: split on ';', filter with IN.
        List<String> products = null;
        if (inp.product != null) {
            products = new List<String>();
            for (String p : inp.product.split(';')) {
                if (!String.isBlank(p)) { products.add(p.trim()); }
            }
            if (products.isEmpty()) { products = null; }
        }
        String whereClause = 'Active__c = true AND Source_Type__c != \'query\' '
            + 'AND Source_Type__c != \'draft\' AND Source_Type__c != \'internal_ops\'';
        if (products != null) { whereClause += ' AND Product__c IN :products'; }
        String q = 'FIND \'' + expr + '\' IN ALL FIELDS RETURNING Support_Solution__c '
            + '(Id, Name, Visibility__c, Source_Type__c, Common_Case__c WHERE ' + whereClause + ' LIMIT 40)';
        try {
            List<List<SObject>> res = Search.query(q);
            List<Object> poolDocs = new List<Object>();
            for (SObject so : res[0]) {
                Support_Solution__c s = (Support_Solution__c) so;
                poolDocs.add(new Map<String, Object>{
                    'id' => String.valueOf(s.Id), 'name' => s.Name,
                    'visibility' => s.Visibility__c, 'sourceType' => s.Source_Type__c,
                    'commonCase' => s.Common_Case__c
                });
            }
            row.put('pool', new Map<String, Object>{ 'size' => poolDocs.size(), 'docs' => poolDocs });
        } catch (Exception e) {
            row.put('pool', new Map<String, Object>{ 'error' => e.getMessage() });
        }
    } else {
        row.put('pool', new Map<String, Object>{ 'size' => 0, 'docs' => new List<Object>() });
    }
    caseOut.add(row);
}

Map<String, Object> report = new Map<String, Object>{
    'runLabel' => RUN_LABEL, 'configEcho' => configEcho, 'cases' => caseOut
};
ContentVersion cv = new ContentVersion();
cv.Title = 'Retrieval Probe ' + RUN_LABEL;
cv.PathOnClient = 'retrieval-probe-' + RUN_LABEL + '.json';
cv.VersionData = Blob.valueOf(JSON.serialize(report));
insert cv;
System.debug(LoggingLevel.ERROR, 'Probe ' + RUN_LABEL + ': ' + caseOut.size()
    + ' cases -> ContentVersion ' + cv.Id);
