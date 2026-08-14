// Update Support_Draft_Setting.Default via the Apex Metadata API (CLI record deploy throws
// UNKNOWN_EXCEPTION). Copies every current __c value forward and overrides only the two we changed:
//   Draft_Min_Top_Score__c        0.45 -> 0.50  (Fix 4: cut near-floor false positives)
//   Retrieval_Distill_Accept_Margin__c  (new) -> 0.05  (Fix 3: accept modest distilled recovery)
Support_Draft_Setting__mdt rec = Support_Draft_Setting__mdt.getInstance('Default');
Map<String, Schema.SObjectField> fmap =
    Support_Draft_Setting__mdt.getSObjectType().getDescribe().fields.getMap();

Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
cmd.fullName = 'Support_Draft_Setting.Default';
cmd.label = 'Default';

for (String f : fmap.keySet()) {
    if (!f.endsWith('__c')) { continue; } // only custom value fields
    Object val = rec.get(f);
    if (f.equalsIgnoreCase('Draft_Min_Top_Score__c')) { val = 0.50; }
    if (f.equalsIgnoreCase('Retrieval_Distill_Accept_Margin__c')) { val = 0.05; }
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = fmap.get(f).getDescribe().getName();
    v.value = val;
    cmd.values.add(v);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cmd);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment job: ' + jobId);
