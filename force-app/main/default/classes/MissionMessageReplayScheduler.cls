/**
 * Job planifié : resync automatique des messages Echange__c vers l'API gestionnaire.
 * Planification par défaut : toutes les 15 minutes (voir ensureScheduled).
 */
public class MissionMessageReplayScheduler implements Schedulable {

    public static final String JOB_NAME = 'MissionMessageReplay_15min';
    public static final String CRON_EVERY_15_MIN = '0 0,15,30,45 * * * ?';

    public void execute(SchedulableContext context) {
        MissionMessageReplayQueueable.enqueueAllPending();
    }

    /**
     * Crée le job planifié s'il n'existe pas encore (à appeler une fois après déploiement).
     */
    public static void ensureScheduled() {
        if (hasActiveSchedule()) {
            return;
        }
        System.schedule(JOB_NAME, CRON_EVERY_15_MIN, new MissionMessageReplayScheduler());
    }

    public static Boolean hasActiveSchedule() {
        List<CronTrigger> rows = [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME AND State IN ('WAITING', 'ACQUIRED', 'EXECUTING')
            LIMIT 1
        ];
        return !rows.isEmpty();
    }
}
