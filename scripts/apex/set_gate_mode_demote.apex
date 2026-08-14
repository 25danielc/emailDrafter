// Flips the verification gates to DEMOTE mode on Support_Draft_Setting.Default via the Apex
// Metadata API (CLI CustomMetadata record deploys throw UNKNOWN_EXCEPTION on this org — D27).
// demote = a failed grounding/claim/verify gate stamps [NEEDS REVIEW] warnings + LOW confidence
// but still produces a DRAFTED outcome for human review. ROLLBACK: change 'demote' to 'block'
// below and re-run — fail-closed behavior returns with no code deploy.
// Partial upsert: only this one field is touched; all other Default values are left unchanged.
// NOTE: the deployment is ASYNC — verify it landed before evaluating:
//   sf apex run -o vscodeOrg -e "System.debug(Support_Draft_Setting__mdt.getInstance('Default').Draft_Gate_Mode__c);"
Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
cm.fullName = 'Support_Draft_Setting.Default';
cm.label = 'Default';

Metadata.CustomMetadataValue gateMode = new Metadata.CustomMetadataValue();
gateMode.field = 'Draft_Gate_Mode__c';
gateMode.value = 'demote';
cm.values.add(gateMode);

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cm);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment: ' + jobId);
