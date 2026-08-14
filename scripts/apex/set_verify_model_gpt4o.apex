// Escalates the verification-gate judge from GPT-4o-mini to full GPT-4o (partial CMDT upsert via the
// Apex Metadata API — CLI record deploy throws UNKNOWN_EXCEPTION on this org). Only the model field is
// changed; verify stays enabled. Revert to 'sfdc_ai__DefaultOpenAIGPT4OmniMini' to undo.
Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
cm.fullName = 'Support_Draft_Setting.Default';
cm.label = 'Default';
Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
v.field = 'Draft_Verify_Model__c';
v.value = 'sfdc_ai__DefaultGPT4Omni';
cm.values.add(v);
Metadata.DeployContainer c = new Metadata.DeployContainer();
c.addMetadata(cm);
System.debug('Enqueued: ' + Metadata.Operations.enqueueDeployment(c, null));
