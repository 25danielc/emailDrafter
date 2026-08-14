/**
 * rollback_mining_import.apex — delete the preprod agent-reply EmailMessages imported for corpus
 * mining (Subject tag '[MINING-IMPORT-2026-07-21]'). The mined DOCS are rolled back separately via
 * scripts/apex/rollback_case_mined.apex — the two are independent.
 *
 * DRY_PREVIEW=true prints what WOULD be deleted; flip to false to delete (~420 rows, one txn).
 * Run: sf apex run -f scripts/apex/rollback_mining_import.apex -o vscodeOrg
 */
Boolean DRY_PREVIEW = true;
String IMPORT_TAG = '[MINING-IMPORT-2026-07-21]%';

List<EmailMessage> imported = [
    SELECT Id, ParentId, Subject FROM EmailMessage
    WHERE Incoming = false AND Subject LIKE :IMPORT_TAG
];
System.debug(LoggingLevel.ERROR, 'Tagged imported reply threads: ' + imported.size());

if (DRY_PREVIEW) {
    for (Integer i = 0; i < Math.min(5, imported.size()); i++) {
        System.debug(LoggingLevel.ERROR, '  sample: ' + imported[i].Subject);
    }
    System.debug(LoggingLevel.ERROR, 'DRY_PREVIEW=true — nothing deleted. Flip to false to delete.');
} else {
    delete imported;
    System.debug(LoggingLevel.ERROR, 'Deleted ' + imported.size() + ' imported EmailMessages.');
}
