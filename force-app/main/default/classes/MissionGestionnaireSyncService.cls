/**
 * Synchronisation asynchrone des missions auto-missionnement médecin vers l'API « Poste gestionnaire ».
 * Routage et codes « nature » configurés dans Gestionnaire_API_Mapping__mdt ; id gestionnaire dans Gestionnaire_Sync__mdt.Default.
 * Corps JSON aligné sur la spec self-missionning (POST unique sur missions/self-missionning).
 */
public without sharing class MissionGestionnaireSyncService {
    public static final String NAMED_CREDENTIAL = 'callout:Gestionnaire_Auto_Missionnement';
    /** Un seul chemin côté API : /api/v1/missions/self-missionning */
    private static final String SELF_MISSIONNING_PATH = 'missions/self-missionning';

    private static List<Gestionnaire_API_Mapping__mdt> mappingCache;

    public static Boolean shouldEnqueue(Mission__c m) {
        if (m == null) {
            return false;
        }
        if (m.Type_de_mission__c != 'Auto-missionnement') {
            return false;
        }
        Gestionnaire_Sync__mdt cfg = Gestionnaire_Sync__mdt.getInstance('Default');
        if (cfg == null || !cfg.Actif__c) {
            return false;
        }
        return resolveMapping(m) != null;
    }

    public static void syncMission(Id missionId) {
        Gestionnaire_Sync__mdt cfg = Gestionnaire_Sync__mdt.getInstance('Default');
        if (cfg == null || !cfg.Actif__c) {
            return;
        }
        String gestionnaireId = cfg.Gestionnaire_Id__c;
        if (String.isBlank(gestionnaireId)) {
            updateApiStatus(missionId, null, 'Skipped', 'Gestionnaire_Id__c vide (CMDT Default).');
            return;
        }

        Mission__c m;
        try {
            m = [
                SELECT
                    Id,
                    Branche__c,
                    Nature_Mission__c,
                    Type_Prestataire__c,
                    Type_de_mission__c,
                    Heure_debut_passage__c,
                    Heure_fin_passage__c,
                    Nombre_dossiers__c,
                    Type_Sinistre__c,
                    Numero_police__c,
                    Date_survenance__c,
                    Date_nomination__c,
                    Date_convocation__c,
                    Reference_dossier_prestataire__c,
                    Nom_societe__c,
                    Personnes_impliquees__c
                FROM Mission__c
                WHERE Id = :missionId
                LIMIT 1
            ];
        } catch (Exception e) {
            return;
        }

        Gestionnaire_API_Mapping__mdt mapRow = resolveMapping(m);
        if (mapRow == null) {
            return;
        }

        String body;
        try {
            body = buildJsonBody(m, mapRow, gestionnaireId);
        } catch (Exception e) {
            updateApiStatus(missionId, null, 'PayloadError', truncate(e.getMessage(), 32768));
            return;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/' + SELF_MISSIONNING_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=UTF-8');
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            updateApiStatus(missionId, null, 'CalloutError', truncate(e.getMessage(), 32768));
            return;
        }

        Integer code = res.getStatusCode();
        if (code >= 200 && code < 300) {
            String ext = extractExternalId(res.getBody());
            updateApiStatus(missionId, ext, 'Synced', null);
        } else {
            String err = truncate(res.getStatus() + ' ' + res.getBody(), 32768);
            updateApiStatus(missionId, null, 'HTTP_' + code, err);
        }
    }

    private static Gestionnaire_API_Mapping__mdt resolveMapping(Mission__c m) {
        if (m == null || String.isBlank(m.Type_Prestataire__c) || String.isBlank(m.Branche__c) || String.isBlank(m.Nature_Mission__c)) {
            return null;
        }
        for (Gestionnaire_API_Mapping__mdt row : getMappings()) {
            if (!row.Actif__c) {
                continue;
            }
            if (equalsIc(row.Type_Prestataire__c, m.Type_Prestataire__c)
                && equalsIc(row.Branche__c, m.Branche__c)
                && equalsIc(row.Nature_De_Mission__c, m.Nature_Mission__c)) {
                return row;
            }
        }
        return null;
    }

    private static List<Gestionnaire_API_Mapping__mdt> getMappings() {
        if (mappingCache == null) {
            mappingCache = [
                SELECT
                    DeveloperName,
                    Actif__c,
                    Type_Prestataire__c,
                    Branche__c,
                    Nature_De_Mission__c,
                    Api_Nature__c,
                    Path_Branch_Slug__c,
                    Path_Role_Slug__c
                FROM Gestionnaire_API_Mapping__mdt
                WHERE Actif__c = TRUE
            ];
        }
        return mappingCache;
    }

    private static Boolean equalsIc(String a, String b) {
        if (a == null || b == null) {
            return false;
        }
        return a.equalsIgnoreCase(b);
    }

    private static String buildJsonBody(Mission__c m, Gestionnaire_API_Mapping__mdt mapRow, String gestionnaireId) {
        Map<String, Object> root = new Map<String, Object>();
        Object police = parsePoliceNumber(m.Numero_police__c);
        if (police != null) {
            root.put('policeNumber', police);
        }
        root.put('branch', mapBranchToApi(m.Branche__c));
        root.put('nature', mapRow.Api_Nature__c);
        root.put('missionType', deriveMissionType(mapRow.Api_Nature__c));
        root.put('occurrenceDate', formatDateIso(m.Date_survenance__c));
        root.put('nominationDate', formatDateIso(m.Date_nomination__c));
        root.put('appointmentDate', formatDateIso(m.Date_convocation__c));
        root.put('providerFileNumber', m.Reference_dossier_prestataire__c);
        root.put('companyName', m.Nom_societe__c);
        root.put('status', 'PENDING');
        root.put('persons', parsePersons(m.Personnes_impliquees__c));
        root.put('idSalesforce', String.valueOf(m.Id));
        if (String.isNotBlank(gestionnaireId)) {
            root.put('gestionnaireId', gestionnaireId);
        }
        return JSON.serialize(root);
    }

    private static String mapBranchToApi(String branche) {
        if (String.isBlank(branche)) {
            return null;
        }
        if (branche.equalsIgnoreCase('AT')) {
            return 'AT';
        }
        if (branche.equalsIgnoreCase('Santé') || branche.equalsIgnoreCase('Sante')) {
            return 'SANTE';
        }
        return branche;
    }

    private static String deriveMissionType(String apiNature) {
        if (String.isBlank(apiNature)) {
            return 'VACATION';
        }
        if ('AT_CONTROLE_MEDICAL'.equalsIgnoreCase(apiNature) || 'MEDICAL_CONTROL'.equalsIgnoreCase(apiNature)) {
            return 'CONTROLE_MEDICAL';
        }
        if ('VACATION_SIEGE'.equalsIgnoreCase(apiNature)) {
            return 'VACATION';
        }
        return 'VACATION';
    }

    private static Object parsePoliceNumber(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim().replace(',', '.');
        try {
            return Decimal.valueOf(s);
        } catch (Exception e) {
            String digits = s.replaceAll('[^0-9]', '');
            if (String.isBlank(digits)) {
                return null;
            }
            try {
                return Decimal.valueOf(digits);
            } catch (Exception e2) {
                return null;
            }
        }
    }

    private static String formatDateIso(Date d) {
        if (d == null) {
            return null;
        }
        Datetime dt = Datetime.newInstanceGmt(d.year(), d.month(), d.day());
        return dt.formatGmt('yyyy-MM-dd');
    }

    private static List<Object> parsePersons(String raw) {
        List<Object> out = new List<Object>();
        if (String.isBlank(raw)) {
            return out;
        }
        for (String line : raw.split('\n')) {
            if (String.isBlank(line)) {
                continue;
            }
            List<String> p = line.split('\\|', -1);
            if (p.size() < 4) {
                continue;
            }
            String typeFr = p[0];
            String civility = p.size() > 1 ? p[1] : null;
            String nom = p.size() > 2 ? p[2] : '';
            String prenom = p.size() > 3 ? p[3] : '';
            String birth = p.size() > 4 ? p[4] : null;
            Map<String, Object> person = new Map<String, Object>{
                'civility' => civility,
                'lastName' => nom,
                'firstName' => prenom,
                'birthDate' => birth,
                'type' => mapPersonType(typeFr)
            };
            out.add(person);
        }
        return out;
    }

    private static String mapPersonType(String typeFr) {
        if (String.isBlank(typeFr)) {
            return 'VICTIM';
        }
        if (typeFr.equalsIgnoreCase('Victime')) {
            return 'VICTIM';
        }
        if (typeFr.equalsIgnoreCase('Assuré') || typeFr.equalsIgnoreCase('Assure')) {
            return 'VICTIM';
        }
        if (typeFr.equalsIgnoreCase('Tiers')) {
            return 'THIRD_PARTY';
        }
        if (typeFr.equalsIgnoreCase('Témoin') || typeFr.equalsIgnoreCase('Temoin')) {
            return 'WITNESS';
        }
        return 'VICTIM';
    }

    private static String extractExternalId(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            Object root = JSON.deserializeUntyped(body);
            if (!(root instanceof Map<String, Object>)) {
                return truncate(body, 255);
            }
            Map<String, Object> m = (Map<String, Object>) root;
            for (String k : new List<String>{ 'id', 'missionId', 'mission_id', 'reference' }) {
                if (m.containsKey(k) && m.get(k) != null) {
                    return String.valueOf(m.get(k));
                }
            }
            Object data = m.get('data');
            if (data instanceof Map<String, Object>) {
                Map<String, Object> dm = (Map<String, Object>) data;
                if (dm.containsKey('id') && dm.get('id') != null) {
                    return String.valueOf(dm.get('id'));
                }
            }
        } catch (Exception e) {
            // ignore
        }
        return truncate(body, 255);
    }

    private static void updateApiStatus(Id missionId, String externalId, String statut, String erreur) {
        Mission__c upd = new Mission__c(
            Id = missionId,
            Statut_API__c = truncate(statut, 255),
            Id_Externe_API__c = truncate(externalId, 255),
            Erreur_API__c = erreur
        );
        try {
            update upd;
        } catch (Exception e) {
            // FLS / droits : ne pas relancer
        }
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return null;
        }
        if (maxLen == null || s.length() <= maxLen) {
            return s;
        }
        return s.substring(0, maxLen);
    }
}
