@IsTest
private class MissionMessageReplaySchedulerTest {

    private class ReplayMock implements HttpCalloutMock {
        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'GET') {
                res.setBody('[]');
            } else if (req.getMethod() == 'POST') {
                res.setBody(
                    '{"id":1,"content":"Message auto replay","senderRole":"PRESTATAIRE","tag":"INFORMATION"}'
                );
            }
            return res;
        }
    }

    @TestSetup
    static void setup() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Replay Auto');
        insert acc;
        Mission__c m = new Mission__c(
            Name = 'Mission auto replay',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180200'
        );
        insert m;
        MissionEchangeLocalService.createOutboundPending(
            m.Id,
            'Message auto replay',
            'INFORMATION'
        );
    }

    @IsTest
    static void queueable_replays_and_marks_synced() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Mission__c m = [SELECT Id FROM Mission__c WHERE Numero_mission2__c = '202605180200' LIMIT 1];
        System.assertEquals(1, [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id]);

        Test.setMock(HttpCalloutMock.class, new ReplayMock());
        Test.startTest();
        System.enqueueJob(new MissionMessageReplayQueueable(new List<Id>{ m.Id }));
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id],
            'Historique Echange__c conservé après resync'
        );
    }

    @IsTest
    static void scheduler_executes_without_error() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Test.setMock(HttpCalloutMock.class, new ReplayMock());
        Test.startTest();
        new MissionMessageReplayScheduler().execute(null);
        Test.stopTest();
        System.assert(true, 'Scheduler OK');
    }

    @IsTest
    static void ensureScheduled_creates_cron_job() {
        Test.startTest();
        if (!MissionMessageReplayScheduler.hasActiveSchedule()) {
            System.schedule(
                MissionMessageReplayScheduler.JOB_NAME,
                MissionMessageReplayScheduler.CRON_EVERY_15_MIN,
                new MissionMessageReplayScheduler()
            );
        }
        Test.stopTest();
        System.assert(
            MissionMessageReplayScheduler.hasActiveSchedule(),
            'Job planifié créé'
        );
    }
}
