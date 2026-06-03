/**
 * Après création d'un Echange__c local : tentative de resync asynchrone vers l'API gestionnaire.
 */
public class MissionEchangeReplayTriggerHandler {

    public static void afterInsert(List<SObject> newRecords) {
        if (!MissionEchangeLocalService.isAvailable() || newRecords == null || newRecords.isEmpty()) {
            return;
        }
        if (Test.isRunningTest()) {
            return;
        }
        if (System.isFuture() || System.isBatch() || System.isQueueable() || System.isScheduled()) {
            return;
        }

        Set<Id> missionIds = new Set<Id>();
        for (SObject row : newRecords) {
            if (!MissionEchangeLocalService.shouldEnqueueOutboundReplay(row)) {
                continue;
            }
            Id mid = (Id) row.get('Mission__c');
            if (mid != null) {
                missionIds.add(mid);
            }
        }
        if (missionIds.isEmpty()) {
            return;
        }
        System.enqueueJob(
            new MissionMessageReplayQueueable(new List<Id>(missionIds))
        );
    }
}
