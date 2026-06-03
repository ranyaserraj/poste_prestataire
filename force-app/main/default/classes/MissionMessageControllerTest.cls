@IsTest
private class MissionMessageControllerTest {

    private class MessagesMock implements HttpCalloutMock {
        public String lastPostPath;
        public String lastPostBody;

        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'POST') {
                lastPostPath = req.getEndpoint();
                lastPostBody = req.getBody();
            }
            if (req.getMethod() == 'GET') {
                res.setBody(
                    '[{"id":1,"content":"Bonjour","senderName":"GS","senderRole":"GESTIONNAIRE","sentAt":"2026-05-18T10:00:00Z","tag":{"code":"INFORMATION","label":"Information"},"isRead":false}]'
                );
            } else if (req.getMethod() == 'POST') {
                res.setBody(
                    '{"id":2,"content":"Réponse","senderName":"Prestataire","senderRole":"PRESTATAIRE","sentAt":"2026-05-18T11:00:00Z","tag":"QUESTION_TECHNIQUE","isRead":false}'
                );
            } else {
                res.setBody('{"isRead":true}');
            }
            return res;
        }
    }

    @IsTest
    static void getMessages_rejectsAvocat() {
        Account acc = new Account(Name = 'Test Prestataire');
        insert acc;

        Contact con = new Contact(LastName = 'Test', AccountId = acc.Id);
        insert con;

        Mission__c m = new Mission__c(
            Name = 'Mission test',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Avocat',
            Id_Externe_API__c = '12345'
        );
        insert m;

        User u = createPortalUser(con.Id);
        Boolean rejected = false;
        System.runAs(u) {
            try {
                MissionMessageController.getMessages(m.Id);
            } catch (AuraHandledException e) {
                rejected = true;
            }
        }
        System.assert(rejected, 'Avocat doit être refusé');
    }

    @IsTest
    static void getMessages_success() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Med Prest');
        insert acc;

        Contact con = new Contact(LastName = 'Med', AccountId = acc.Id);
        insert con;

        Mission__c m = new Mission__c(
            Name = 'Mission med',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180021'
        );
        insert m;

        if (MissionEchangeLocalService.isAvailable()) {
            MissionEchangeLocalService.createInboundSynced(
                m.Id,
                'Bonjour',
                'INFORMATION',
                'GS',
                1,
                '2026-05-18T10:00:00Z'
            );
        }

        User u = createPortalUser(con.Id);
        Test.setMock(HttpCalloutMock.class, new MessagesMock());
        Test.startTest();
        System.runAs(u) {
            List<MissionMessageController.MessageDto> msgs =
                MissionMessageController.getMessages(m.Id);
            System.assertEquals(1, msgs.size());
            System.assertEquals('Bonjour', msgs[0].content);
            System.assertEquals(false, msgs[0].isMine);
        }
        Test.stopTest();
    }

    @IsTest
    static void sendMessage_posts_to_numeroMission_path() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Med Prest');
        insert acc;

        Contact con = new Contact(LastName = 'Med', AccountId = acc.Id);
        insert con;

        Mission__c m = new Mission__c(
            Name = 'Mission med post',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180021'
        );
        insert m;

        User u = createPortalUser(con.Id);
        MessagesMock mock = new MessagesMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.runAs(u) {
            MissionMessageController.MessageDto sent = MissionMessageController.sendMessage(
                m.Id,
                'Bonjour gestionnaire',
                'QUESTION_TECHNIQUE'
            );
            System.assertNotEquals(null, sent);
            System.assertEquals('Bonjour gestionnaire', sent.content);
            System.assertEquals(
                false,
                sent.deliveredToGestionnaire,
                'Réponse immédiate : en attente de sync asynchrone'
            );
            if (MissionEchangeLocalService.isAvailable()) {
                System.assertEquals(
                    1,
                    [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id],
                    'Historique conservé dans Echange__c'
                );
            }
        }
        Test.stopTest();

        System.runAs(u) {
            System.assert(
                mock.lastPostPath != null && mock.lastPostPath.contains('202605180021'),
                'POST queueable vers /missions/{numeroMission}/messages : ' + mock.lastPostPath
            );
            System.assert(
                mock.lastPostBody != null && mock.lastPostBody.contains('QUESTION_TECHNIQUE'),
                'Tag API attendu : ' + mock.lastPostBody
            );
            List<MissionMessageController.MessageDto> afterSync =
                MissionMessageController.getMessages(m.Id);
            Boolean synced = false;
            for (MissionMessageController.MessageDto dto : afterSync) {
                if (dto.content == 'Bonjour gestionnaire' && dto.deliveredToGestionnaire == true) {
                    synced = true;
                }
            }
            System.assert(synced, 'Message synchronisé après le job asynchrone');
        }
    }

    @TestSetup
    static void setupReplayMission() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Med Replay');
        insert acc;
        Contact con = new Contact(LastName = 'Replay', AccountId = acc.Id);
        insert con;
        Mission__c m = new Mission__c(
            Name = 'Mission replay',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180099'
        );
        insert m;
        MissionEchangeLocalService.createOutboundPending(
            m.Id,
            'Message en attente sync',
            'INFORMATION'
        );
        createPortalUser(con.Id);
    }

    @IsTest
    static void syncPendingOutbound_marks_message_synced() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Med Sync');
        insert acc;
        Contact con = new Contact(LastName = 'Sync', AccountId = acc.Id);
        insert con;
        Mission__c m = new Mission__c(
            Name = 'Mission sync out',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180077'
        );
        insert m;

        User u = createPortalUser(con.Id);
        MessagesMock mock = new MessagesMock();
        Test.setMock(HttpCalloutMock.class, mock);

        System.runAs(u) {
            MissionMessageController.MessageDto sent = MissionMessageController.sendMessage(
                m.Id,
                'Sync immediat',
                'INFORMATION'
            );
            System.assertEquals(false, sent.deliveredToGestionnaire);
            MissionMessageController.MessageDto synced = MissionMessageController.syncPendingOutbound(
                m.Id,
                sent.sfExchangeId
            );
            System.assertNotEquals(null, synced);
            System.assertNotEquals(null, synced.sfExchangeId, 'Echange local conservé');
        }
    }

    @IsTest
    static void getMessages_portal_sees_multiple_gestionnaire_rows() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Account acc = new Account(Name = 'Med GS');
        insert acc;
        Contact con = new Contact(LastName = 'GSView', AccountId = acc.Id);
        insert con;
        Mission__c m = new Mission__c(
            Name = 'Mission gs view',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180055'
        );
        insert m;

        MissionEchangeLocalService.createInboundSynced(
            m.Id,
            'Bonjour gestionnaire 1',
            'INFORMATION',
            'GS',
            10,
            '2026-05-18T09:00:00Z'
        );
        MissionEchangeLocalService.createInboundSynced(
            m.Id,
            'Bonjour gestionnaire 2',
            'QUESTION_TECHNIQUE',
            'GS',
            11,
            '2026-05-18T10:00:00Z'
        );
        MissionEchangeLocalService.createOutboundPending(m.Id, 'Reponse prestataire', 'INFORMATION');

        User u = createPortalUser(con.Id);
        Test.setMock(HttpCalloutMock.class, new MessagesMock());
        System.runAs(u) {
            List<MissionMessageController.MessageDto> msgs =
                MissionMessageController.getMessages(m.Id);
            Integer gest = 0;
            for (MissionMessageController.MessageDto dto : msgs) {
                if (dto != null && dto.isMine != true) {
                    gest++;
                }
            }
            System.assert(
                gest >= 2,
                'Le portail doit voir les messages gestionnaire (isMine=false). Trouvé : ' + gest
            );
        }
    }

    @IsTest
    static void getMessages_replays_pending_local_to_api() {
        if (!MissionEchangeLocalService.isAvailable()) {
            return;
        }
        Mission__c m = [SELECT Id FROM Mission__c WHERE Numero_mission2__c = '202605180099' LIMIT 1];
        System.assertEquals(1, [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id]);

        User u = [
            SELECT Id
            FROM User
            WHERE Contact.LastName = 'Replay'
            LIMIT 1
        ];

        Test.setMock(HttpCalloutMock.class, new ReplayMock());
        Test.startTest();
        System.runAs(u) {
            List<MissionMessageController.MessageDto> msgs = MissionMessageController.getMessages(m.Id);
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id],
                'Echange conservé après resync'
            );
            Boolean foundReplayed = false;
            for (MissionMessageController.MessageDto dto : msgs) {
                if (dto.content != null
                    && dto.content.contains('Message en attente sync')
                    && dto.deliveredToGestionnaire == true) {
                    foundReplayed = true;
                }
            }
            System.assert(foundReplayed, 'Message resynchronisé (SYNCED) dans Echange__c');
        }
        Test.stopTest();
    }

    private class ReplayMock implements HttpCalloutMock {
        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'GET') {
                res.setBody(
                    '[{"id":88,"content":"Message en attente sync","senderName":"Prestataire","senderRole":"PRESTATAIRE","sentAt":"2026-05-18T12:00:00Z","tag":"INFORMATION","isRead":false}]'
                );
            } else if (req.getMethod() == 'POST') {
                res.setBody(
                    '{"id":88,"content":"Message en attente sync","senderName":"Prestataire","senderRole":"PRESTATAIRE","sentAt":"2026-05-18T12:00:00Z","tag":"INFORMATION","isRead":false}'
                );
            }
            return res;
        }
    }

    private static User createPortalUser(Id contactId) {
        Profile p = [SELECT Id FROM Profile WHERE Name LIKE '%Customer Community%' LIMIT 1];
        User u = new User(
            Alias = 'tport',
            Email = 'testport@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Portail',
            LanguageLocaleKey = 'fr',
            LocaleSidKey = 'fr_FR_Euro',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Europe/Paris',
            Username = 'testport' + Crypto.getRandomInteger() + '@example.com',
            ContactId = contactId
        );
        insert u;
        return u;
    }
}
