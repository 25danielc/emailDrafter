/**
 * rollback_case_mined.apex — deactivate case-mined docs (Active__c=false; deactivate-not-delete is
 * the store's audit convention — retrieval's SOSL WHERE excludes inactive rows immediately).
 *
 * PAGE_ID_PREFIX narrows the rollback: null/blank = ALL case-mined docs; 'case-mined:seed:' = only
 * the seeded backlog docs; a full pageId = that one doc. Re-ingesting later is free (idempotent
 * pageIds re-activate via upsert with isActive=true).
 *
 * Run: sf apex run -f scripts/apex/rollback_case_mined.apex -o vscodeOrg
 */
String PAGE_ID_PREFIX = '';   // '' = all case-mined docs
Boolean DRY_PREVIEW = true;   // true: count + list only, no writes

List<Support_Solution__c> docs = [
    SELECT Id, Name, Confluence_Page_Id__c, Active__c, Mined_From_Cases__c
    FROM Support_Solution__c
    WHERE Source_Space_Key__c = 'case-mined' AND Active__c = true
];
List<Support_Solution__c> toDeactivate = new List<Support_Solution__c>();
for (Support_Solution__c d : docs) {
    if (String.isBlank(PAGE_ID_PREFIX) || d.Confluence_Page_Id__c.startsWith(PAGE_ID_PREFIX)) {
        System.debug(LoggingLevel.ERROR, (DRY_PREVIEW ? '[preview] ' : '[deactivating] ')
            + d.Confluence_Page_Id__c + ' — ' + d.Name + ' (from cases: ' + d.Mined_From_Cases__c + ')');
        d.Active__c = false;
        toDeactivate.add(d);
    }
}
if (DRY_PREVIEW) {
    System.debug(LoggingLevel.ERROR, 'DRY_PREVIEW=true — ' + toDeactivate.size()
        + ' docs would be deactivated. Flip to false to execute.');
} else {
    update toDeactivate;
    System.debug(LoggingLevel.ERROR, 'Deactivated ' + toDeactivate.size() + ' case-mined docs.');
}
