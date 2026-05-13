public with sharing class MissionController {

    // ============================================================
    // SEARCH POLICE (mock — sera remplacé par appel BFF)
    // ============================================================
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchPolice(
        String numPolice, String raisonSociale) {

        List<Map<String, Object>> polices = new List<Map<String, Object>>();

        Map<String, Object> police1 = new Map<String, Object>{
            'numPolice' => 'POL-2024-001',
            'raisonSociale' => 'Maroc Telecom',
            'codeIntermediaire' => 'INT-001',
            'nomIntermediaire' => 'Allianz Maroc',
            'dateDebut' => '2024-01-01',
            'dateFin' => '2026-12-31'
        };
        polices.add(police1);

        Map<String, Object> police2 = new Map<String, Object>{
            'numPolice' => 'POL-2024-002',
            'raisonSociale' => 'OCP Group',
            'codeIntermediaire' => 'INT-002',
            'nomIntermediaire' => 'Wafa Assurance',
            'dateDebut' => '2024-01-01',
            'dateFin' => '2026-12-31'
        };
        polices.add(police2);

        return polices;
    }

    // ============================================================
    // SEARCH ADHERENT (mock — sera remplacé par appel BFF)
    // ============================================================
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchAdherent(
        String nom, String prenom,
        String cin, String numAffilie,
        String numPolice) {

        List<Map<String, Object>> adherents = new List<Map<String, Object>>();

        Map<String, Object> adherent1 = new Map<String, Object>{
            'nom' => 'Alami',
            'prenom' => 'Mohamed',
            'cin' => 'BK234567',
            'numAffilie' => 'ADH-789',
            'dateNaissance' => '1985-03-15'
        };
        adherents.add(adherent1);

        Map<String, Object> adherent2 = new Map<String, Object>{
            'nom' => 'Benali',
            'prenom' => 'Karim',
            'cin' => 'BE123456',
            'numAffilie' => 'ADH-123',
            'dateNaissance' => '1990-07-20'
        };
        adherents.add(adherent2);

        return adherents;
    }

    // ============================================================
    // CREATE MISSION
    // ============================================================
    @AuraEnabled
    public static String createMission(
        String numPolice,
        String numAffilie,
        String nomPatient,
        String prenomPatient,
        String cinPatient,
        String dateNaissance,
        String lienParente,
        String motifHospitalisation,
        String medecinTraitant,
        String dateHospitalisation,
        String codeINPE,
        String dateSurvenance) {

        try {
            Id clinicRTId = Schema.SObjectType.Mission__c
                .getRecordTypeInfosByDeveloperName()
                .get('Clinique')
                .getRecordTypeId();

            // Récupérer l'Account du user connecté
            User currentUser = [
                SELECT ContactId, Contact.AccountId
                FROM User
                WHERE Id = :UserInfo.getUserId()
                LIMIT 1
            ];

            Mission__c mission = new Mission__c();
            mission.RecordTypeId = clinicRTId;

            // Lier la mission au prestataire connecté
            if (currentUser.ContactId != null) {
                Contact c = [
                    SELECT AccountId
                    FROM Contact
                    WHERE Id = :currentUser.ContactId
                    LIMIT 1
                ];
                if (c.AccountId != null) {
                    mission.Prestataire__c = c.AccountId;
                }
            }

            mission.Numero_police__c = numPolice;
            mission.Numero_affilie__c = numAffilie;
            mission.Nom_patient__c = nomPatient;
            mission.Prenom_patient__c = prenomPatient;
            mission.CIN_patient__c = cinPatient;
            mission.Date_de_naissance_patient__c = parseDate(dateNaissance);
            mission.Lien_de_parente__c = lienParente;
            mission.Motif_d_hospitalisation__c = motifHospitalisation;
            mission.Medecin_traitant__c = medecinTraitant;
            mission.Date_hospitalisation__c = parseDate(dateHospitalisation);
            mission.Date_survenance__c = parseDate(dateSurvenance);
            mission.Branche__c = 'AT';
            mission.Type_de_mission__c = 'Auto-missionnement';
            mission.Type_de_prestation__c = 'Prémission';
            mission.Nature_Mission__c = 'Prise en charge';
            mission.Statut__c = 'Initiée';

            // TODO : mapper codeINPE quand le champ sera créé sur Mission__c
            // mission.Code_INPE__c = codeINPE;

            insert mission;
            return mission.Id;

        } catch (Exception e) {
            throw new AuraHandledException('Erreur création mission : ' + e.getMessage());
        }
    }

    private static Date parseDate(String dateStr) {
        if (String.isBlank(dateStr)) return null;
        try {
            return Date.valueOf(dateStr);
        } catch (Exception e) {
            throw new AuraHandledException('Format date invalide : ' + dateStr);
        }
    }
}