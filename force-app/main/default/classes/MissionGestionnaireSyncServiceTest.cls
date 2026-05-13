@IsTest
private class MissionGestionnaireSyncServiceTest {
    private class MockHttp200 implements HttpCalloutMock {
        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setStatus('OK');
            res.setBody('{"id":"EXT-GEST-001"}');
            return res;
        }
    }

    private class MockHttp500 implements HttpCalloutMock {
        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setStatus('Server Error');
            res.setBody('{"error":"fail"}');
            return res;
        }
    }

    @IsTest
    static void http_500_sets_error_status() {
        Test.setMock(HttpCalloutMock.class, new MockHttp500());

        System.runAs(adminUser()) {
            Mission__c m = new Mission__c(
                Name = 'Test HTTP 500',
                RecordTypeId = medecinRecordTypeId(),
                Type_Prestataire__c = 'Medecin',
                Type_de_mission__c = 'Auto-missionnement',
                Branche__c = 'Santé',
                Nature_Mission__c = 'VSG',
                Nombre_dossiers__c = 1
            );

            Test.startTest();
            insert m;
            Test.stopTest();

            Mission__c r = [SELECT Statut_API__c, Erreur_API__c FROM Mission__c WHERE Id = :m.Id];
            System.assert(r.Statut_API__c != null && r.Statut_API__c.startsWith('HTTP_'), r.Statut_API__c);
            System.assert(String.isNotBlank(r.Erreur_API__c));
        }
    }

    @IsTest
    static void shouldEnqueue_false_for_non_auto() {
        Mission__c m = new Mission__c(
            Type_de_mission__c = 'Missionnement',
            Type_Prestataire__c = 'Medecin',
            Branche__c = 'Santé',
            Nature_Mission__c = 'VSG'
        );
        System.assertEquals(false, MissionGestionnaireSyncService.shouldEnqueue(m));
    }

    private static User adminUser() {
        List<User> users = [
            SELECT Id
            FROM User
            WHERE IsActive = TRUE
                AND (Profile.Name = 'System Administrator' OR Profile.Name = 'Administrateur système')
            LIMIT 1
        ];
        return users.isEmpty() ? new User(Id = UserInfo.getUserId()) : users[0];
    }

    private static Id medecinRecordTypeId() {
        for (RecordTypeInfo ri : Schema.SObjectType.Mission__c.getRecordTypeInfos()) {
            if (ri.isAvailable() && ri.getDeveloperName() == 'Medecin') {
                return ri.getRecordTypeId();
            }
        }
        return Schema.SObjectType.Mission__c.getRecordTypeInfos()[0].getRecordTypeId();
    }

    @IsTest
    static void autoMissionnement_sante_vacation_siege_syncs_via_queueable() {
        Test.setMock(HttpCalloutMock.class, new MockHttp200());

        System.runAs(adminUser()) {
            Mission__c m = new Mission__c(
                Name = 'Test sync santé',
                RecordTypeId = medecinRecordTypeId(),
                Type_Prestataire__c = 'Medecin',
                Type_de_mission__c = 'Auto-missionnement',
                Branche__c = 'Santé',
                Nature_Mission__c = 'VSG',
                Nombre_dossiers__c = 5,
                Heure_debut_passage__c = Time.newInstance(9, 0, 0, 0),
                Heure_fin_passage__c = Time.newInstance(11, 0, 0, 0)
            );

            Test.startTest();
            insert m;
            Test.stopTest();

            Mission__c r = [SELECT Statut_API__c, Id_Externe_API__c FROM Mission__c WHERE Id = :m.Id];
            System.assertEquals('Synced', r.Statut_API__c, 'Statut sync gestionnaire');
            System.assertEquals('EXT-GEST-001', r.Id_Externe_API__c);
        }
    }

    @IsTest
    static void autoMissionnement_at_controle_medicale_syncs() {
        Test.setMock(HttpCalloutMock.class, new MockHttp200());

        System.runAs(adminUser()) {
            Mission__c m = new Mission__c(
                Name = 'Test sync AT',
                RecordTypeId = medecinRecordTypeId(),
                Type_Prestataire__c = 'Medecin',
                Type_de_mission__c = 'Auto-missionnement',
                Branche__c = 'AT',
                Nature_Mission__c = 'CM',
                Type_Sinistre__c = 'MP',
                Numero_police__c = '2052026000002',
                Date_survenance__c = Date.newInstance(2024, 5, 1),
                Date_nomination__c = Date.newInstance(2024, 5, 10),
                Reference_dossier_prestataire__c = 'REF-MED-961',
                Personnes_impliquees__c = 'Victime|M.|Alami|Said|1988-01-01|Non blessé'
            );

            Test.startTest();
            insert m;
            Test.stopTest();

            Mission__c r = [SELECT Statut_API__c, Id_Externe_API__c FROM Mission__c WHERE Id = :m.Id];
            System.assertEquals('Synced', r.Statut_API__c, 'Statut sync AT');
            System.assertEquals('EXT-GEST-001', r.Id_Externe_API__c);
        }
    }

    @IsTest
    static void non_auto_missionnement_does_not_sync() {
        Test.setMock(HttpCalloutMock.class, new MockHttp200());

        System.runAs(adminUser()) {
            Mission__c m = new Mission__c(
                Name = 'Pas auto',
                RecordTypeId = medecinRecordTypeId(),
                Type_Prestataire__c = 'Medecin',
                Type_de_mission__c = 'Missionnement',
                Branche__c = 'Santé',
                Nature_Mission__c = 'VSG'
            );

            Test.startTest();
            insert m;
            Test.stopTest();

            Mission__c r = [SELECT Statut_API__c FROM Mission__c WHERE Id = :m.Id];
            System.assertEquals(null, r.Statut_API__c);
        }
    }
}
