@IsTest
private class MissionMessagingUtilTest {

    private static final String API_RESPONSE =
        '{"id":42,"numeroMission":"202605180021","status":"PENDING","branche":"SANTE"}';

    @IsTest
    static void extractNumeroMission_from_api_response() {
        System.assertEquals(
            '202605180021',
            MissionMessagingUtil.extractNumeroMission(API_RESPONSE)
        );
    }

    @IsTest
    static void extractStorableNumeroMission2_truncates_to_20() {
        String longNm = '2026051800219999999999';
        System.assertEquals(
            longNm.substring(0, 20),
            MissionMessagingUtil.extractStorableNumeroMission2(
                '{"numeroMission":"' + longNm + '"}'
            )
        );
    }

    @IsTest
    static void resolveFromMission_uses_numero_mission2_only() {
        Mission__c m = new Mission__c(Numero_mission2__c = '202605180021');
        System.assertEquals('202605180021', MissionMessagingUtil.resolveMessagingIdsFromMission(m)[0]);
    }

    @IsTest
    static void resolveFromMission_empty_without_numero_mission2() {
        Mission__c m = new Mission__c();
        System.assertEquals(0, MissionMessagingUtil.resolveMessagingIdsFromMission(m).size());
    }

    @IsTest
    static void canUseMessaging_true_when_numero_mission2_set() {
        Mission__c m = new Mission__c(
            Type_Prestataire__c = 'Medecin',
            Numero_mission2__c = '202605180021'
        );
        System.assertEquals(true, MissionMessagingUtil.canUseMessaging(m));
    }
}
