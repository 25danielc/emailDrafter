/**
 * fetch_probe.apex — list 'Retrieval Probe' / 'Draft Regen Probe' ContentVersions written by the
 * diagnostic probe scripts and print the REST download command for each. Read-only.
 *
 * Run: sf apex run -f scripts/apex/fetch_probe.apex -o vscodeOrg
 */

List<ContentVersion> reports = [
    SELECT Id, Title, ContentSize, CreatedDate
    FROM ContentVersion
    WHERE Title LIKE 'Retrieval Probe%' OR Title LIKE 'Draft Regen Probe%'
    ORDER BY CreatedDate DESC
    LIMIT 40
];

if (reports.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'No probe reports found.');
}
for (ContentVersion cv : reports) {
    System.debug(LoggingLevel.ERROR, cv.Title + '  (' + cv.ContentSize + ' bytes)  Id=' + cv.Id
        + '  download: sf api request rest "/services/data/v61.0/sobjects/ContentVersion/'
        + cv.Id + '/VersionData" -o vscodeOrg');
}
