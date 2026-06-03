/**
 * Resync asynchrone des Echange__c prestataire vers l'API gestionnaire (par lots de missions).
 */
public class MissionMessageReplayQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer MISSIONS_PER_RUN = 10;

    private final List<Id> missionIds;
    private final Integer startIndex;

    public MissionMessageReplayQueueable(List<Id> missionIds) {
        this(missionIds, 0);
    }

    private MissionMessageReplayQueueable(List<Id> missionIds, Integer startIndex) {
        this.missionIds = missionIds == null ? new List<Id>() : new List<Id>(missionIds);
        this.startIndex = startIndex == null || startIndex < 0 ? 0 : startIndex;
    }

    public void execute(QueueableContext context) {
        if (missionIds.isEmpty()) {
            return;
        }
        Integer endIdx = Math.min(startIndex + MISSIONS_PER_RUN, missionIds.size());
        for (Integer i = startIndex; i < endIdx; i++) {
            MissionMessageController.replayPendingForMission(missionIds[i]);
        }
        if (endIdx < missionIds.size()) {
            System.enqueueJob(new MissionMessageReplayQueueable(missionIds, endIdx));
        }
    }

    /** Lance la resync pour toutes les missions avec messages locaux en attente. */
    public static void enqueueAllPending() {
        Set<Id> ids = MissionEchangeLocalService.listMissionIdsWithOutboundPending();
        if (ids.isEmpty()) {
            return;
        }
        System.enqueueJob(new MissionMessageReplayQueueable(new List<Id>(ids)));
    }

    /** Lance la resync pour une mission (ex. après insert Echange__c). */
    public static void enqueueForMission(Id missionId) {
        if (missionId == null) {
            return;
        }
        System.enqueueJob(new MissionMessageReplayQueueable(new List<Id>{ missionId }));
    }
}
