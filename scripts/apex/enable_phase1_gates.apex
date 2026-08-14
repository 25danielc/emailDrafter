// Enable the 2026-07-23 Phase-1 precision levers on Support_Draft_Setting.Default via the Apex
// Metadata API (CLI record deploy throws UNKNOWN_EXCEPTION). Copies every current __c value
// forward and overrides only the two new checkboxes:
//   Draft_Structural_Decline_Enabled__c  -> true  (screenshot-only / regression pre-decline)
//   Draft_Verify_Second_Vote__c          -> true  (double-decline blocks in demote mode)
Support_Draft_Setting__mdt rec = Support_Draft_Setting__mdt.getInstance('Default');
Map<String, Schema.SObjectField> fmap =
    Support_Draft_Setting__mdt.getSObjectType().getDescribe().fields.getMap();

Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
cmd.fullName = 'Support_Draft_Setting.Default';
cmd.label = 'Default';

for (String f : fmap.keySet()) {
    if (!f.endsWith('__c')) { continue; } // only custom value fields
    Object val = rec.get(f);
    if (f.equalsIgnoreCase('Draft_Structural_Decline_Enabled__c')) { val = true; }
    if (f.equalsIgnoreCase('Draft_Verify_Second_Vote__c')) { val = true; }
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = fmap.get(f).getDescribe().getName();
    v.value = val;
    cmd.values.add(v);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cmd);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment job: ' + jobId);
