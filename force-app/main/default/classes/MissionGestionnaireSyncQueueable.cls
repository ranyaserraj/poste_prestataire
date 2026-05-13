public class MissionGestionnaireSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> missionIds;

    public MissionGestionnaireSyncQueueable(List<Id> missionIds) {
        this.missionIds = missionIds == null ? new List<Id>() : new List<Id>(missionIds);
    }

    public void execute(QueueableContext context) {
        for (Id missionId : missionIds) {
            MissionGestionnaireSyncService.syncMission(missionId);
        }
    }
}
