trigger MissionGestionnaireSyncTrigger on Mission__c(after insert) {
    List<Id> ids = new List<Id>();
    for (Mission__c m : Trigger.new) {
        if (MissionGestionnaireSyncService.shouldEnqueue(m)) {
            ids.add(m.Id);
        }
    }
    if (!ids.isEmpty()) {
        System.enqueueJob(new MissionGestionnaireSyncQueueable(ids));
    }
}
