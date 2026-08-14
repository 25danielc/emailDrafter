// Turn Draft_Verify_Second_Vote__c OFF on Support_Draft_Setting.Default via the Apex Metadata API
// (CLI record deploy throws UNKNOWN_EXCEPTION). 2026-07-23 pinned smoke: two same-model verify
// samples agreed 8/8 (correlated), so double-decline blocking degenerated into the rejected full
// flagged-channel re-block and killed good drafts. Copies every current __c value forward.
Support_Draft_Setting__mdt rec = Support_Draft_Setting__mdt.getInstance('Default');
Map<String, Schema.SObjectField> fmap =
    Support_Draft_Setting__mdt.getSObjectType().getDescribe().fields.getMap();

Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
cmd.fullName = 'Support_Draft_Setting.Default';
cmd.label = 'Default';

for (String f : fmap.keySet()) {
    if (!f.endsWith('__c')) { continue; }
    Object val = rec.get(f);
    if (f.equalsIgnoreCase('Draft_Verify_Second_Vote__c')) { val = false; }
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = fmap.get(f).getDescribe().getName();
    v.value = val;
    cmd.values.add(v);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cmd);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment job: ' + jobId);
