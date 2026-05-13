public with sharing class MissionCreateMedecinGateController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getGateInfo() {
        try {
            Map<String, Object> result = new Map<String, Object>{
                'accountId' => null,
                'accountRecordTypeDeveloperName' => null,
                'branches' => null
            };

            User currentUser = [
                SELECT ContactId
                FROM User
                WHERE Id = :UserInfo.getUserId()
                LIMIT 1
            ];

            if (currentUser.ContactId == null) return result;

            Contact contact = [
                SELECT AccountId
                FROM Contact
                WHERE Id = :currentUser.ContactId
                LIMIT 1
            ];

            if (contact.AccountId == null) return result;

            Account account = [
                SELECT Id, RecordType.DeveloperName, Branches__c
                FROM Account
                WHERE Id = :contact.AccountId
                LIMIT 1
            ];

            result.put('accountId', account.Id);
            result.put('accountRecordTypeDeveloperName', account.RecordType.DeveloperName);
            result.put('branches', account.Branches__c);

            return result;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}

