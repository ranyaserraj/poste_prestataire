/**
 * Messagerie mission — API gestionnaire (hors Avocat).
 * GET/POST /missions/{numeroMission}/messages — PUT /missions/messages/{msgId}
 */
public without sharing class MissionMessageController {

    private static final String NAMED_CREDENTIAL = 'callout:Gestionnaire_Auto_Missionnement';

    public class MessageDto {
        @AuraEnabled public Integer id;
        /** Id Salesforce Echange__c (messagerie locale). */
        @AuraEnabled public String sfExchangeId;
        @AuraEnabled public String content;
        @AuraEnabled public String senderName;
        @AuraEnabled public String senderRole;
        @AuraEnabled public String sentAt;
        @AuraEnabled public String tag;
        @AuraEnabled public Boolean isRead;
        @AuraEnabled public Boolean isMine;
        /** true = présent côté API gestionnaire ; false = copie locale Salesforce uniquement. */
        @AuraEnabled public Boolean deliveredToGestionnaire;
        @AuraEnabled public String deliveryStatus;
        @AuraEnabled public String deliveryError;
    }

    public class MessagingGateDto {
        @AuraEnabled public Boolean messagingEnabled;
        @AuraEnabled public String disabledMessage;
        @AuraEnabled public String typePrestataire;
        @AuraEnabled public String numeroMissionGestionnaire;
    }

    private class MissionCtx {
        Id salesforceId;
        List<String> apiMissionIds;
        String resolvedApiMissionId;
        String typePrestataire;
    }

    private static final Integer MAX_REPLAY_PER_REQUEST = 20;

    /**
     * Éligibilité messagerie pour le portail (sans callout).
     * Même règles que MissionMedecinController / detailMissionMedecin.
     */
    @AuraEnabled(cacheable=true)
    public static MessagingGateDto getMessagingGate(String missionId) {
        MessagingGateDto gate = new MessagingGateDto();
        gate.messagingEnabled = false;
        gate.disabledMessage = 'Messagerie indisponible pour cette mission.';

        Id mid = parseSalesforceId(missionId);
        if (mid == null) {
            gate.disabledMessage = 'Identifiant mission invalide.';
            return gate;
        }

        Id accountId = currentAccountId();
        if (accountId == null) {
            gate.disabledMessage = 'Utilisateur sans compte prestataire associé.';
            return gate;
        }

        List<Mission__c> rows = [
            SELECT
                Id,
                Prestataire__c,
                Type_Prestataire__c,
                Numero_mission2__c,
                ParentId__c,
                Id_Externe_API__c
            FROM Mission__c
            WHERE Id = :mid AND Prestataire__c = :accountId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            gate.disabledMessage = 'Mission introuvable ou accès refusé.';
            return gate;
        }

        Mission__c m = rows[0];
        gate.typePrestataire = m.Type_Prestataire__c;
        gate.numeroMissionGestionnaire = MissionMessagingUtil.primaryNumeroMission(m);

        if (isAvocatMission(m)) {
            gate.disabledMessage =
                'La messagerie par mission n\'est pas disponible pour le profil Avocat.';
            return gate;
        }

        gate.messagingEnabled = MissionMessagingUtil.canUseMessaging(m);
        if (gate.messagingEnabled) {
            gate.disabledMessage = null;
            return gate;
        }

        if (String.isNotBlank(gate.numeroMissionGestionnaire)) {
            gate.disabledMessage = 'Messagerie indisponible pour cette mission.';
        } else {
            gate.disabledMessage =
                'Mission non synchronisée avec le gestionnaire : enregistrez un numeroMission (sync API) pour activer la messagerie.';
        }
        return gate;
    }

    @AuraEnabled(cacheable=false)
    public static List<MessageDto> getMessages(String missionId) {
        MissionCtx ctx = resolveContext(missionId);
        if (!MissionEchangeLocalService.isAvailable()) {
            throw new AuraHandledException('Historique messagerie indisponible (objet Echange__c).');
        }

        // Historique local d'abord (visible même si l'API gestionnaire est indisponible).
        List<MessageDto> local = loadLocalMessages(ctx.salesforceId);
        if (ctx.apiMissionIds == null || ctx.apiMissionIds.isEmpty()) {
            return local;
        }

        try {
            List<MessageDto> apiSnapshot = fetchApiMessagesSnapshot(ctx);
            syncInboundFromApi(ctx, apiSnapshot);
            scheduleReplayIfPending(ctx.salesforceId);
            List<MessageDto> refreshed = loadLocalMessages(ctx.salesforceId);
            return appendApiOnlyMessages(refreshed, apiSnapshot);
        } catch (Exception e) {
            return loadLocalMessages(ctx.salesforceId);
        }
    }

    private static List<MessageDto> loadLocalMessages(Id missionSfId) {
        try {
            return MissionEchangeLocalService.getMessages(missionSfId);
        } catch (MissionEchangeException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Resync outbound en arrière-plan (pas de POST dans getMessages — évite erreurs 400 / callout). */
    private static void scheduleReplayIfPending(Id missionSfId) {
        if (missionSfId == null || !MissionEchangeLocalService.isAvailable()) {
            return;
        }
        if (!MissionEchangeLocalService.listOutboundPending(missionSfId).isEmpty()) {
            MissionMessageReplayQueueable.enqueueForMission(missionSfId);
        }
    }

    /**
     * Archive les messages GESTIONNAIRE de l'API dans Echange__c (callouts puis DML).
     */
    private static void syncInboundFromApi(MissionCtx ctx, List<MessageDto> apiMessages) {
        if (ctx == null || ctx.salesforceId == null || apiMessages == null) {
            return;
        }
        for (MessageDto api : apiMessages) {
            if (api == null || !isGestionnaireApiMessage(api) || String.isBlank(api.content)) {
                continue;
            }
            try {
                MissionEchangeLocalService.createInboundSynced(
                    ctx.salesforceId,
                    api.content.trim(),
                    api.tag,
                    api.senderName,
                    api.id,
                    api.sentAt
                );
            } catch (Exception e) {
                // non bloquant
            }
        }
    }

    /** Messages API absents de Echange__c (ex. échec d'archivage) — affichage temporaire. */
    private static List<MessageDto> appendApiOnlyMessages(
        List<MessageDto> local,
        List<MessageDto> apiMessages
    ) {
        List<MessageDto> merged = new List<MessageDto>();
        if (local != null) {
            merged.addAll(local);
        }
        if (apiMessages == null) {
            return sortMessagesBySentAt(merged);
        }
        for (MessageDto api : apiMessages) {
            if (api == null || !isGestionnaireApiMessage(api)) {
                continue;
            }
            prepareGestionnaireDisplayDto(api);
            merged.add(api);
        }
        return sortMessagesBySentAt(merged);
    }

    private static void prepareGestionnaireDisplayDto(MessageDto api) {
        if (api == null) {
            return;
        }
        api.isMine = false;
        api.senderRole = String.isNotBlank(api.senderRole) ? api.senderRole : 'GESTIONNAIRE';
        if (String.isBlank(api.senderName)) {
            api.senderName = 'Gestionnaire';
        }
        api.deliveredToGestionnaire = true;
        api.deliveryStatus = MissionEchangeLocalService.SYNC_SYNCED;
        api.deliveryError = null;
    }

    /** Message entrant poste gestionnaire (API GET) — tout sauf rôle prestataire explicite. */
    private static Boolean isGestionnaireApiMessage(MessageDto api) {
        if (api == null) {
            return false;
        }
        if (isPrestataireMessage(api.senderRole)) {
            return false;
        }
        if (String.isNotBlank(api.senderRole)) {
            return true;
        }
        String name = api.senderName != null ? api.senderName.toLowerCase() : '';
        if (name.contains('gestion') || name.contains(' gs') || name.startsWith('gs')) {
            return true;
        }
        return true;
    }

    private static List<MessageDto> sortMessagesBySentAt(List<MessageDto> items) {
        List<MessageDto> sorted = new List<MessageDto>();
        if (items == null || items.isEmpty()) {
            return sorted;
        }
        List<MessageSortable> wrappers = new List<MessageSortable>();
        for (MessageDto dto : items) {
            if (dto != null) {
                wrappers.add(new MessageSortable(dto));
            }
        }
        wrappers.sort();
        for (MessageSortable w : wrappers) {
            sorted.add(w.dto);
        }
        return sorted;
    }

    private class MessageSortable implements Comparable {
        MessageDto dto;
        String sortKey;

        MessageSortable(MessageDto dto) {
            this.dto = dto;
            this.sortKey = String.isNotBlank(dto.sentAt) ? dto.sentAt : '';
        }

        public Integer compareTo(Object other) {
            MessageSortable o = (MessageSortable) other;
            if (String.isBlank(sortKey) && String.isBlank(o.sortKey)) {
                return compareTieBreaker(dto, o.dto);
            }
            if (String.isBlank(sortKey)) {
                return -1;
            }
            if (String.isBlank(o.sortKey)) {
                return 1;
            }
            Integer cmp = sortKey.compareTo(o.sortKey);
            return cmp != 0 ? cmp : compareTieBreaker(dto, o.dto);
        }
    }

    private static Integer compareTieBreaker(MessageDto a, MessageDto b) {
        String keyA = String.isNotBlank(a.sfExchangeId)
            ? a.sfExchangeId
            : String.valueOf(a.id);
        String keyB = String.isNotBlank(b.sfExchangeId)
            ? b.sfExchangeId
            : String.valueOf(b.id);
        if (keyA == keyB) {
            return 0;
        }
        if (String.isBlank(keyA)) {
            return -1;
        }
        if (String.isBlank(keyB)) {
            return 1;
        }
        return keyA.compareTo(keyB);
    }

    private static Boolean containsStrictEquivalent(List<MessageDto> items, MessageDto candidate) {
        if (candidate == null || items == null) {
            return false;
        }
        for (MessageDto existing : items) {
            if (String.isNotBlank(candidate.sfExchangeId)
                && candidate.sfExchangeId == existing.sfExchangeId) {
                return true;
            }
            if (candidate.id != null
                && candidate.id == existing.id
                && candidate.isMine == existing.isMine) {
                return true;
            }
            if (sameMessageContent(existing, candidate)
                && candidate.isMine == existing.isMine
                && sameSentAt(existing.sentAt, candidate.sentAt)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean sameSentAt(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) {
            return false;
        }
        return a.trim().equalsIgnoreCase(b.trim());
    }

    @AuraEnabled
    public static MessageDto sendMessage(String missionId, String content, String tag) {
        if (String.isBlank(content) || String.isBlank(tag)) {
            throw new AuraHandledException('Contenu et tag obligatoires.');
        }
        String tagNorm = tag.trim();
        String contentTrimmed = content.trim();
        MissionCtx ctx = resolveContext(missionId);

        MessageDto pending;
        try {
            pending = MissionEchangeLocalService.createOutboundPending(
                ctx.salesforceId,
                contentTrimmed,
                tagNorm
            );
        } catch (MissionEchangeException e) {
            throw new AuraHandledException(e.getMessage());
        }

        if (ctx.apiMissionIds == null || ctx.apiMissionIds.isEmpty()) {
            return pending;
        }

        // Callout interdit après INSERT dans la même transaction → sync asynchrone.
        MissionMessageReplayQueueable.enqueueForMission(ctx.salesforceId);
        Id echangeId = parseEchangeId(pending.sfExchangeId);
        MessageDto refreshed = refreshExchangeDto(echangeId, pending);
        return refreshed != null ? refreshed : pending;
    }

    /**
     * Sync immédiate OUTBOUND (nouvelle transaction, callouts autorisés).
     * Appelé par le LWC juste après sendMessage pour éviter un refresh manuel.
     */
    @AuraEnabled
    public static MessageDto syncPendingOutbound(String missionId, String echangeRecordId) {
        MissionCtx ctx = resolveContext(missionId);
        Id echangeId = parseEchangeId(echangeRecordId);
        MessageDto fallback = echangeId != null
            ? MissionEchangeLocalService.getById(echangeId)
            : null;

        if (ctx.apiMissionIds == null || ctx.apiMissionIds.isEmpty()) {
            return fallback;
        }

        try {
            replayPendingForMission(ctx.salesforceId);
        } catch (Exception e) {
            if (echangeId != null) {
                recordPendingSyncFailure(
                    echangeId,
                    e instanceof AuraHandledException ? e.getMessage() : e.getMessage()
                );
            }
        }

        MessageDto refreshed = refreshExchangeDto(echangeId, fallback);
        return refreshed != null ? refreshed : fallback;
    }

    private static MessageDto markExchangeSyncedFromApi(
        Id echangeId,
        MessageDto apiDto,
        String tagNorm,
        MessageDto fallback
    ) {
        MessageDto synced = MissionEchangeLocalService.markSynced(echangeId, apiDto != null ? apiDto.id : null);
        MessageDto out = synced != null ? synced : fallback;
        if (apiDto != null) {
            if (apiDto.id != null) {
                out.id = apiDto.id;
            }
            if (String.isNotBlank(apiDto.sentAt)) {
                out.sentAt = apiDto.sentAt;
            }
            if (String.isNotBlank(apiDto.senderName)) {
                out.senderName = apiDto.senderName;
            }
        }
        out.tag = tagNorm;
        out.deliveredToGestionnaire = true;
        out.deliveryStatus = MissionEchangeLocalService.SYNC_SYNCED;
        out.deliveryError = null;
        return out;
    }

    private static void recordPendingSyncFailure(Id echangeId, String errorMessage) {
        if (echangeId != null) {
            MissionEchangeLocalService.recordSyncAttemptFailure(echangeId, errorMessage);
        }
    }

    private static MessageDto refreshExchangeDto(Id echangeId, MessageDto fallback) {
        MessageDto refreshed = echangeId != null ? MissionEchangeLocalService.getById(echangeId) : null;
        return refreshed != null ? refreshed : fallback;
    }

    private static Id parseEchangeId(String sfExchangeId) {
        if (String.isBlank(sfExchangeId)) {
            return null;
        }
        try {
            return (Id) sfExchangeId;
        } catch (Exception e) {
            return null;
        }
    }

    private static MessageDto parsePostMessageResponse(String body, String contentTrimmed) {
        if (String.isBlank(body)) {
            return null;
        }
        List<MessageDto> parsed = mapMessages(body);
        if (parsed.isEmpty()) {
            parsed = mapMessages('[' + body + ']');
        }
        if (parsed.isEmpty()) {
            return null;
        }
        MessageDto dto = parsed[0];
        if (String.isBlank(dto.content)) {
            dto.content = contentTrimmed;
        }
        if (dto.id != null || String.isNotBlank(dto.content)) {
            return dto;
        }
        return null;
    }

    private static MessageDto findMessageOnGestionnaire(MissionCtx ctx, String contentTrimmed) {
        if (ctx == null || String.isBlank(contentTrimmed)) {
            return null;
        }
        HttpResponse getRes;
        try {
            getRes = tryMissionMessagesRequest('GET', ctx, null);
        } catch (AuraHandledException e) {
            return null;
        }
        if (getRes == null || getRes.getStatusCode() < 200 || getRes.getStatusCode() >= 300) {
            return null;
        }
        String target = contentTrimmed.trim();
        for (MessageDto m : mapMessages(getRes.getBody())) {
            if (m == null || String.isBlank(m.content)) {
                continue;
            }
            if (m.content.trim().equalsIgnoreCase(target)) {
                return m;
            }
        }
        return null;
    }

    private static Boolean sameMessageContent(MessageDto a, MessageDto b) {
        if (a == null || b == null || String.isBlank(a.content) || String.isBlank(b.content)) {
            return false;
        }
        return a.content.trim().equalsIgnoreCase(b.content.trim());
    }

    private class PendingReplayOutcome {
        Id echangeId;
        Integer apiMessageId;
        Boolean markSynced;
        String errorMessage;
    }

    /**
     * Reposte les Echange__c OUTBOUND PENDING vers l'API puis met à jour (callouts avant tout DML).
     */
    private static Integer replayPendingLocalExchanges(MissionCtx ctx) {
        Integer syncedCount = 0;
        if (ctx == null || !MissionEchangeLocalService.isAvailable()) {
            return syncedCount;
        }
        if (ctx.apiMissionIds == null || ctx.apiMissionIds.isEmpty()) {
            return syncedCount;
        }

        List<SObject> pending = MissionEchangeLocalService.listOutboundPending(ctx.salesforceId);
        if (pending.isEmpty()) {
            return syncedCount;
        }

        User u;
        try {
            u = [SELECT Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        } catch (Exception e) {
            u = null;
        }
        String defaultSender = u != null && String.isNotBlank(u.Name) ? u.Name : 'Prestataire';
        Integer replayed = 0;

        List<MessageDto> apiSnapshot = fetchApiMessagesSnapshot(ctx);
        List<PendingReplayOutcome> outcomes = new List<PendingReplayOutcome>();

        for (SObject row : pending) {
            if (replayed >= MAX_REPLAY_PER_REQUEST) {
                break;
            }
            Id echangeId = (Id) row.get('Id');
            String senderName = resolveSenderNameForReplay(row, defaultSender);
            String content = exchangeContent(row);
            if (String.isBlank(content)) {
                continue;
            }
            String contentTrimmed = content.trim();
            String tagNorm = normalizeTagForApi(extractTagFromExchange(row));
            if (String.isBlank(tagNorm)) {
                tagNorm = 'INFORMATION';
            }

            PendingReplayOutcome outcome = new PendingReplayOutcome();
            outcome.echangeId = echangeId;
            MessageDto localDto = buildLocalDtoFromExchange(row, contentTrimmed, tagNorm);

            if (hasDeliveredApiEquivalent(apiSnapshot, localDto)) {
                outcome.markSynced = true;
                outcome.apiMessageId = resolveApiIdFromEquivalent(apiSnapshot, localDto);
                outcomes.add(outcome);
                replayed++;
                continue;
            }

            try {
                HttpResponse res = tryMissionMessagesRequest(
                    'POST',
                    ctx,
                    buildPostMessageBody(ctx, contentTrimmed, tagNorm, senderName)
                );
                if (res != null && res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                    MessageDto fromPost = parsePostMessageResponse(res.getBody(), contentTrimmed);
                    if (fromPost != null) {
                        outcome.markSynced = true;
                        outcome.apiMessageId = fromPost.id;
                        apiSnapshot.add(fromPost);
                    }
                }
            } catch (AuraHandledException e) {
                outcome.errorMessage = e.getMessage();
            }

            outcomes.add(outcome);
            replayed++;
        }

        for (PendingReplayOutcome outcome : outcomes) {
            if (outcome.markSynced == true) {
                MissionEchangeLocalService.markSynced(outcome.echangeId, outcome.apiMessageId);
                syncedCount++;
            } else if (String.isNotBlank(outcome.errorMessage)) {
                MissionEchangeLocalService.recordSyncAttemptFailure(
                    outcome.echangeId,
                    outcome.errorMessage
                );
            }
        }

        return syncedCount;
    }

    /**
     * Resync automatique (Scheduler / Queueable / Trigger).
     * @return Nombre d'Echange__c passés en SYNCED.
     */
    public static Integer replayPendingForMission(Id missionSfId) {
        MissionCtx ctx = buildReplayContext(missionSfId);
        if (ctx == null) {
            return 0;
        }
        return replayPendingLocalExchanges(ctx);
    }

    /** @deprecated Utiliser replayPendingForMission — l'historique n'est plus supprimé. */
    public static Integer replayAndDeletePendingForMission(Id missionSfId) {
        return replayPendingForMission(missionSfId);
    }

    private static Integer resolveApiIdFromEquivalent(
        List<MessageDto> apiMessages,
        MessageDto local
    ) {
        if (local == null || apiMessages == null) {
            return null;
        }
        for (MessageDto api : apiMessages) {
            if (api != null
                && api.deliveredToGestionnaire == true
                && sameMessageContent(api, local)
                && api.id != null) {
                return api.id;
            }
        }
        return null;
    }

    private static MissionCtx buildReplayContext(Id missionSfId) {
        if (missionSfId == null) {
            return null;
        }
        List<Mission__c> rows = (List<Mission__c>) Database.queryWithBinds(
            'SELECT Id, Type_Prestataire__c, Numero_mission2__c, ParentId__c FROM Mission__c WHERE Id = :missionSfId LIMIT 1',
            new Map<String, Object>{ 'missionSfId' => missionSfId },
            AccessLevel.SYSTEM_MODE
        );
        if (rows.isEmpty() || isAvocatMission(rows[0])) {
            return null;
        }
        List<String> apiIds = MissionMessagingUtil.resolveMessagingIdsFromMission(rows[0]);
        if (apiIds.isEmpty()) {
            return null;
        }
        MissionCtx ctx = new MissionCtx();
        ctx.salesforceId = rows[0].Id;
        ctx.apiMissionIds = apiIds;
        ctx.typePrestataire = rows[0].Type_Prestataire__c;
        return ctx;
    }

    private static String resolveSenderNameForReplay(SObject row, String defaultSender) {
        if (row != null) {
            try {
                Object nomField = row.get('Expediteur_Nom__c');
                if (nomField != null && String.isNotBlank(String.valueOf(nomField))) {
                    return String.valueOf(nomField);
                }
            } catch (Exception e) {
                // champ absent du SELECT
            }
        }
        return String.isNotBlank(defaultSender) ? defaultSender : 'Prestataire';
    }

    private static List<MessageDto> fetchApiMessagesSnapshot(MissionCtx ctx) {
        List<MessageDto> out = new List<MessageDto>();
        try {
            HttpResponse getRes = tryMissionMessagesRequest('GET', ctx, null);
            if (getRes != null && getRes.getStatusCode() >= 200 && getRes.getStatusCode() < 300) {
                for (MessageDto dto : mapMessages(getRes.getBody())) {
                    if (dto != null && isGestionnaireApiMessage(dto)) {
                        prepareGestionnaireDisplayDto(dto);
                        out.add(dto);
                    }
                }
            }
        } catch (Exception e) {
            // API indisponible — fil local Echange__c uniquement
        }
        return out;
    }

    private static MessageDto buildLocalDtoFromExchange(
        SObject row,
        String content,
        String tag
    ) {
        MessageDto dto = new MessageDto();
        dto.sfExchangeId = (String) row.get('Id');
        dto.content = content;
        dto.tag = tag;
        dto.isMine = true;
        dto.deliveredToGestionnaire = false;
        return dto;
    }

    private static String extractTagFromExchange(SObject row) {
        if (row == null) {
            return null;
        }
        String tag = stringVal(row.get('Tag_message__c'));
        if (String.isNotBlank(tag)) {
            return tag;
        }
        String tagMulti = stringVal(row.get('Tag__c'));
        if (String.isNotBlank(tagMulti)) {
            return tagMulti.contains(';') ? tagMulti.split(';')[0].trim() : tagMulti;
        }
        return null;
    }

    private static String normalizeTagForApi(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String key = raw.trim().toUpperCase();
        if (key == 'QUESTION_TECHNIQUE' || key.contains('QUESTION')) {
            return 'QUESTION_TECHNIQUE';
        }
        if (key == 'DEMANDE_PIECES' || key.contains('PIECES') || key.contains('PIÈCES')) {
            return 'DEMANDE_PIECES';
        }
        if (key == 'INFORMATION' || key.contains('INFORM')) {
            return 'INFORMATION';
        }
        return raw.trim();
    }

    private static Boolean hasDeliveredApiEquivalent(
        List<MessageDto> apiMessages,
        MessageDto local
    ) {
        if (local == null || apiMessages == null) {
            return false;
        }
        for (MessageDto api : apiMessages) {
            if (api != null
                && api.deliveredToGestionnaire == true
                && sameMessageContent(api, local)) {
                return true;
            }
        }
        return false;
    }

    @AuraEnabled
    public static void markMessageRead(
        String missionId,
        Integer messageId,
        String echangeRecordId
    ) {
        if (String.isNotBlank(echangeRecordId)) {
            MissionEchangeLocalService.markRead((Id) echangeRecordId);
            return;
        }
        if (messageId == null) {
            throw new AuraHandledException('messageId requis.');
        }
        resolveContext(missionId);
        Map<String, Object> body = new Map<String, Object>{ 'isRead' => true };
        HttpResponse res = sendRequest(
            'PUT',
            'missions/messages/' + messageId,
            JSON.serialize(body)
        );
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new AuraHandledException(httpError(res));
        }
    }

    private static MissionCtx resolveContext(String missionId) {
        Id mid = parseSalesforceId(missionId);
        if (mid == null) {
            throw new AuraHandledException('Identifiant mission invalide.');
        }

        Id accountId = currentAccountId();
        if (accountId == null) {
            throw new AuraHandledException('Utilisateur sans compte prestataire associé.');
        }

        List<Mission__c> rows = [
            SELECT
                Id,
                Prestataire__c,
                Type_Prestataire__c,
                Numero_mission2__c,
                ParentId__c
            FROM Mission__c
            WHERE Id = :mid AND Prestataire__c = :accountId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Mission introuvable ou accès refusé.');
        }

        Mission__c m = rows[0];
        if (isAvocatMission(m)) {
            throw new AuraHandledException(
                'La messagerie par mission n\'est pas disponible pour le profil Avocat.'
            );
        }

        List<String> apiIds = MissionMessagingUtil.resolveMessagingIdsFromMission(m);

        MissionCtx ctx = new MissionCtx();
        ctx.salesforceId = m.Id;
        ctx.apiMissionIds = apiIds;
        ctx.typePrestataire = m.Type_Prestataire__c;

        if (apiIds.isEmpty() && !MissionEchangeLocalService.isAvailable()) {
            throw new AuraHandledException(
                'Mission non synchronisée avec le gestionnaire (identifiant API manquant ou invalide).'
            );
        }
        return ctx;
    }

    private static AuraHandledException apiMissionNotFound(MissionCtx ctx) {
        return new AuraHandledException(
            'API messagerie : mission introuvable côté gestionnaire (ids testés : ' +
            MissionMessagingUtil.formatTriedIdsMessage(ctx.apiMissionIds) +
            '). Vérifiez que la sync self-missionning a renvoyé un numeroMission, ' +
            'ou utilisez la messagerie locale Echange__c.'
        );
    }

    /**
     * Corps POST /missions/{numeroMission}/messages (schéma API gestionnaire).
     */
    private static Map<String, Object> buildPostMessageBody(
        MissionCtx ctx,
        String content,
        String tag,
        String senderName
    ) {
        String numeroMission = ctx != null ? ctx.resolvedApiMissionId : null;
        if (String.isBlank(numeroMission) && ctx != null && ctx.apiMissionIds != null
            && !ctx.apiMissionIds.isEmpty()) {
            numeroMission = ctx.apiMissionIds[0];
        }
        Map<String, Object> body = new Map<String, Object>{
            'id' => 0,
            'phaseId' => 0,
            'content' => content,
            'tag' => tag,
            'sentAt' => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
            'isRead' => false,
            'read' => false,
            'senderName' => senderName,
            'senderRole' => 'PRESTATAIRE',
            'attachments' => new List<Object>(),
            'attachmentIds' => new List<Object>()
        };
        if (String.isNotBlank(numeroMission)) {
            body.put('missionId', numeroMission);
        } else {
            body.put('missionId', 0);
        }
        return body;
    }

    private static HttpResponse tryMissionMessagesRequest(
        String method,
        MissionCtx ctx,
        Object bodyOrTemplate
    ) {
        if (ctx.apiMissionIds == null || ctx.apiMissionIds.isEmpty()) {
            return null;
        }
        HttpResponse lastRes;
        for (String apiId : ctx.apiMissionIds) {
            String path =
                'missions/' +
                EncodingUtil.urlEncode(apiId, 'UTF-8') +
                '/messages';
            String body = null;
            if (bodyOrTemplate instanceof Map<String, Object> && 'POST'.equalsIgnoreCase(method)) {
                Map<String, Object> tpl = (Map<String, Object>) bodyOrTemplate;
                if (String.isBlank(ctx.resolvedApiMissionId)) {
                    tpl.put('missionId', apiId);
                }
                body = JSON.serialize(tpl);
            } else if (bodyOrTemplate instanceof Map<String, Object>) {
                body = JSON.serialize(bodyOrTemplate);
            } else if (bodyOrTemplate != null) {
                body = String.valueOf(bodyOrTemplate);
            }
            lastRes = sendRequest(method, path, body);
            if (lastRes.getStatusCode() >= 200 && lastRes.getStatusCode() < 300) {
                ctx.resolvedApiMissionId = apiId;
                return lastRes;
            }
            if (!MissionMessagingUtil.isRetryableMissionNotFound(lastRes)) {
                throw new AuraHandledException(httpError(lastRes));
            }
        }
        return null;
    }

    private static Boolean isAvocatMission(Mission__c m) {
        if (m == null) {
            return false;
        }
        String t = m.Type_Prestataire__c;
        return t != null && t.equalsIgnoreCase('Avocat');
    }

    private static Id currentAccountId() {
        User u = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        if (u.ContactId == null) {
            return null;
        }
        Contact c = [SELECT AccountId FROM Contact WHERE Id = :u.ContactId LIMIT 1];
        return c.AccountId;
    }

    private static Id parseSalesforceId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim();
        if (s.length() == 15 || s.length() == 18) {
            try {
                return (Id) s;
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private static HttpResponse sendRequest(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/' + path.replaceAll('^/+', ''));
        req.setMethod(method);
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json; charset=UTF-8');
        req.setHeader('Accept', 'application/json');
        applyAuthHeader(req);
        if (String.isNotBlank(body)) {
            req.setBody(body);
        }
        return new Http().send(req);
    }

    private static void applyAuthHeader(HttpRequest req) {
        try {
            GED_Config__mdt cfg = GED_Config__mdt.getInstance('Default');
            if (cfg != null && String.isNotBlank(cfg.Auth_Token__c)) {
                req.setHeader('Authorization', 'Bearer ' + cfg.Auth_Token__c);
            }
        } catch (Exception e) {
            // Named Credential gère l'auth si pas de token CMDT
        }
    }

    private static String httpError(HttpResponse res) {
        String msg = res.getStatus();
        if (String.isNotBlank(res.getBody())) {
            msg += ' — ' + res.getBody().left(500);
        }
        return 'API messagerie (' + res.getStatusCode() + ') : ' + msg;
    }

    private static List<MessageDto> mapMessages(String jsonBody) {
        List<MessageDto> out = new List<MessageDto>();
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
            } else {
                for (String k : new List<String>{ 'data', 'messages', 'items', 'content' }) {
                    if (m.containsKey(k) && m.get(k) instanceof List<Object>) {
                        items = (List<Object>) m.get(k);
                        break;
                    }
                }
            }
        }
        for (Object o : items) {
            if (o instanceof Map<String, Object>) {
                out.add(mapOne((Map<String, Object>) o));
            }
        }
        return out;
    }

    private static MessageDto mapOne(Map<String, Object> m) {
        MessageDto dto = new MessageDto();
        dto.id = toInteger(m.get('id'));
        dto.content = firstNonBlank(
            new List<Object>{ m.get('content'), m.get('body'), m.get('text'), m.get('message'), m.get('libelle') }
        );
        dto.senderName = firstNonBlank(
            new List<Object>{ m.get('senderName'), m.get('sender'), m.get('authorName'), m.get('expediteurNom') }
        );
        dto.senderRole = firstNonBlank(
            new List<Object>{ m.get('senderRole'), m.get('role'), m.get('senderType'), m.get('typeExpediteur') }
        );
        dto.sentAt = firstNonBlank(
            new List<Object>{ m.get('sentAt'), m.get('sent_at'), m.get('dateEnvoi'), m.get('createdAt') }
        );
        dto.tag = resolveTagFromPayload(m.get('tag'));
        dto.isRead = toBoolean(m.get('isRead'));
        if (dto.isRead == null) {
            dto.isRead = toBoolean(m.get('read'));
        }
        dto.isMine = isPrestataireMessage(dto.senderRole);
        if (!dto.isMine) {
            dto.senderRole = String.isNotBlank(dto.senderRole) ? dto.senderRole : 'GESTIONNAIRE';
            if (String.isBlank(dto.senderName)) {
                dto.senderName = 'Gestionnaire';
            }
        }
        if (dto.deliveredToGestionnaire == null) {
            dto.deliveredToGestionnaire = dto.isMine == true;
            dto.deliveryStatus = dto.isMine == true
                ? MissionEchangeLocalService.SYNC_SYNCED
                : 'GESTIONNAIRE';
        }
        return dto;
    }

    private static Boolean isPrestataireMessage(String role) {
        if (String.isBlank(role)) {
            return false;
        }
        String r = role.toLowerCase();
        if (r.contains('gestion')
            || r.contains('manager')
            || r.contains('gs')
            || r == 'poste') {
            return false;
        }
        return r.contains('prestataire')
            || r.contains('provider')
            || r.contains('medec')
            || r.contains('médec');
    }

    private static String firstNonBlank(List<Object> values) {
        if (values == null) {
            return null;
        }
        for (Object o : values) {
            String s = stringVal(o);
            if (String.isNotBlank(s)) {
                return s;
            }
        }
        return null;
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

    private static String exchangeContent(SObject row) {
        if (row == null) {
            return null;
        }
        try {
            return stringVal(row.get('Contenu__c'));
        } catch (Exception e) {
            return null;
        }
    }

    /** Tag API : chaîne ou objet { code, label }. */
    private static String resolveTagFromPayload(Object tagObj) {
        if (tagObj == null) {
            return null;
        }
        if (tagObj instanceof Map<String, Object>) {
            Map<String, Object> tm = (Map<String, Object>) tagObj;
            if (tm.containsKey('code') && tm.get('code') != null) {
                return stringVal(tm.get('code'));
            }
            if (tm.containsKey('label') && tm.get('label') != null) {
                return stringVal(tm.get('label'));
            }
        }
        return stringVal(tagObj);
    }
}
