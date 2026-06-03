/**
 * Identifiants messagerie gestionnaire : uniquement Mission__c.Numero_mission2__c.
 * L'extraction depuis la réponse API (sync) sert à remplir ce champ, pas à lire d'autres champs mission.
 */
public class MissionMessagingUtil {

    /**
     * numeroMission pour GET/POST /missions/{numeroMission}/messages.
     * Source unique : Numero_mission2__c (mission courante, puis mission parente si vide).
     */
    public static List<String> resolveMessagingIdsFromMission(Mission__c mission) {
        List<String> out = new List<String>();
        if (mission == null) {
            return out;
        }
        addNumeroMission2(mission, out);
        if (!out.isEmpty()) {
            return out;
        }
        Id parentId = mission.ParentId__c;
        if (parentId != null && hasNumeroMission2Field()) {
            List<Mission__c> parents = [
                SELECT Numero_mission2__c
                FROM Mission__c
                WHERE Id = :parentId
                LIMIT 1
            ];
            if (!parents.isEmpty()) {
                addNumeroMission2(parents[0], out);
            }
        }
        return out;
    }

    /** Premier numeroMission pour l'URL messagerie. */
    public static String primaryNumeroMission(Mission__c mission) {
        List<String> ids = resolveMessagingIdsFromMission(mission);
        return ids.isEmpty() ? null : ids[0];
    }

    /** numeroMission renvoyé par POST self-missionning (à stocker dans Numero_mission2__c). */
    public static String extractNumeroMission(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        String trimmed = body.trim();
        if (!trimmed.startsWith('{')) {
            return truncate(trimmed, 255);
        }
        try {
            Object root = JSON.deserializeUntyped(trimmed);
            if (root instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) root;
                if (m.containsKey('numeroMission') && m.get('numeroMission') != null) {
                    String nm = String.valueOf(m.get('numeroMission')).trim();
                    if (String.isNotBlank(nm)) {
                        return truncate(nm, 255);
                    }
                }
            }
        } catch (Exception e) {
            // ignore
        }
        String fromPattern = parseNumeroMissionPatternString(trimmed);
        return String.isNotBlank(fromPattern) ? truncate(fromPattern, 255) : null;
    }

    public static String extractStorableNumeroMission2(String body) {
        return truncate(extractNumeroMission(body), 20);
    }

    public static Boolean canUseMessaging(Mission__c mission) {
        if (mission == null) {
            return false;
        }
        if (String.isNotBlank(mission.Type_Prestataire__c)
            && mission.Type_Prestataire__c.equalsIgnoreCase('Avocat')) {
            return false;
        }
        if (!resolveMessagingIdsFromMission(mission).isEmpty()) {
            return true;
        }
        return MissionEchangeLocalService.isAvailable();
    }

    public static Boolean isRetryableMissionNotFound(HttpResponse res) {
        if (res == null) {
            return false;
        }
        Integer code = res.getStatusCode();
        if (code != 404 && code != 500) {
            return false;
        }
        String body = res.getBody();
        if (String.isBlank(body)) {
            return code == 404;
        }
        String lower = body.toLowerCase();
        if (lower.contains('mission not found') || lower.contains('mission introuvable')) {
            return true;
        }
        if (lower.contains('failed to convert') && lower.contains('missionid')) {
            return true;
        }
        return false;
    }

    public static String formatTriedIdsMessage(List<String> ids) {
        if (ids == null || ids.isEmpty()) {
            return 'aucun Numero_mission2__c';
        }
        return String.join(ids, ', ');
    }

    private static Boolean hasNumeroMission2Field() {
        return Schema.SObjectType.Mission__c.fields.getMap().containsKey('Numero_mission2__c');
    }

    private static void addNumeroMission2(Mission__c mission, List<String> out) {
        if (!hasNumeroMission2Field() || mission.get('Numero_mission2__c') == null) {
            return;
        }
        String nm = String.valueOf(mission.get('Numero_mission2__c')).trim();
        if (String.isNotBlank(nm)) {
            addUrlCandidate(nm, out);
        }
    }

    private static void addUrlCandidate(String value, List<String> out) {
        if (String.isBlank(value)) {
            return;
        }
        String v = value.trim();
        for (String existing : out) {
            if (existing.equals(v)) {
                return;
            }
        }
        out.add(v);
    }

    private static String parseNumeroMissionPatternString(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        Matcher m = Pattern.compile('"numeroMission"\\s*:\\s*"?([^",}]+)"?').matcher(raw);
        if (m.find()) {
            return m.group(1).trim();
        }
        return null;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return null;
        }
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }
}
