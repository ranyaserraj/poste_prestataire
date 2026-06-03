/**
 * Relais POST gestionnaire → API EC2 /missions/{numeroMission}/messages.
 * Utilisé par l'API REST entrante (mock poste gestionnaire sans UI).
 * Ne modifie pas le fil portail : le prestataire lit via MissionMessageController.getMessages (GET).
 */
public without sharing class MissionInboundMessageService {

    private static final String NAMED_CREDENTIAL = 'callout:Gestionnaire_Auto_Missionnement';

    public class InboundRequest {
        public String content;
        public String tag;
        public String senderName;
        public String senderRole;
        public String sentAt;
        public Boolean isRead;
    }

    public class InboundResult {
        public Integer httpStatus;
        public String status;
        public String numeroMission;
        public Integer messageId;
        public Boolean deliveredToGestionnaire;
        public String error;
        public MissionMessageController.MessageDto message;
    }

    /**
     * Crée un message côté API gestionnaire (callout POST) pour le numeroMission fourni.
     */
    public static InboundResult forwardToGestionnaireApi(String numeroMission, InboundRequest input) {
        InboundResult out = new InboundResult();
        out.numeroMission = normalizeNumero(numeroMission);
        out.httpStatus = 400;
        out.status = 'error';
        out.deliveredToGestionnaire = false;

        if (input == null) {
            out.error = 'Corps JSON requis.';
            return out;
        }

        String content = String.isBlank(input.content) ? null : input.content.trim();
        String tag = normalizeTag(input.tag);
        if (String.isBlank(content)) {
            out.error = 'content obligatoire.';
            return out;
        }
        if (String.isBlank(tag)) {
            out.error = 'tag obligatoire (QUESTION_TECHNIQUE, DEMANDE_PIECES, INFORMATION).';
            return out;
        }

        if (String.isBlank(out.numeroMission)) {
            out.error = 'numeroMission invalide.';
            return out;
        }

        Mission__c missionRow = findMissionByNumero(out.numeroMission);
        if (missionRow == null) {
            out.httpStatus = 404;
            out.error =
                'Aucune mission Salesforce pour numeroMission ' + out.numeroMission + '.';
            return out;
        }
        if (isAvocatMission(missionRow)) {
            out.httpStatus = 422;
            out.error = 'Messagerie indisponible pour le profil Avocat.';
            return out;
        }

        String senderName = String.isBlank(input.senderName)
            ? 'Gestionnaire'
            : input.senderName.trim();
        String senderRole = String.isBlank(input.senderRole)
            ? 'GESTIONNAIRE'
            : input.senderRole.trim();

        Map<String, Object> body = buildPostBody(
            out.numeroMission,
            content,
            tag,
            senderName,
            senderRole,
            input.sentAt,
            input.isRead
        );

        HttpResponse res;
        try {
            res = sendPost(out.numeroMission, body);
        } catch (Exception e) {
            out.httpStatus = 502;
            out.error = e.getMessage();
            return out;
        }

        if (res == null) {
            out.httpStatus = 502;
            out.error = 'API gestionnaire : aucune réponse.';
            return out;
        }

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            out.httpStatus = 502;
            out.error = httpError(res);
            return out;
        }

        MissionMessageController.MessageDto dto = parsePostResponse(res.getBody(), content);
        if (dto == null) {
            dto = verifyViaGet(out.numeroMission, content);
        }

        out.httpStatus = 201;
        out.status = 'ok';
        out.deliveredToGestionnaire = true;
        out.message = dto;
        if (dto != null && dto.id != null) {
            out.messageId = dto.id;
        }

        if (MissionEchangeLocalService.isAvailable()) {
            try {
                MissionMessageController.MessageDto stored =
                    MissionEchangeLocalService.createInboundSynced(
                        missionRow.Id,
                        content,
                        tag,
                        senderName,
                        out.messageId,
                        input.sentAt
                    );
                if (stored != null) {
                    out.message = stored;
                }
            } catch (Exception storeEx) {
                out.error =
                    (String.isNotBlank(out.error) ? out.error + ' | ' : '') +
                    'Echange__c : ' +
                    storeEx.getMessage();
            }
        }

        return out;
    }

    private static String normalizeNumero(String raw) {
        return String.isBlank(raw) ? null : raw.trim();
    }

    private static String normalizeTag(Object tagObj) {
        if (tagObj == null) {
            return null;
        }
        if (tagObj instanceof Map<String, Object>) {
            Map<String, Object> tm = (Map<String, Object>) tagObj;
            if (tm.containsKey('code') && tm.get('code') != null) {
                return String.valueOf(tm.get('code')).trim();
            }
        }
        String s = String.valueOf(tagObj).trim();
        return String.isBlank(s) ? null : s;
    }

    private static Mission__c findMissionByNumero(String numeroMission) {
        List<Mission__c> rows = [
            SELECT Id, Type_Prestataire__c, Numero_mission2__c
            FROM Mission__c
            WHERE Numero_mission2__c = :numeroMission
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Boolean isAvocatMission(Mission__c m) {
        if (m == null || String.isBlank(m.Type_Prestataire__c)) {
            return false;
        }
        return m.Type_Prestataire__c.equalsIgnoreCase('Avocat');
    }

    private static Map<String, Object> buildPostBody(
        String numeroMission,
        String content,
        String tag,
        String senderName,
        String senderRole,
        String sentAt,
        Boolean isRead
    ) {
        Boolean readFlag = isRead == true;
        String sent = String.isNotBlank(sentAt)
            ? sentAt.trim()
            : Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
        return new Map<String, Object>{
            'id' => 0,
            'phaseId' => 0,
            'missionId' => numeroMission,
            'content' => content,
            'tag' => tag,
            'sentAt' => sent,
            'isRead' => readFlag,
            'read' => readFlag,
            'senderName' => senderName,
            'senderRole' => senderRole,
            'attachments' => new List<Object>(),
            'attachmentIds' => new List<Object>()
        };
    }

    private static HttpResponse sendPost(String numeroMission, Map<String, Object> body) {
        String path =
            'missions/' +
            EncodingUtil.urlEncode(numeroMission, 'UTF-8') +
            '/messages';
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/' + path);
        req.setMethod('POST');
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json; charset=UTF-8');
        req.setHeader('Accept', 'application/json');
        applyOutboundAuth(req);
        req.setBody(JSON.serialize(body));
        return new Http().send(req);
    }

    private static void applyOutboundAuth(HttpRequest req) {
        try {
            GED_Config__mdt cfg = GED_Config__mdt.getInstance('Default');
            if (cfg != null && String.isNotBlank(cfg.Auth_Token__c)) {
                req.setHeader('Authorization', 'Bearer ' + cfg.Auth_Token__c);
            }
        } catch (Exception e) {
            // Named Credential sans auth explicite
        }
    }

    private static MissionMessageController.MessageDto verifyViaGet(
        String numeroMission,
        String contentTrimmed
    ) {
        String path =
            'missions/' +
            EncodingUtil.urlEncode(numeroMission, 'UTF-8') +
            '/messages';
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/' + path);
        req.setMethod('GET');
        req.setTimeout(120000);
        req.setHeader('Accept', 'application/json');
        applyOutboundAuth(req);
        HttpResponse getRes = new Http().send(req);
        if (getRes.getStatusCode() < 200 || getRes.getStatusCode() >= 300) {
            return null;
        }
        String target = contentTrimmed.trim();
        for (MissionMessageController.MessageDto m : mapMessages(getRes.getBody())) {
            if (m != null && String.isNotBlank(m.content)
                && m.content.trim().equalsIgnoreCase(target)) {
                return m;
            }
        }
        return null;
    }

    private static MissionMessageController.MessageDto parsePostResponse(
        String body,
        String contentTrimmed
    ) {
        if (String.isBlank(body)) {
            return null;
        }
        List<MissionMessageController.MessageDto> parsed = mapMessages(body);
        if (parsed.isEmpty()) {
            parsed = mapMessages('[' + body + ']');
        }
        if (parsed.isEmpty()) {
            return null;
        }
        MissionMessageController.MessageDto dto = parsed[0];
        if (String.isBlank(dto.content)) {
            dto.content = contentTrimmed;
        }
        if (dto.id != null || String.isNotBlank(dto.content)) {
            dto.deliveredToGestionnaire = true;
            dto.isMine = false;
            return dto;
        }
        return null;
    }

    private static List<MissionMessageController.MessageDto> mapMessages(String jsonBody) {
        List<MissionMessageController.MessageDto> out = new List<MissionMessageController.MessageDto>();
        if (String.isBlank(jsonBody)) {
            return out;
        }
        Object root = JSON.deserializeUntyped(jsonBody);
        List<Object> items = new List<Object>();
        if (root instanceof List<Object>) {
            items = (List<Object>) root;
        } else if (root instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) root;
            if (m.containsKey('content') || m.containsKey('id')) {
                items.add(root);
            }
        }
        for (Object o : items) {
            if (o instanceof Map<String, Object>) {
                out.add(mapOne((Map<String, Object>) o));
            }
        }
        return out;
    }

    private static MissionMessageController.MessageDto mapOne(Map<String, Object> m) {
        MissionMessageController.MessageDto dto = new MissionMessageController.MessageDto();
        dto.id = toInteger(m.get('id'));
        dto.content = stringVal(m.get('content'));
        dto.senderName = stringVal(m.get('senderName'));
        dto.senderRole = stringVal(m.get('senderRole'));
        dto.sentAt = stringVal(m.get('sentAt'));
        Object tagObj = m.get('tag');
        if (tagObj instanceof Map<String, Object>) {
            Map<String, Object> tm = (Map<String, Object>) tagObj;
            dto.tag = tm.containsKey('code') ? stringVal(tm.get('code')) : stringVal(tagObj);
        } else {
            dto.tag = stringVal(tagObj);
        }
        dto.isRead = toBoolean(m.get('isRead'));
        if (dto.isRead == null) {
            dto.isRead = toBoolean(m.get('read'));
        }
        dto.isMine = false;
        dto.deliveredToGestionnaire = true;
        return dto;
    }

    private static Integer toInteger(Object o) {
        if (o == null) {
            return null;
        }
        if (o instanceof Integer) {
            return (Integer) o;
        }
        if (o instanceof Long) {
            return ((Long) o).intValue();
        }
        if (o instanceof Decimal) {
            return ((Decimal) o).intValue();
        }
        try {
            return Integer.valueOf(String.valueOf(o));
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean toBoolean(Object o) {
        if (o == null) {
            return null;
        }
        if (o instanceof Boolean) {
            return (Boolean) o;
        }
        return Boolean.valueOf(String.valueOf(o));
    }

    private static String stringVal(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    private static String httpError(HttpResponse res) {
        String msg = res.getStatus();
        if (String.isNotBlank(res.getBody())) {
            msg += ' — ' + res.getBody().left(500);
        }
        return 'API gestionnaire (' + res.getStatusCode() + ') : ' + msg;
    }
}
