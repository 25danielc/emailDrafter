// Phase-2 recall setting: lower the distillation accept margin 0.10 -> 0.05 on
// Support_Draft_Setting.Default via the Apex Metadata API (CLI record deploys throw
// UNKNOWN_EXCEPTION on this org — D27). A distilled retrieval pass now replaces the deterministic
// first pass when it reaches draftable strength AND beats it by 0.05 (was 0.10) — recovers cases
// where the distilled query surfaced the right doc but lost by the wide margin.
// ROLLBACK: change 0.05 back to 0.10 and re-run. Partial upsert: only this field is touched.
// Verify (async): sf apex run reading Retrieval_Distill_Accept_Margin__c.
Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
cm.fullName = 'Support_Draft_Setting.Default';
cm.label = 'Default';

Metadata.CustomMetadataValue margin = new Metadata.CustomMetadataValue();
margin.field = 'Retrieval_Distill_Accept_Margin__c';
margin.value = 0.05;
cm.values.add(margin);

Metadata.DeployContainer container = new Metadata.DeployContainer();
container.addMetadata(cm);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deployment: ' + jobId);
