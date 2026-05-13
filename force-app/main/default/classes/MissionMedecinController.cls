/**
 * Données fiche mission pour la page Experience « Mission médecin » (detailMissionMedecin).
 * Logique field sets / prestataire — séparée de MissionController (création clinique, mocks recherche).
 */
public with sharing class MissionMedecinController {

    /**
     * missionId en String (LWR / query). cacheable=false pour appels impératifs fiables depuis LWR.
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getMissionDetails(String missionId) {

        Id mid = parseMissionRecordId(missionId);
        if (mid == null) {
            throw new AuraHandledException('missionId requis ou invalide');
        }

        User currentUser = [
            SELECT ContactId
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];

        if (currentUser.ContactId == null) {
            throw new AuraHandledException(
                'Utilisateur sans Contact ou Account associé — impossible de déterminer le type prestataire'
            );
        }

        Contact userContact = [
            SELECT AccountId
            FROM Contact
            WHERE Id = :currentUser.ContactId
            LIMIT 1
        ];

        if (userContact.AccountId == null) {
            throw new AuraHandledException(
                'Utilisateur sans Account associé — impossible de déterminer le type prestataire'
            );
        }
        Id accountId = userContact.AccountId;

        Map<String, Schema.SObjectField> accountFieldMap = Schema.SObjectType.Account.fields.getMap();
        List<String> accountFields = new List<String>{
            'Id',
            'Name',
            'RecordType.DeveloperName'
        };
        if (accountFieldMap.containsKey('SpecialiteMedecin__c')) {
            accountFields.add('SpecialiteMedecin__c');
        }
        if (accountFieldMap.containsKey('Specialite__c')) {
            accountFields.add('Specialite__c');
        }

        String accQuery = 'SELECT ' + String.join(accountFields, ', ') +
            ' FROM Account WHERE Id = :accountId LIMIT 1';
        Account prestataire = (Account)Database.query(accQuery);

        String typePrestataire = prestataire.RecordType?.DeveloperName;

        if (String.isBlank(typePrestataire)) {
            throw new AuraHandledException('Account sans Record Type — configuration invalide');
        }

        Boolean isMedecinAccount = isMedecinRecordTypeDeveloperName(typePrestataire);

        List<Mission__c> ctxRows = [
            SELECT Branche__c, Nature_Mission__c
            FROM Mission__c
            WHERE Id = :mid AND Prestataire__c = :accountId
            LIMIT 1
        ];
        if (ctxRows.isEmpty()) {
            throw new AuraHandledException(
                'Mission introuvable ou non associée à votre compte prestataire.'
            );
        }
        Mission__c ctx = ctxRows[0];

        String fieldSetName = isMedecinAccount
            ? getFieldSetNameMedecin(ctx.Branche__c, ctx.Nature_Mission__c)
            : getFieldSetName(typePrestataire);

        Schema.FieldSet fs = Schema.SObjectType.Mission__c
            .fieldSets.getMap()
            .get(fieldSetName);

        if (fs == null) {
            throw new AuraHandledException(
                'Field Set introuvable : ' + fieldSetName +
                ' — créer le Field Set sur Mission__c'
            );
        }

        List<Schema.FieldSetMember> fsMembers = fs.getFields();

        if (fsMembers.isEmpty()) {
            throw new AuraHandledException('Field Set vide : ' + fieldSetName);
        }

        Set<String> fieldPaths = new Set<String>{ 'Id', 'Name' };
        for (Schema.FieldSetMember f : fsMembers) {
            fieldPaths.add(f.getFieldPath());
        }
        fieldPaths.add('Branche__c');
        fieldPaths.add('Nature_Mission__c');
        fieldPaths.add('Type_de_mission__c');
        fieldPaths.add('Date_nomination__c');
        fieldPaths.add('Date_echeance__c');
        fieldPaths.add('Date_convocation__c');
        fieldPaths.add('Specialite__c');

        String query = 'SELECT ' + String.join(new List<String>(fieldPaths), ', ') +
               ' FROM Mission__c WHERE Id = :mid AND Prestataire__c = :accountId LIMIT 1';

        List<Mission__c> missions = Database.query(query);

        if (missions.isEmpty()) {
            throw new AuraHandledException(
                'Mission introuvable ou accès refusé (champs / droits). Vérifiez le field set « ' +
                fieldSetName + ' » et la FLS sur Mission__c.'
            );
        }

        Mission__c mission = missions[0];

        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        for (Schema.FieldSetMember f : fsMembers) {
            fields.add(new Map<String, Object>{
                'label' => f.getLabel(),
                'apiName' => f.getFieldPath(),
                'value' => mission.get(f.getFieldPath())
            });
        }

        return new Map<String, Object>{
            'fields' => fields,
            'missionName' => mission.Name,
            'typePrestataire' => typePrestataire,
            'prestataireName' => prestataire.Name,
            'prestataireSpecialite' => (
                accountFieldMap.containsKey('SpecialiteMedecin__c') ? prestataire.get('SpecialiteMedecin__c') :
                (accountFieldMap.containsKey('Specialite__c') ? prestataire.get('Specialite__c') : null)
            ),
            'missionBranche' => mission.Branche__c,
            'missionNature' => mission.Nature_Mission__c,
            'missionType' => mission.Type_de_mission__c
        };
    }

    private static String getFieldSetName(String typePrestataire) {
        switch on typePrestataire {
            when 'Clinique'  { return 'FS_Clinique'; }
            when 'Medecin'   { return 'FS_Medecin'; }
            when 'Avocat'    { return 'FS_Avocat'; }
            when 'Expert'    { return 'FS_Expert'; }
            when 'Opticien'  { return 'FS_Opticien'; }
            when else {
                throw new AuraHandledException(
                    'Type prestataire non reconnu : ' + typePrestataire
                );
            }
        }
    }

    private static Boolean isMedecinRecordTypeDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            return false;
        }
        String d = developerName.trim().toLowerCase();
        return d == 'medecin' || d.contains('medecin');
    }

    private static String getFieldSetNameMedecin(String branche, String natureMission) {
        if (String.isBlank(branche) || String.isBlank(natureMission)) {
            return 'FS_Medecin';
        }

        String b = normalizeKey(branche);
        String n = normalizeKey(natureMission);

        if (b == 'at') {
            if (n == 'controle medicale' || n == 'controle medical') return 'FS_Medecin_AT_controle';
            if (n == 'vacation') return 'FS_Medecin_AT_vacation';
            return 'FS_Medecin';
        }

        if (b == 'sante') {
            if (n == 'vacation sur site') return 'FS_Medecin_Sante_vacation_site';
            if (n == 'vacation sur siege') return 'FS_Medecin_Sante_vacation_siege';
            return 'FS_Medecin';
        }

        return 'FS_Medecin';
    }

    private static String normalizeKey(String s) {
        if (s == null) return '';
        String out = s.trim().toLowerCase();

        out = out.replace('é', 'e').replace('è', 'e').replace('ê', 'e').replace('ë', 'e');
        out = out.replace('à', 'a').replace('â', 'a');
        out = out.replace('î', 'i').replace('ï', 'i');
        out = out.replace('ô', 'o').replace('ö', 'o');
        out = out.replace('ù', 'u').replace('û', 'u').replace('ü', 'u');
        out = out.replace('ç', 'c');

        while (out.contains('  ')) out = out.replace('  ', ' ');
        return out;
    }

    private static Id parseMissionRecordId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim();
        if ((s.length() != 15 && s.length() != 18) || !Pattern.matches('^[a-zA-Z0-9]+$', s)) {
            return null;
        }
        return (Id) s;
    }
}
