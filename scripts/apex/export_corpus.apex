/**
 * export_corpus.apex — snapshot the active knowledge corpus for the draft-eval reviewer step.
 *
 * The post-run reviewer agents judge "should this case have drafted?" by deciding whether ANY doc
 * answers the case. They need the same ground-truth doc set the pipeline retrieves from, so this
 * dumps every active Support_Solution__c (Id + Name + Body + product/visibility/provenance) to a
 * single ContentVersion titled 'Support Corpus Snapshot'. The reviewers map a case's retrieved
 * sourceIds back to these docs by Id.
 *
 * Only write is the one ContentVersion (a disposable artifact — delete from Files when done).
 * Fetch it the same way as the eval CSV:
 *   sf api request rest "/services/data/v61.0/sobjects/ContentVersion/<Id>/VersionData" \
 *       -o vscodeOrg > docs/corpus-snapshot.json
 *
 * Run: sf apex run -f scripts/apex/export_corpus.apex -o vscodeOrg
 */

// Answers are short; cap the body so an outlier doc can't blow the synchronous heap.
Integer BODY_MAX = 8000;

List<Object> docs = new List<Object>();
for (Support_Solution__c s : [
        SELECT Id, Name, Body__c, Product__c, Visibility__c, Solution_Type__c,
               Common_Case__c, Source_Space_Key__c, Keywords__c
        FROM Support_Solution__c
        WHERE Active__c = true
        ORDER BY Name]) {
    String body = s.Body__c;
    if (body != null && body.length() > BODY_MAX) { body = body.substring(0, BODY_MAX); }
    docs.add(new Map<String, Object>{
        'id'          => s.Id,
        'name'        => s.Name,
        'product'     => s.Product__c,
        'visibility'  => s.Visibility__c,
        'solutionType'=> s.Solution_Type__c,
        'commonCase'  => s.Common_Case__c,
        'source'      => s.Source_Space_Key__c,
        'keywords'    => s.Keywords__c,
        'body'        => body
    });
}

ContentVersion cv = new ContentVersion();
cv.Title = 'Support Corpus Snapshot';
cv.PathOnClient = 'corpus-snapshot.json';
cv.VersionData = Blob.valueOf(JSON.serializePretty(docs));
insert cv;

System.debug(LoggingLevel.ERROR, 'Wrote Support Corpus Snapshot: ' + docs.size()
    + ' active docs, ' + cv.VersionData.size() + ' bytes. ContentVersion Id=' + cv.Id);
System.debug(LoggingLevel.ERROR, '  download: sf api request rest '
    + '"/services/data/v61.0/sobjects/ContentVersion/' + cv.Id
    + '/VersionData" -o vscodeOrg > docs/corpus-snapshot.json');
