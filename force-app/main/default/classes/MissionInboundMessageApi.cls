/**
 * API REST entrante — le poste gestionnaire (mock) appelle cette URL pour créer un message.
 * Salesforce relaie vers POST /missions/{numeroMission}/messages (API EC2, Named Credential existante).
 *
 * URL : POST /services/apexrest/portail/v1/missions/{numeroMission}/messages
 */
@RestResource(urlMapping='/portail/v1/missions/*/messages')
global without sharing class MissionInboundMessageApi {

    @HttpPost
    global static void createMessage() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        String numeroMission = extractNumeroMission(req);
        if (String.isBlank(numeroMission)) {
            writeJson(res, 400, errorBody('numeroMission manquant dans l\'URL.'));
            return;
        }

        MissionInboundMessageService.InboundRequest inbound;
        try {
            inbound = parseBody(req.requestBody == null ? null : req.requestBody.toString());
        } catch (Exception e) {
            writeJson(res, 400, errorBody('JSON invalide : ' + e.getMessage()));
            return;
        }

        MissionInboundMessageService.InboundResult result = MissionInboundMessageService.forwardToGestionnaireApi(
            numeroMission,
            inbound
        );

        if (result.httpStatus == 201) {
            Map<String, Object> ok = new Map<String, Object>{
                'status' => 'ok',
                'numeroMission' => result.numeroMission,
                'deliveredToGestionnaire' => true
            };
            if (result.messageId != null) {
                ok.put('messageId', result.messageId);
            }
            if (result.message != null) {
                ok.put('content', result.message.content);
                ok.put('tag', result.message.tag);
                ok.put('sentAt', result.message.sentAt);
            }
            writeJson(res, 201, ok);
            return;
        }

        writeJson(res, result.httpStatus, errorBody(result.error));
    }

    private static MissionInboundMessageService.InboundRequest parseBody(String raw) {
        MissionInboundMessageService.InboundRequest inbound = new MissionInboundMessageService.InboundRequest();
        if (String.isBlank(raw)) {
            return inbound;
        }
        Object root = JSON.deserializeUntyped(raw);
        if (!(root instanceof Map<String, Object>)) {
            throw new IllegalArgumentException('Objet JSON attendu.');
        }
        Map<String, Object> m = (Map<String, Object>) root;
        inbound.content = stringVal(m.get('content'));
        inbound.tag = tagFromPayload(m.get('tag'));
        inbound.senderName = stringVal(m.get('senderName'));
        inbound.senderRole = stringVal(m.get('senderRole'));
        inbound.sentAt = stringVal(m.get('sentAt'));
        inbound.isRead = toBoolean(m.get('isRead'));
        if (inbound.isRead == null) {
            inbound.isRead = toBoolean(m.get('read'));
        }
        return inbound;
    }

    private static String tagFromPayload(Object tagObj) {
        if (tagObj == null) {
            return null;
        }
        if (tagObj instanceof Map<String, Object>) {
            Map<String, Object> tm = (Map<String, Object>) tagObj;
            if (tm.containsKey('code') && tm.get('code') != null) {
                return String.valueOf(tm.get('code')).trim();
            }
            if (tm.containsKey('label') && tm.get('label') != null) {
                return String.valueOf(tm.get('label')).trim();
            }
        }
        return String.valueOf(tagObj).trim();
    }

    private static String extractNumeroMission(RestRequest req) {
        if (req == null) {
            return null;
        }
        if (req.params != null && req.params.containsKey('numeroMission')) {
            return req.params.get('numeroMission');
        }
        String uri = req.requestURI;
        if (String.isBlank(uri)) {
            return null;
        }
        List<String> parts = uri.split('/');
        for (Integer i = 0; i < parts.size(); i++) {
            if ('missions'.equalsIgnoreCase(parts[i]) && i + 1 < parts.size()) {
                String candidate = parts[i + 1];
                if (String.isNotBlank(candidate) && !'messages'.equalsIgnoreCase(candidate)) {
                    return candidate;
                }
            }
        }
        return null;
    }

    private static Map<String, Object> errorBody(String message) {
        return new Map<String, Object>{
            'status' => 'error',
            'message' => message
        };
    }

    private static void writeJson(RestResponse res, Integer statusCode, Map<String, Object> body) {
        res.statusCode = statusCode;
        res.addHeader('Content-Type', 'application/json; charset=UTF-8');
        res.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static String stringVal(Object o) {
        return o == null ? null : String.valueOf(o);
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
}
