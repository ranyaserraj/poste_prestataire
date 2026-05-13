public with sharing class MissionCreateMedecinGateControllerCopy {
    
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getGateInfo() {
        try {
            Map<String, Object> result = new Map<String, Object>{
                'accountId' => null,
                'accountRecordTypeDeveloperName' => null,
                'branches' => null,
                'missionMedecinRecordTypeId' => null
            };
            
            // Étape 1 — Récupère le ContactId de l'utilisateur connecté
            User currentUser = [
                SELECT ContactId 
                FROM User 
                WHERE Id = :UserInfo.getUserId() 
                LIMIT 1
            ];
            
            if (currentUser.ContactId == null) {
                return result;
            }
            
            // Étape 2 — Récupère l'AccountId du Contact
            Contact contact = [
                SELECT AccountId 
                FROM Contact 
                WHERE Id = :currentUser.ContactId 
                LIMIT 1
            ];
            
            if (contact.AccountId == null) {
                return result;
            }
            
            // Étape 3 — Récupère le Account avec RecordType et Branches
            Account account = [
                SELECT Id, 
                       RecordType.DeveloperName, 
                       Branches__c
                FROM Account 
                WHERE Id = :contact.AccountId 
                LIMIT 1
            ];
            
            // Étape 4 — Remplit le résultat
            result.put('accountId', account.Id);
            result.put('accountRecordTypeDeveloperName', account.RecordType.DeveloperName);
            result.put('branches', account.Branches__c);
            result.put('missionMedecinRecordTypeId', resolveMissionMedecinRecordTypeId());

            return result;

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Record type Mission « Médecin » via Describe (fiable en Experience Cloud).
     * Évite le repli LDS sur defaultRecordTypeId (souvent Avocat / autre) quand le find LWC échoue.
     */
    private static Id resolveMissionMedecinRecordTypeId() {
        for (Schema.RecordTypeInfo rti : Mission__c.SObjectType.getDescribe().getRecordTypeInfos()) {
            if (!rti.isAvailable()) {
                continue;
            }
            String d = rti.getDeveloperName();
            if (String.isNotBlank(d)) {
                String lower = d.toLowerCase();
                if (lower == 'medecin' || lower.contains('medecin')) {
                    return rti.getRecordTypeId();
                }
            }
            String nm = rti.getName();
            if (String.isNotBlank(nm)) {
                String nLower = nm.toLowerCase();
                if (nLower.contains('medecin') || nLower.contains('médecin')) {
                    return rti.getRecordTypeId();
                }
            }
        }
        return null;
    }
}

