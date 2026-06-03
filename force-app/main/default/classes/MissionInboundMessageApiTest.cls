@IsTest
private class MissionInboundMessageApiTest {

    private class GestionnairePostMock implements HttpCalloutMock {
        public String lastPath;
        public String lastBody;

        public HTTPResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'POST') {
                lastPath = req.getEndpoint();
                lastBody = req.getBody();
                res.setBody(
                    '{"id":99,"content":"Msg gestionnaire","senderName":"GS","senderRole":"GESTIONNAIRE","sentAt":"2026-05-24T10:00:00Z","tag":"INFORMATION","isRead":false}'
                );
            } else if (req.getMethod() == 'GET') {
                res.setBody('[]');
            }
            return res;
        }
    }

    @IsTest
    static void forwardToGestionnaire_postsWithGestionnaireRole() {
        Account acc = new Account(Name = 'Prestataire inbound');
        insert acc;

        Mission__c m = new Mission__c(
            Name = 'Mission inbound',
            Prestataire__c = acc.Id,
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605240099'
        );
        insert m;

        GestionnairePostMock mock = new GestionnairePostMock();
        Test.setMock(HttpCalloutMock.class, mock);

        MissionInboundMessageService.InboundRequest req = new MissionInboundMessageService.InboundRequest();
        req.content = 'Msg gestionnaire';
        req.tag = 'INFORMATION';
        req.senderName = 'Gestionnaire Test';
        req.senderRole = 'GESTIONNAIRE';

        Test.startTest();
        MissionInboundMessageService.InboundResult result = MissionInboundMessageService.forwardToGestionnaireApi(
            '202605240099',
            req
        );
        Test.stopTest();

        System.assertEquals(201, result.httpStatus);
        System.assertEquals(true, result.deliveredToGestionnaire);
        System.assert(
            mock.lastPath != null && mock.lastPath.contains('202605240099'),
            'POST EC2 sur numeroMission : ' + mock.lastPath
        );
        System.assert(
            mock.lastBody != null && mock.lastBody.contains('GESTIONNAIRE'),
            'senderRole GESTIONNAIRE : ' + mock.lastBody
        );
        if (MissionEchangeLocalService.isAvailable()) {
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Echange__c WHERE Mission__c = :m.Id],
                'Message gestionnaire archivé dans Echange__c'
            );
        }
    }

    @IsTest
    static void forwardToGestionnaire_returns404WhenMissionMissing() {
        Test.setMock(HttpCalloutMock.class, new GestionnairePostMock());

        MissionInboundMessageService.InboundRequest req = new MissionInboundMessageService.InboundRequest();
        req.content = 'Test';
        req.tag = 'INFORMATION';

        MissionInboundMessageService.InboundResult result = MissionInboundMessageService.forwardToGestionnaireApi(
            '999999999999',
            req
        );
        System.assertEquals(404, result.httpStatus);
    }

    @IsTest
    static void forwardToGestionnaire_rejectsAvocat() {
        Mission__c m = new Mission__c(
            Name = 'Mission avocat',
            Type_Prestataire__c = 'Avocat',
            Numero_mission2__c = '202605240100'
        );
        insert m;

        MissionInboundMessageService.InboundRequest req = new MissionInboundMessageService.InboundRequest();
        req.content = 'Test';
        req.tag = 'INFORMATION';

        MissionInboundMessageService.InboundResult result = MissionInboundMessageService.forwardToGestionnaireApi(
            '202605240100',
            req
        );
        System.assertEquals(422, result.httpStatus);
    }

    @IsTest
    static void service_requiresContentAndTag() {
        MissionInboundMessageService.InboundResult result = MissionInboundMessageService.forwardToGestionnaireApi(
            '202605240099',
            new MissionInboundMessageService.InboundRequest()
        );
        System.assertEquals(400, result.httpStatus);
    }
}
