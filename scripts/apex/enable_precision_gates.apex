// Populates the new precision-gate fields on Support_Draft_Setting.Default via the Apex Metadata API.
// The CLI CustomMetadata *record* deploy throws UNKNOWN_EXCEPTION on this org (see DECISIONS/D27), so
// record-value updates go through Metadata.Operations. Field definitions are deployed separately.
// Only the four new fields are set here; all other Default values are left unchanged (partial upsert).
Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
cm.fullName = 'Support_Draft_Setting.Default';
cm.label = 'Default';

Metadata.CustomMetadataValue verifyEnabled = new Metadata.CustomMetadataValue();
verifyEnabled.field = 'Draft_Verify_Enabled__c';
verifyEnabled.value = true;
cm.values.add(verifyEnabled);

Metadata.CustomMetadataValue verifyModel = new Metadata.CustomMetadataValue();
verifyModel.field = 'Draft_Verify_Model__c';
verifyModel.value = 'sfdc_ai__DefaultOpenAIGPT4OmniMini';
cm.values.add(verifyModel);

Metadata.CustomMetadataValue claimEnabled = new Metadata.CustomMetadataValue();
claimEnabled.field = 'Draft_Claim_Check_Enabled__c';
claimEnabled.value = true;
cm.values.add(claimEnabled);

Metadata.CustomMetadataValue claimMax = new Metadata.CustomMetadataValue();
claimMax.field = 'Draft_Claim_Check_Max_Unverified__c';
claimMax.value = 0;
cm.values.add(claimMax);

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cm);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment: ' + jobId);
