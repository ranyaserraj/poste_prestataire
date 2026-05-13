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
            ? getFieldSetNameMedecin(
                mergeNormForFieldSetMatch('Branche__c', ctx.Branche__c),
                mergeNormForFieldSetMatch('Nature_Mission__c', ctx.Nature_Mission__c)
            )
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
            String path = f.getFieldPath();
            Schema.DescribeFieldResult fd = f.getSObjectField().getDescribe();
            Object raw = mission.get(path);
            fields.add(new Map<String, Object>{
                'label' => f.getLabel(),
                'apiName' => path,
                'value' => formatMissionFieldValue(fd, raw)
            });
        }

        String brancheLabel = picklistLabelOrValue('Branche__c', mission.Branche__c);
        String natureLabel = picklistLabelOrValue('Nature_Mission__c', mission.Nature_Mission__c);

        return new Map<String, Object>{
            'fields' => fields,
            'fieldSetUsed' => fieldSetName,
            'missionName' => mission.Name,
            'typePrestataire' => typePrestataire,
            'prestataireName' => prestataire.Name,
            'prestataireSpecialite' => (
                accountFieldMap.containsKey('SpecialiteMedecin__c') ? prestataire.get('SpecialiteMedecin__c') :
                (accountFieldMap.containsKey('Specialite__c') ? prestataire.get('Specialite__c') : null)
            ),
            'missionBranche' => brancheLabel,
            'missionNature' => natureLabel,
            'missionType' => picklistLabelOrValue('Type_de_mission__c', mission.Type_de_mission__c)
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

    /**
     * Field sets médecin selon branche + nature.
     * @param bNorm Chaîne normalisée (valeur API + libellé picklist), ex. « at vacation … »
     * @param nNorm Idem pour la nature
     */
    private static String getFieldSetNameMedecin(String bNorm, String nNorm) {
        if (String.isBlank(bNorm) || String.isBlank(nNorm)) {
            return 'FS_Medecin';
        }

        if (isBrancheAT(bNorm)) {
            if (isNatureControleMedicale(nNorm)) {
                return 'FS_Medecin_AT_controle';
            }
            if (isNatureATVacation(nNorm)) {
                return 'FS_Medecin_AT_vacation';
            }
            return 'FS_Medecin';
        }

        if (isBrancheSante(bNorm)) {
            if (nNorm.contains('vacation') && nNorm.contains('site')) {
                return 'FS_Medecin_Sante_vacation_site';
            }
            if (nNorm.contains('vacation') && nNorm.contains('siege')) {
                return 'FS_Medecin_Sante_vacation_siege';
            }
            // Abréviation courante « VSG » = vacation siège (si le libellé describe ne matche pas)
            if (nNorm.contains('vsg') && !nNorm.contains('site')) {
                return 'FS_Medecin_Sante_vacation_siege';
            }
            return 'FS_Medecin';
        }

        return 'FS_Medecin';
    }

    /**
     * Valeur stockée + libellé picklist (describe) pour matcher les field sets sur le sens métier,
     * même si la valeur API est courte (ex. VSG).
     */
    private static String mergeNormForFieldSetMatch(String fieldApiName, String storedValue) {
        if (String.isBlank(storedValue)) {
            return '';
        }
        String v = normalizeKey(storedValue);
        String lbl = normalizeKey(getPicklistLabelForMissionField(fieldApiName, storedValue));
        if (String.isBlank(lbl) || lbl == v) {
            return v;
        }
        return v + ' ' + lbl;
    }

    private static String getPicklistLabelForMissionField(String fieldApiName, String storedValue) {
        if (String.isBlank(storedValue)) {
            return '';
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Mission__c.fields.getMap();
        if (!fm.containsKey(fieldApiName)) {
            return '';
        }
        Schema.DescribeFieldResult dfr = fm.get(fieldApiName).getDescribe();
        if (dfr.getType() != Schema.DisplayType.PICKLIST && dfr.getType() != Schema.DisplayType.MULTIPICKLIST) {
            return '';
        }
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive() && String.valueOf(pe.getValue()).equals(String.valueOf(storedValue))) {
                return pe.getLabel();
            }
        }
        return '';
    }

    /** Libellé picklist pour l’UI ; si inconnu ou champ non-picklist, retourne la valeur stockée. */
    private static String picklistLabelOrValue(String fieldApiName, String storedValue) {
        if (String.isBlank(storedValue)) {
            return '';
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Mission__c.fields.getMap();
        if (!fm.containsKey(fieldApiName)) {
            return storedValue;
        }
        Schema.DescribeFieldResult dfr = fm.get(fieldApiName).getDescribe();
        if (dfr.getType() != Schema.DisplayType.PICKLIST && dfr.getType() != Schema.DisplayType.MULTIPICKLIST) {
            return storedValue;
        }
        String lbl = getPicklistLabelForMissionField(fieldApiName, storedValue);
        return String.isNotBlank(lbl) ? lbl : storedValue;
    }

    private static String formatMissionFieldValue(Schema.DescribeFieldResult fd, Object raw) {
        if (raw == null) {
            return null;
        }
        Schema.DisplayType dt = fd.getType();
        if (dt == Schema.DisplayType.TIME) {
            return formatTimeDisplayUniversal(raw);
        }
        if (dt == Schema.DisplayType.DATE) {
            Date d = (Date) raw;
            return d != null ? String.valueOf(d) : null;
        }
        if (dt == Schema.DisplayType.DATETIME) {
            Datetime dtt = (Datetime) raw;
            return dtt != null ? dtt.format() : null;
        }
        if (dt == Schema.DisplayType.PICKLIST) {
            return picklistLabelOrValue(fd.getName(), String.valueOf(raw));
        }
        if (dt == Schema.DisplayType.MULTIPICKLIST) {
            return formatMultipicklistLabels(fd, String.valueOf(raw));
        }
        if (dt == Schema.DisplayType.BOOLEAN) {
            return ((Boolean) raw) ? 'Oui' : 'Non';
        }
        if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.INTEGER || dt == Schema.DisplayType.LONG) {
            String api = fd.getName().toLowerCase();
            if (api.contains('heure') && (api.contains('passage') || api.contains('debut') || api.contains('fin'))) {
                return formatTimeDisplayUniversal(raw);
            }
        }
        return String.valueOf(raw);
    }

    private static String formatMultipicklistLabels(Schema.DescribeFieldResult fd, String stored) {
        if (String.isBlank(stored)) {
            return '';
        }
        List<String> parts = stored.split(';');
        List<String> out = new List<String>();
        for (String p : parts) {
            if (String.isBlank(p)) {
                continue;
            }
            out.add(picklistLabelOrValue(fd.getName(), p.trim()));
        }
        return String.join(out, ' ; ');
    }

    private static String formatTimeDisplayUniversal(Object raw) {
        if (raw instanceof Time) {
            return formatTimeHms((Time) raw);
        }
        if (raw instanceof Decimal) {
            return formatMsSinceMidnightToHhMmSs((Decimal) raw);
        }
        if (raw instanceof Integer) {
            return formatMsSinceMidnightToHhMmSs(Decimal.valueOf((Integer) raw));
        }
        if (raw instanceof Long) {
            return formatMsSinceMidnightToHhMmSs(Decimal.valueOf((Long) raw));
        }
        return String.valueOf(raw);
    }

    private static String formatTimeHms(Time t) {
        if (t == null) {
            return null;
        }
        return twoPad(t.hour()) + ':' + twoPad(t.minute()) + ':' + twoPad(t.second());
    }

    private static String formatMsSinceMidnightToHhMmSs(Decimal msIn) {
        if (msIn == null) {
            return null;
        }
        Long ms = msIn.longValue();
        Long day = 86400000L;
        ms = Math.mod(ms, day);
        if (ms < 0) {
            ms += day;
        }
        Integer totalSec = (Integer)(ms / 1000);
        Integer h = totalSec / 3600;
        Integer m = Math.mod(totalSec, 3600) / 60;
        Integer s = Math.mod(totalSec, 60);
        return twoPad(h) + ':' + twoPad(m) + ':' + twoPad(s);
    }

    private static String twoPad(Integer n) {
        String s = String.valueOf(n);
        return s.length() == 1 ? '0' + s : s;
    }

    private static Boolean isBrancheAT(String bNorm) {
        if (String.isBlank(bNorm)) {
            return false;
        }
        if (bNorm == 'at') {
            return true;
        }
        if (bNorm.contains('accident') && bNorm.contains('travail')) {
            return true;
        }
        return false;
    }

    private static Boolean isBrancheSante(String bNorm) {
        if (String.isBlank(bNorm)) {
            return false;
        }
        return bNorm == 'sante' || bNorm.contains('sante');
    }

    /** Contrôle médicale (libellé ou proche), sans s’appuyer sur des codes API figés. */
    private static Boolean isNatureControleMedicale(String n) {
        if (String.isBlank(n)) {
            return false;
        }
        Boolean hasControle = n.contains('controle') || n.contains('control');
        if (!hasControle) {
            return false;
        }
        return n.contains('medic') || n.contains('medical') || n.contains('medicale');
    }

    /**
     * Vacation côté AT : exclut « vacation sur site / siège » (rattachées à la branche Santé dans les field sets).
     */
    private static Boolean isNatureATVacation(String n) {
        if (String.isBlank(n) || !n.contains('vacation')) {
            return false;
        }
        if (n.contains(' sur ')) {
            return false;
        }
        return true;
    }

    private static String normalizeKey(String s) {
        if (s == null) {
            return '';
        }
        String out = s.trim().toLowerCase();

        out = out.replace('é', 'e').replace('è', 'e').replace('ê', 'e').replace('ë', 'e');
        out = out.replace('à', 'a').replace('â', 'a');
        out = out.replace('î', 'i').replace('ï', 'i');
        out = out.replace('ô', 'o').replace('ö', 'o');
        out = out.replace('ù', 'u').replace('û', 'u').replace('ü', 'u');
        out = out.replace('ç', 'c');

        out = out.replace('_', ' ').replace('-', ' ');
        while (out.contains('  ')) {
            out = out.replace('  ', ' ');
        }
        return out.trim();
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
