/**
 * fetch_draft_eval.apex — locate the CSV report(s) written by DraftEvalBatchJob.
 *
 * Read-only: lists recent 'Draft Eval …' ContentVersions and prints the ready-to-paste REST
 * download command (binary-safe; debug-log printing would truncate the CSV).
 *
 * Run: sf apex run -f scripts/apex/fetch_draft_eval.apex -o vscodeOrg
 */

List<ContentVersion> reports = [
    SELECT Id, Title, PathOnClient, ContentSize, CreatedDate
    FROM ContentVersion
    WHERE Title LIKE 'Draft Eval%'
    ORDER BY CreatedDate DESC
    LIMIT 5
];

if (reports.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'No Draft Eval reports found. Is the job chain still running? '
        + 'Check: SELECT Status, ExtendedStatus FROM AsyncApexJob '
        + 'WHERE ApexClass.Name = \'DraftEvalBatchJob\' ORDER BY CreatedDate DESC');
} else {
    for (ContentVersion cv : reports) {
        System.debug(LoggingLevel.ERROR, cv.Title + '  (' + cv.ContentSize + ' bytes, '
            + cv.CreatedDate.format() + ')  Id=' + cv.Id);
        System.debug(LoggingLevel.ERROR, '  download: sf api request rest '
            + '"/services/data/v61.0/sobjects/ContentVersion/' + cv.Id
            + '/VersionData" -o vscodeOrg > docs/eval-run.csv');
    }
}
