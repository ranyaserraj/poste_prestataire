public with sharing class MissionPortailController6Copy {

    /* ══════════════════════════════════════════════════════
       ÉTAPE 1 — Récupérer les missions
       ══════════════════════════════════════════════════════ */

    // ✅ MODE PORTAIL (Experience Cloud) — actif
    // Apex récupère lui-même le compte de l'utilisateur connecté
    @AuraEnabled(cacheable=true)
    public static List<MissionWrapper> getMissions() {
        try {
            User currentUser = [
                SELECT Contact.AccountId
                FROM User
                WHERE Id = :UserInfo.getUserId()
                LIMIT 1
            ];

            if (currentUser.Contact == null || currentUser.Contact.AccountId == null) {
                return new List<MissionWrapper>();
            }

            return fetchMissions(currentUser.Contact.AccountId);

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ✅ MODE ACCOUNT (Record Page) — commenter pour le portail
    // @AuraEnabled(cacheable=true)
    // public static List<MissionWrapper> getMissions(Id accountId) {
    //     try {
    //         if (accountId == null) { 
    //             return new List<MissionWrapper>();
    //         }
    //         return fetchMissions(accountId);
    //     } catch (Exception e) {
    //         throw new AuraHandledException(e.getMessage());
    //     }
    // }

    /* ══════════════════════════════════════════════════════
       MÉTHODE COMMUNE — Requête partagée entre les deux modes
       ══════════════════════════════════════════════════════ */
    private static List<MissionWrapper> fetchMissions(Id accountId) {
        List<Mission__c> missions = [
            SELECT Id, Name, Numero_mission__c, Statut__c, Branche__c,
                   Date_nomination__c, Date_survenance__c, Date_convocation__c,
                   Date_echeance__c, Date_cloture__c, Numero_sinistre__c,
                   Reference_dossier__c, Echanges_non_lus__c, Rapport_depose__c,
                   Prestataire__r.Name, RecordTypeId
            FROM Mission__c
            WHERE Prestataire__c = :accountId
            ORDER BY Date_nomination__c DESC
            LIMIT 100
        ];

        List<MissionWrapper> result = new List<MissionWrapper>();
        for (Mission__c m : missions) {
            result.add(new MissionWrapper(m));
        }
        return result;
    }

    /* ══════════════════════════════════════════════════════
       ÉTAPE 2 — RecordTypeId Mission selon le compte
       ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static Id getMissionRecordTypeId(Id accountRecordTypeId) {
        try {
            if (accountRecordTypeId == null) return null;

            RecordType accountRt = [
                SELECT DeveloperName
                FROM RecordType
                WHERE Id = :accountRecordTypeId
                LIMIT 1
            ];

            List<RecordType> missionRts = [
                SELECT Id
                FROM RecordType
                WHERE SObjectType = 'Mission__c'
                AND DeveloperName = :accountRt.DeveloperName
                AND IsActive = true
                LIMIT 1
            ];

            return missionRts.isEmpty() ? null : missionRts[0].Id;

        } catch (Exception e) {
            return null;
        }
    }

    /* ══════════════════════════════════════════════════════
       ÉTAPE 3 — Options de filtres pour le portail
       (Retourne directement les valeurs de picklist existantes)
       ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getStatutOptions() {
        try {
            User currentUser = [
                SELECT Contact.AccountId
                FROM User
                WHERE Id = :UserInfo.getUserId()
                LIMIT 1
            ];

            if (currentUser.Contact == null || currentUser.Contact.AccountId == null) {
                return new List<PicklistOption>();
            }

            Set<String> statuts = new Set<String>();
            for (Mission__c m : [
                SELECT Statut__c FROM Mission__c
                WHERE Prestataire__c = :currentUser.Contact.AccountId
                AND Statut__c != null
            ]) {
                statuts.add(m.Statut__c);
            }

            List<PicklistOption> result = new List<PicklistOption>();
            result.add(new PicklistOption('Tous les statuts', 'toutes'));
            for (String s : statuts) {
                result.add(new PicklistOption(getStatutLabel(s), s));
            }
            return result;

        } catch (Exception e) {
            return new List<PicklistOption>();
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getBrancheOptions() {
        try {
            User currentUser = [
                SELECT Contact.AccountId
                FROM User
                WHERE Id = :UserInfo.getUserId()
                LIMIT 1
            ];

            if (currentUser.Contact == null || currentUser.Contact.AccountId == null) {
                return new List<PicklistOption>();
            }

            Set<String> branches = new Set<String>();
            for (Mission__c m : [
                SELECT Branche__c FROM Mission__c
                /*WHERE Prestataire__c = :currentUser.Contact.AccountId
                AND Branche__c != null*/
                WHERE Branche__c != null
            ]) {
                branches.add(m.Branche__c);
            }

            List<PicklistOption> result = new List<PicklistOption>();
            result.add(new PicklistOption('Toutes les branches', 'toutes'));
            for (String b : branches) {
                result.add(new PicklistOption(b, b));
            }
            return result;

        } catch (Exception e) {
            return new List<PicklistOption>();
        }
    }

    /* ══════════════════════════════════════════════════════
       UTILITAIRES
       ══════════════════════════════════════════════════════ */
    private static String getStatutLabel(String statut) {
        Map<String, String> labels = new Map<String, String>{
            'Initiee'         => 'Initiée',
            'En_cours'        => 'En cours',
            'Rapport_recu'    => 'Rapport reçu',
            'Rapport_attendu' => 'Rapport attendu',
            'Cloturee'        => 'Clôturée',
            'Annulee'         => 'Annulée'
        };
        return labels.containsKey(statut) ? labels.get(statut) : statut;
    }

    /* ══════════════════════════════════════════════════════
       WRAPPER CLASSES
       ══════════════════════════════════════════════════════ */
    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;

        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class MissionWrapper {
        @AuraEnabled public String Id;
        @AuraEnabled public String Numero_mission;
        @AuraEnabled public String Statut;
        @AuraEnabled public String Branche;
        @AuraEnabled public String Date_nomination;
        @AuraEnabled public String Date_survenance;
        @AuraEnabled public String Date_convocation;
        @AuraEnabled public String Date_echeance;
        @AuraEnabled public String Date_cloture;
        @AuraEnabled public String Numero_sinistre;
        @AuraEnabled public String Reference_dossier;
        @AuraEnabled public Decimal Echanges_non_lus;
        @AuraEnabled public Boolean Rapport_depose;
        @AuraEnabled public String Prestataire_Name;
        @AuraEnabled public String RecordTypeId;

        public MissionWrapper(Mission__c m) {
            this.Id                = m.Id;
            this.Numero_mission    = m.Numero_mission__c;
            this.Statut            = m.Statut__c;
            this.Branche           = m.Branche__c;
            this.Date_nomination   = m.Date_nomination__c != null ? String.valueOf(m.Date_nomination__c) : null;
            this.Date_survenance   = m.Date_survenance__c != null ? String.valueOf(m.Date_survenance__c) : null;
            this.Date_convocation  = m.Date_convocation__c != null ? String.valueOf(m.Date_convocation__c) : null;
            this.Date_echeance     = m.Date_echeance__c != null ? String.valueOf(m.Date_echeance__c) : null;
            this.Date_cloture      = m.Date_cloture__c != null ? String.valueOf(m.Date_cloture__c) : null;
            this.Numero_sinistre   = m.Numero_sinistre__c;
            this.Reference_dossier = m.Reference_dossier__c;
            this.Echanges_non_lus  = m.Echanges_non_lus__c;
            this.Rapport_depose    = m.Rapport_depose__c;
            this.Prestataire_Name  = m.Prestataire__r != null ? m.Prestataire__r.Name : null;
            this.RecordTypeId      = String.valueOf(m.RecordTypeId);
        }
    }
}

