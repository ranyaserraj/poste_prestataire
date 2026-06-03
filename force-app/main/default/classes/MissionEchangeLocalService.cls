/**
 * Historique messagerie mission — tous les messages sont persistés dans Echange__c.
 * Statut_Sync__c : PENDING | SYNCED | FAILED — Source__c : OUTBOUND | INBOUND
 */
public without sharing class MissionEchangeLocalService {

    private static final String OBJ = 'Echange__c';

    public static final String SYNC_PENDING = 'PENDING';
    public static final String SYNC_SYNCED = 'SYNCED';
    public static final String SYNC_FAILED = 'FAILED';
    public static final String SOURCE_OUTBOUND = 'OUTBOUND';
    public static final String SOURCE_INBOUND = 'INBOUND';

    private static final Integer MAX_SYNC_ATTEMPTS = 10;
    private static final String NAME_MARKER_PENDING = '[PENDING]';
    private static final String NAME_MARKER_SYNCED = '[SYNCED]';
    private static final String NAME_MARKER_FAILED = '[FAILED]';

    private static final Map<String, List<String>> TAG_FALLBACKS = new Map<String, List<String>>{
        'QUESTION_TECHNIQUE' => new List<String>{
            'QUESTION_TECHNIQUE',
            'Question technique',
            'Question_technique'
        },
        'DEMANDE_PIECES' => new List<String>{
            'DEMANDE_PIECES',
            'Demande de pièces',
            'Demande_de_pieces'
        },
        'INFORMATION' => new List<String>{ 'INFORMATION', 'Information' }
    };

    public static Boolean isAvailable() {
        return Schema.getGlobalDescribe().containsKey(OBJ);
    }

    /** Trigger / Queueable : uniquement OUTBOUND en PENDING. */
    public static Boolean shouldEnqueueOutboundReplay(SObject row) {
        if (row == null) {
            return false;
        }
        return isOutboundPendingRow(row, row.getPopulatedFieldsAsMap().keySet());
    }

    /** Fil de mission : historique complet depuis Echange__c. */
    public static List<MissionMessageController.MessageDto> getMessages(Id missionSfId) {
        if (!isAvailable() || missionSfId == null) {
            return new List<MissionMessageController.MessageDto>();
        }
        try {
            Map<String, Schema.SObjectField> fMap = fieldMap();
            List<String> fields = baseSelectFields(fMap);
            String orderField = fMap.containsKey('Date_Envoi__c') ? 'Date_Envoi__c' : 'CreatedDate';
            ExchangeQueryResult queryResult = queryExchanges(missionSfId, fields, orderField);
            List<SObject> rows = queryResult.rows;
            List<MissionMessageController.MessageDto> out = new List<MissionMessageController.MessageDto>();
            Set<String> selected = new Set<String>(queryResult.fields);
            Integer idx = 0;
            for (SObject row : rows) {
                out.add(mapRow(row, idx++, selected));
            }
            return out;
        } catch (Exception e) {
            throwServiceError('Lecture Echange__c : ' + rootMessage(e));
            return new List<MissionMessageController.MessageDto>();
        }
    }

    private class ExchangeQueryResult {
        List<SObject> rows;
        List<String> fields;
    }

    private static ExchangeQueryResult queryExchanges(
        Id missionSfId,
        List<String> fields,
        String orderField
    ) {
        ExchangeQueryResult out = new ExchangeQueryResult();
        out.fields = fields;
        String q =
            'SELECT ' +
            String.join(fields, ', ') +
            ' FROM ' +
            OBJ +
            ' WHERE Mission__c = :missionSfId ORDER BY ' +
            orderField +
            ' ASC NULLS LAST';
        try {
            out.rows = runSoql(q, new Map<String, Object>{ 'missionSfId' => missionSfId });
            return out;
        } catch (QueryException qe) {
            if (!isInvalidFieldQueryException(qe)) {
                throw qe;
            }
            List<String> minimal = minimalSelectFields(fieldMap());
            if (minimal.size() == fields.size()) {
                throw qe;
            }
            return queryExchanges(missionSfId, minimal, orderField);
        }
    }

    private static ExchangeQueryResult queryAllExchanges(List<String> fields) {
        ExchangeQueryResult out = new ExchangeQueryResult();
        out.fields = fields;
        String q = 'SELECT ' + String.join(fields, ', ') + ' FROM ' + OBJ + ' WHERE Mission__c != NULL';
        try {
            out.rows = runSoql(q);
            return out;
        } catch (QueryException qe) {
            if (!isInvalidFieldQueryException(qe)) {
                throw qe;
            }
            List<String> minimal = minimalSelectFields(fieldMap());
            if (minimal.size() == fields.size()) {
                throw qe;
            }
            return queryAllExchanges(minimal);
        }
    }

    private static Boolean isInvalidFieldQueryException(QueryException qe) {
        String msg = qe != null ? qe.getMessage() : '';
        return msg != null && msg.contains('Invalid field');
    }

    /**
     * Prestataire envoie : INSERT PENDING + OUTBOUND, puis sync API via Queueable / replay.
     */
    public static MissionMessageController.MessageDto createOutboundPending(
        Id missionSfId,
        String content,
        String tag
    ) {
        return insertExchange(
            missionSfId,
            content,
            tag,
            SOURCE_OUTBOUND,
            SYNC_PENDING,
            true,
            UserInfo.getUserId(),
            null,
            null,
            null
        );
    }

    /**
     * Gestionnaire → portail (API inbound) : INSERT SYNCED + INBOUND.
     */
    public static MissionMessageController.MessageDto createInboundSynced(
        Id missionSfId,
        String content,
        String tag,
        String senderName,
        Integer apiMessageId,
        String sentAtIso
    ) {
        return insertExchange(
            missionSfId,
            content,
            tag,
            SOURCE_INBOUND,
            SYNC_SYNCED,
            false,
            null,
            senderName,
            apiMessageId,
            sentAtIso
        );
    }

    /** Indique si un message gestionnaire similaire existe déjà (usage optionnel). */
    public static Boolean hasArchivedInbound(Id missionSfId, MissionMessageController.MessageDto api) {
        if (!isAvailable() || missionSfId == null || api == null || String.isBlank(api.content)) {
            return false;
        }
        try {
            String content = api.content.trim();
            if (api.id != null) {
                String apiField = apiMessageIdFieldApi();
                if (apiField != null) {
                    String q =
                        'SELECT Id FROM ' +
                        OBJ +
                        ' WHERE Mission__c = :missionSfId AND ' +
                        apiField +
                        ' = :apiId LIMIT 1';
                    List<SObject> byId = runSoql(
                        q,
                        new Map<String, Object>{
                            'missionSfId' => missionSfId,
                            'apiId' => String.valueOf(api.id)
                        }
                    );
                    if (!byId.isEmpty()) {
                        return true;
                    }
                }
            }
            Map<String, Schema.SObjectField> fMap = fieldMap();
            List<String> fields = new List<String>{ 'Id', 'Contenu__c' };
            addSelectField(fields, fMap, 'Source__c');
            addSelectField(fields, fMap, 'Type_Expediteur__c');
            String q2 =
                'SELECT ' +
                String.join(fields, ', ') +
                ' FROM ' +
                OBJ +
                ' WHERE Mission__c = :missionSfId AND Contenu__c = :content LIMIT 20';
            for (SObject row : runSoql(
                q2,
                new Map<String, Object>{ 'missionSfId' => missionSfId, 'content' => content }
            )) {
                Set<String> selected = new Set<String>(fields);
                if (isGestionnaireRow(row, selected) || SOURCE_INBOUND.equalsIgnoreCase(
                    stringVal(fieldValue(row, selected, 'Source__c'))
                )) {
                    return true;
                }
            }
        } catch (Exception e) {
            // non bloquant
        }
        return false;
    }

    public static MissionMessageController.MessageDto markSynced(
        Id echangeId,
        Integer apiMessageId
    ) {
        return updateSyncStatus(echangeId, SYNC_SYNCED, null, apiMessageId, true);
    }

    public static MissionMessageController.MessageDto markSyncFailed(
        Id echangeId,
        String errorMessage
    ) {
        return updateSyncStatus(echangeId, SYNC_FAILED, errorMessage, null, false);
    }

    public static void recordSyncAttemptFailure(Id echangeId, String errorMessage) {
        if (!isAvailable() || echangeId == null) {
            return;
        }
        try {
            SObject e = loadExchangeById(echangeId);
            if (e == null) {
                return;
            }
            putIfExists(e, 'Erreur_Sync__c', String.isNotBlank(errorMessage) ? errorMessage.left(32768) : null);
            if (fieldExists('Tentatives_Sync__c')) {
                Integer attempts = toInteger(e.get('Tentatives_Sync__c'));
                attempts = attempts == null ? 1 : attempts + 1;
                e.put('Tentatives_Sync__c', attempts);
                if (attempts >= MAX_SYNC_ATTEMPTS && fieldExists('Statut_Sync__c')) {
                    String failed = resolvePicklistValue(
                        'Statut_Sync__c',
                        SYNC_FAILED,
                        new List<String>{ SYNC_FAILED, 'Failed', 'Echec' }
                    );
                    if (failed != null) {
                        e.put('Statut_Sync__c', failed);
                    }
                }
            }
            updateRecord(e);
        } catch (Exception ex) {
            // non bloquant
        }
    }

    /** @deprecated Ne plus supprimer — conserver l'historique. */
    public static void deleteExchanges(List<Id> echangeIds) {
        // Historique obligatoire : no-op volontaire.
    }

    /** Messages OUTBOUND en attente de sync API (Statut_Sync__c = PENDING). */
    public static List<SObject> listOutboundPending(Id missionSfId) {
        if (!isAvailable() || missionSfId == null) {
            return new List<SObject>();
        }
        try {
            Map<String, Schema.SObjectField> fMap = fieldMap();
            List<String> fields = baseSelectFields(fMap);
            String orderField = fMap.containsKey('Date_Envoi__c') ? 'Date_Envoi__c' : 'CreatedDate';
            ExchangeQueryResult queryResult = queryExchanges(missionSfId, fields, orderField);
            Set<String> selected = new Set<String>(queryResult.fields);
            List<SObject> pending = new List<SObject>();
            for (SObject row : queryResult.rows) {
                if (isOutboundPendingRow(row, selected)) {
                    pending.add(row);
                }
            }
            return pending;
        } catch (Exception e) {
            return new List<SObject>();
        }
    }

    public static Set<Id> listMissionIdsWithOutboundPending() {
        Set<Id> missionIds = new Set<Id>();
        if (!isAvailable()) {
            return missionIds;
        }
        try {
            Map<String, Schema.SObjectField> fMap = fieldMap();
            List<String> fields = baseSelectFields(fMap);
            if (!fields.contains('Mission__c')) {
                fields.add('Mission__c');
            }
            ExchangeQueryResult queryResult = queryAllExchanges(fields);
            Set<String> selected = new Set<String>(queryResult.fields);
            for (SObject row : queryResult.rows) {
                if (isOutboundPendingRow(row, selected)) {
                    Id mid = (Id) fieldValue(row, selected, 'Mission__c');
                    if (mid != null) {
                        missionIds.add(mid);
                    }
                }
            }
        } catch (Exception e) {
            // non bloquant
        }
        return missionIds;
    }

    public static MissionMessageController.MessageDto getById(Id echangeId) {
        if (!isAvailable() || echangeId == null) {
            return null;
        }
        try {
            Map<String, Schema.SObjectField> fMap = fieldMap();
            List<String> fields = baseSelectFields(fMap);
            List<SObject> rows = runSoql(
                'SELECT ' +
                String.join(fields, ', ') +
                ' FROM ' +
                OBJ +
                ' WHERE Id = :echangeId LIMIT 1',
                new Map<String, Object>{ 'echangeId' => echangeId }
            );
            if (rows.isEmpty()) {
                return null;
            }
            return mapRow(rows[0], 0, new Set<String>(fields));
        } catch (Exception e) {
            return null;
        }
    }

    public static void markRead(Id echangeId) {
        if (!isAvailable() || echangeId == null) {
            return;
        }
        try {
            List<SObject> readRows = runSoql(
                'SELECT Id FROM ' + OBJ + ' WHERE Id = :echangeId LIMIT 1',
                new Map<String, Object>{ 'echangeId' => echangeId }
            );
            if (readRows.isEmpty()) {
                return;
            }
            SObject e = readRows[0];
            String statutLu = resolvePicklistValue(
                'Statut_Lecture__c',
                'Lu',
                new List<String>{ 'Lu', 'LU', 'Lue' }
            );
            if (statutLu != null) {
                e.put('Statut_Lecture__c', statutLu);
            }
            putIfExists(e, 'Lu__c', true);
            if (fieldExists('Date_Lecture__c')) {
                e.put('Date_Lecture__c', System.now());
            } else if (fieldExists('Lu_le__c')) {
                e.put('Lu_le__c', System.now());
            }
            updateRecord(e);
        } catch (Exception e) {
            // non bloquant
        }
    }

    private static MissionMessageController.MessageDto insertExchange(
        Id missionSfId,
        String content,
        String tag,
        String source,
        String syncStatus,
        Boolean isOutboundPrestataire,
        Id expediteurUserId,
        String senderName,
        Integer apiMessageId,
        String sentAtIso
    ) {
        if (!isAvailable()) {
            throwServiceError('Objet Echange__c indisponible dans l\'org.');
            return null;
        }
        try {
            SObject e = Schema.getGlobalDescribe().get(OBJ).newSObject();
            e.put('Mission__c', missionSfId);

            String name = ('Message ' + Datetime.now().format('dd/MM/yyyy HH:mm')).left(80);
            if (fieldExists('Name')) {
                e.put('Name', name);
            }

            putIfExists(e, 'Contenu__c', content);
            putTagFields(e, tag);
            putSyncAndSource(e, source, syncStatus);
            applySyncNameMarker(e, syncStatus);
            putApiMessageId(e, apiMessageId);

            if (isOutboundPrestataire) {
                putIfExists(e, 'Auteur_id__c', String.valueOf(expediteurUserId));
                String auteurType = resolvePicklistValue(
                    'Auteur_type__c',
                    'Prestataire',
                    new List<String>{ 'Prestataire', 'PRESTATAIRE', 'Medecin', 'Médecin' }
                );
                if (auteurType != null) {
                    e.put('Auteur_type__c', auteurType);
                }
                String typeExp = resolvePicklistValue(
                    'Type_Expediteur__c',
                    'Prestataire',
                    new List<String>{ 'Prestataire', 'PRESTATAIRE', 'Médecin', 'Medecin' }
                );
                if (typeExp != null) {
                    e.put('Type_Expediteur__c', typeExp);
                }
                putIfExists(e, 'Expediteur__c', expediteurUserId);
            } else {
                String typeExp = resolvePicklistValue(
                    'Type_Expediteur__c',
                    'Gestionnaire',
                    new List<String>{ 'Gestionnaire', 'GESTIONNAIRE', 'Gestionnaire' }
                );
                if (typeExp != null) {
                    e.put('Type_Expediteur__c', typeExp);
                }
                if (String.isNotBlank(senderName) && fieldExists('Expediteur_Nom__c')) {
                    putIfExists(e, 'Expediteur_Nom__c', senderName);
                }
            }

            String typeEchange = resolvePicklistValue(
                'Type_echange__c',
                'Message',
                new List<String>{ 'Message', 'Echange', 'Messagerie' }
            );
            if (typeEchange != null) {
                e.put('Type_echange__c', typeEchange);
            }

            if (String.isNotBlank(sentAtIso) && fieldExists('Date_Envoi__c')) {
                try {
                    e.put('Date_Envoi__c', Datetime.valueOfGmt(sentAtIso.replace('T', ' ').replace('Z', '')));
                } catch (Exception ex) {
                    putIfExists(e, 'Date_Envoi__c', System.now());
                }
            } else {
                putIfExists(e, 'Date_Envoi__c', System.now());
            }

            Boolean inboundUnread = SOURCE_INBOUND.equalsIgnoreCase(source);
            String statutLecture = inboundUnread
                ? resolvePicklistValue(
                      'Statut_Lecture__c',
                      'Non lu',
                      new List<String>{ 'Non lu', 'Non Lu', 'NON_LU', 'Non_lu' }
                  )
                : resolvePicklistValue(
                      'Statut_Lecture__c',
                      'Lu',
                      new List<String>{ 'Lu', 'LU', 'Lue' }
                  );
            if (statutLecture != null) {
                e.put('Statut_Lecture__c', statutLecture);
            }
            putIfExists(e, 'Lu__c', !inboundUnread);

            if (!isOutboundPrestataire) {
                e.put('OwnerId', UserInfo.getUserId());
            }

            insertRecord(e);
            return getById((Id) e.get('Id'));
        } catch (DmlException dml) {
            throwServiceError('Création Echange__c : ' + formatDml(dml));
            return null;
        } catch (Exception e) {
            throwServiceError('Envoi messagerie : ' + rootMessage(e));
            return null;
        }
    }

    private static MissionMessageController.MessageDto updateSyncStatus(
        Id echangeId,
        String syncStatus,
        String errorMessage,
        Integer apiMessageId,
        Boolean clearAttempts
    ) {
        if (!isAvailable() || echangeId == null) {
            return null;
        }
        try {
            SObject e = loadExchangeById(echangeId);
            if (e == null) {
                return null;
            }
            putSyncStatus(e, syncStatus);
            applySyncNameMarker(e, syncStatus);
            if (String.isNotBlank(errorMessage)) {
                putIfExists(e, 'Erreur_Sync__c', errorMessage.left(32768));
            } else if (fieldExists('Erreur_Sync__c')) {
                e.put('Erreur_Sync__c', null);
            }
            if (apiMessageId != null) {
                putApiMessageId(e, apiMessageId);
            }
            if (clearAttempts == true && fieldExists('Tentatives_Sync__c')) {
                e.put('Tentatives_Sync__c', 0);
            }
            updateRecord(e);
            return getById(echangeId);
        } catch (Exception ex) {
            return getById(echangeId);
        }
    }

    private static SObject loadExchangeById(Id echangeId) {
        Map<String, Schema.SObjectField> fMap = fieldMap();
        List<SObject> rows = runSoql(
            'SELECT ' +
            String.join(baseSelectFields(fMap), ', ') +
            ' FROM ' +
            OBJ +
            ' WHERE Id = :echangeId LIMIT 1',
            new Map<String, Object>{ 'echangeId' => echangeId }
        );
        return rows.isEmpty() ? null : rows[0];
    }

    private static Boolean isOutboundPendingRow(SObject row, Set<String> selected) {
        if (row == null || isSyncedRow(row, selected)) {
            return false;
        }
        if (isGestionnaireRow(row, selected)) {
            return false;
        }
        String sync = resolveEffectiveSyncStatus(row, selected);
        if (SYNC_SYNCED.equalsIgnoreCase(sync) || SYNC_FAILED.equalsIgnoreCase(sync)) {
            return false;
        }
        if (isPendingSyncValue(sync)) {
            return true;
        }
        return isOutboundPrestataireRow(row, selected);
    }

    private static Boolean isPendingSyncValue(String sync) {
        return String.isNotBlank(sync) && SYNC_PENDING.equalsIgnoreCase(sync.trim());
    }

    private static Boolean isSyncedRow(SObject row, Set<String> selected) {
        String sync = resolveEffectiveSyncStatus(row, selected);
        return SYNC_SYNCED.equalsIgnoreCase(sync) || SYNC_FAILED.equalsIgnoreCase(sync);
    }

    /**
     * Lignes importées gestionnaire sans Source__c / Type_Expediteur__c (anciennes données).
     */
    private static Boolean isLikelyInboundGestionnaireRow(SObject row, Set<String> selected) {
        if (selectedContains(selected, 'Expediteur__c')) {
            Object exp = fieldValue(row, selected, 'Expediteur__c');
            if (exp != null) {
                return false;
            }
        }
        if (selectedContains(selected, 'Source__c')) {
            String src = stringVal(fieldValue(row, selected, 'Source__c'));
            if (SOURCE_OUTBOUND.equalsIgnoreCase(src)) {
                return false;
            }
            if (SOURCE_INBOUND.equalsIgnoreCase(src)) {
                return true;
            }
        }
        String typeExp = stringVal(fieldValue(row, selected, 'Type_Expediteur__c'));
        if (String.isNotBlank(typeExp)) {
            String t = typeExp.toLowerCase();
            if (t.contains('gestion')) {
                return true;
            }
            if (t.contains('prest') || t.contains('medec') || t.contains('médec')) {
                return false;
            }
        }
        String nom = stringVal(fieldValue(row, selected, 'Expediteur_Nom__c'));
        return String.isNotBlank(nom);
    }

    private static Boolean isGestionnaireRow(SObject row, Set<String> selected) {
        if (selectedContains(selected, 'Source__c')) {
            String src = stringVal(fieldValue(row, selected, 'Source__c'));
            if (SOURCE_INBOUND.equalsIgnoreCase(src)) {
                return true;
            }
        }
        String typeExp = stringVal(fieldValue(row, selected, 'Type_Expediteur__c'));
        return typeExp != null && typeExp.toLowerCase().contains('gestion');
    }

    private static Boolean isOutboundPrestataireRow(SObject row, Set<String> selected) {
        if (isGestionnaireRow(row, selected)) {
            return false;
        }
        if (selectedContains(selected, 'Source__c')) {
            String src = stringVal(fieldValue(row, selected, 'Source__c'));
            if (SOURCE_OUTBOUND.equalsIgnoreCase(src)) {
                return true;
            }
        }
        return isPrestataireType(row, selected);
    }

    private static Boolean isPrestataireType(SObject row, Set<String> selected) {
        String typeExp = stringVal(fieldValue(row, selected, 'Type_Expediteur__c'));
        if (String.isBlank(typeExp)) {
            return true;
        }
        String t = typeExp.toLowerCase();
        if (t.contains('gestion')) {
            return false;
        }
        return t.contains('prest') || t.contains('medec') || t.contains('médec');
    }

    private static String resolveEffectiveSyncStatus(SObject row, Set<String> selected) {
        String sync = stringVal(fieldValue(row, selected, 'Statut_Sync__c'));
        if (String.isNotBlank(sync)) {
            return sync;
        }
        String name = stringVal(row.get('Name'));
        if (name != null) {
            if (name.contains(NAME_MARKER_SYNCED)) {
                return SYNC_SYNCED;
            }
            if (name.contains(NAME_MARKER_FAILED)) {
                return SYNC_FAILED;
            }
            if (name.contains(NAME_MARKER_PENDING)) {
                return SYNC_PENDING;
            }
        }
        if (isGestionnaireRow(row, selected)) {
            return SYNC_SYNCED;
        }
        if (isOutboundPrestataireRow(row, selected)) {
            return SYNC_PENDING;
        }
        return null;
    }

    private static void applySyncNameMarker(SObject e, String syncStatus) {
        if (fieldExists('Statut_Sync__c') || e == null || String.isBlank(syncStatus)) {
            return;
        }
        String name = stringVal(e.get('Name'));
        if (String.isBlank(name)) {
            return;
        }
        name = name.replace(NAME_MARKER_PENDING, '')
            .replace(NAME_MARKER_SYNCED, '')
            .replace(NAME_MARKER_FAILED, '')
            .trim();
        String marker = NAME_MARKER_PENDING;
        if (SYNC_SYNCED.equalsIgnoreCase(syncStatus)) {
            marker = NAME_MARKER_SYNCED;
        } else if (SYNC_FAILED.equalsIgnoreCase(syncStatus)) {
            marker = NAME_MARKER_FAILED;
        }
        e.put('Name', (name + ' ' + marker).trim().left(80));
    }

    private static void putSyncAndSource(SObject e, String source, String syncStatus) {
        if (fieldExists('Source__c') && String.isNotBlank(source)) {
            String src = resolvePicklistValue(
                'Source__c',
                source,
                new List<String>{ source, SOURCE_OUTBOUND, SOURCE_INBOUND }
            );
            if (src != null) {
                e.put('Source__c', src);
            }
        }
        putSyncStatus(e, syncStatus);
    }

    private static void putSyncStatus(SObject e, String syncStatus) {
        if (!fieldExists('Statut_Sync__c') || String.isBlank(syncStatus)) {
            return;
        }
        String resolved = resolvePicklistValue(
            'Statut_Sync__c',
            syncStatus,
            new List<String>{ syncStatus, SYNC_PENDING, SYNC_SYNCED, SYNC_FAILED }
        );
        if (resolved != null) {
            e.put('Statut_Sync__c', resolved);
        }
    }

    private static void putApiMessageId(SObject e, Integer apiMessageId) {
        if (apiMessageId == null) {
            return;
        }
        String apiField = apiMessageIdFieldApi();
        if (apiField != null) {
            e.put(apiField, String.valueOf(apiMessageId));
        }
    }

    private static String apiMessageIdFieldApi() {
        Map<String, Schema.SObjectField> fMap = fieldMap();
        for (String cand : new List<String>{ 'Id_Message_API__c', 'Message_Id_Gestionnaire__c' }) {
            if (fMap.containsKey(cand)) {
                return cand;
            }
        }
        return null;
    }

    private static List<String> baseSelectFields(Map<String, Schema.SObjectField> fMap) {
        List<String> fields = new List<String>{ 'Id', 'Name', 'CreatedDate' };
        addSelectField(fields, fMap, 'Contenu__c');
        addSelectField(fields, fMap, 'Tag_message__c');
        addSelectField(fields, fMap, 'Tag__c');
        addSelectField(fields, fMap, 'Type_Expediteur__c');
        addSelectField(fields, fMap, 'Date_Envoi__c');
        addSelectField(fields, fMap, 'Statut_Lecture__c');
        addSelectField(fields, fMap, 'Lu__c');
        addSelectField(fields, fMap, 'Expediteur__c');
        addSelectField(fields, fMap, 'Statut_Sync__c');
        addSelectField(fields, fMap, 'Source__c');
        addSelectField(fields, fMap, 'Erreur_Sync__c');
        addSelectField(fields, fMap, 'Tentatives_Sync__c');
        addSelectField(fields, fMap, 'Expediteur_Nom__c');
        String apiMsgField = apiMessageIdFieldApi();
        if (apiMsgField != null && !fields.contains(apiMsgField)) {
            fields.add(apiMsgField);
        }
        return fields;
    }

    private static List<String> minimalSelectFields(Map<String, Schema.SObjectField> fMap) {
        List<String> fields = new List<String>{ 'Id', 'Name', 'CreatedDate' };
        for (String api : new List<String>{
            'Contenu__c',
            'Tag_message__c',
            'Tag__c',
            'Type_Expediteur__c',
            'Date_Envoi__c',
            'Statut_Lecture__c',
            'Lu__c',
            'Expediteur__c',
            'Mission__c'
        }) {
            addSelectField(fields, fMap, api);
        }
        return fields;
    }

    private static MissionMessageController.MessageDto mapRow(
        SObject row,
        Integer idx,
        Set<String> selected
    ) {
        MissionMessageController.MessageDto dto = new MissionMessageController.MessageDto();
        String apiMsgField = apiMessageIdFieldApi();
        if (apiMsgField != null && selectedContains(selected, apiMsgField)) {
            dto.id = toInteger(row.get(apiMsgField));
        }
        if (dto.id == null) {
            dto.id = idx;
        }
        dto.sfExchangeId = (String) row.get('Id');
        dto.content = stringVal(fieldValue(row, selected, 'Contenu__c'));
        if (String.isBlank(dto.content)) {
            dto.content = '';
        }
        dto.tag = stringVal(fieldValue(row, selected, 'Tag_message__c'));
        if (String.isBlank(dto.tag)) {
            String tagMulti = stringVal(fieldValue(row, selected, 'Tag__c'));
            if (String.isNotBlank(tagMulti)) {
                dto.tag = tagMulti.contains(';') ? tagMulti.split(';')[0].trim() : tagMulti;
            }
        }

        String source = stringVal(fieldValue(row, selected, 'Source__c'));
        String syncStatus = resolveEffectiveSyncStatus(row, selected);
        String typeExp = stringVal(fieldValue(row, selected, 'Type_Expediteur__c'));

        Boolean inbound =
            SOURCE_INBOUND.equalsIgnoreCase(source)
            || isGestionnaireRow(row, selected)
            || isLikelyInboundGestionnaireRow(row, selected);
        dto.isMine = !inbound;
        dto.senderRole = inbound ? 'GESTIONNAIRE' : 'PRESTATAIRE';

        dto.senderName = resolveExpediteurDisplayName(row, selected);
        if (!dto.isMine) {
            dto.senderName = String.isNotBlank(dto.senderName) ? dto.senderName : 'Gestionnaire';
        } else if (String.isBlank(dto.senderName)) {
            dto.senderName = 'Vous';
        }

        Object sent = fieldValue(row, selected, 'Date_Envoi__c');
        if (sent == null) {
            sent = fieldValue(row, selected, 'CreatedDate');
        }
        dto.sentAt =
            sent instanceof Datetime
                ? ((Datetime) sent).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
                : null;

        String statut = stringVal(fieldValue(row, selected, 'Statut_Lecture__c'));
        Object lu = fieldValue(row, selected, 'Lu__c');
        dto.isRead =
            (lu instanceof Boolean && (Boolean) lu) ||
            (statut != null && statut.equalsIgnoreCase('Lu'));

        applyDeliveryFromSync(
            dto,
            syncStatus,
            stringVal(fieldValue(row, selected, 'Erreur_Sync__c'))
        );
        return dto;
    }

    private static Boolean selectedContains(Set<String> selected, String api) {
        return selected != null && api != null && selected.contains(api);
    }

    private static Object fieldValue(SObject row, Set<String> selected, String api) {
        if (!selectedContains(selected, api)) {
            return null;
        }
        try {
            return row.get(api);
        } catch (Exception e) {
            return null;
        }
    }

    private static String resolveExpediteurDisplayName(SObject row, Set<String> selected) {
        String nom = stringVal(fieldValue(row, selected, 'Expediteur_Nom__c'));
        if (String.isNotBlank(nom)) {
            return nom;
        }
        return null;
    }

    private static void applyDeliveryFromSync(
        MissionMessageController.MessageDto dto,
        String syncStatus,
        String syncError
    ) {
        if (String.isNotBlank(syncStatus)) {
            dto.deliveryStatus = syncStatus.toUpperCase();
            if (SYNC_SYNCED.equalsIgnoreCase(syncStatus)) {
                dto.deliveredToGestionnaire = true;
                dto.deliveryError = null;
                return;
            }
            if (SYNC_PENDING.equalsIgnoreCase(syncStatus)) {
                dto.deliveredToGestionnaire = false;
                dto.deliveryError = String.isNotBlank(syncError)
                    ? syncError
                    : 'En attente de transmission au gestionnaire';
                return;
            }
            if (SYNC_FAILED.equalsIgnoreCase(syncStatus)) {
                dto.deliveredToGestionnaire = false;
                dto.deliveryError = String.isNotBlank(syncError)
                    ? syncError
                    : 'Échec de synchronisation avec le gestionnaire';
                return;
            }
        }
        dto.deliveredToGestionnaire = false;
        dto.deliveryStatus = 'LOCAL';
    }

    private static void putTagFields(SObject e, String tag) {
        List<String> fallbacks = TAG_FALLBACKS.get(tag);
        if (fieldExists('Tag_message__c')) {
            String tagMsg = resolvePicklistValue('Tag_message__c', tag, fallbacks);
            if (tagMsg != null) {
                e.put('Tag_message__c', tagMsg);
                return;
            }
        }
        if (fieldExists('Tag__c')) {
            String tagMulti = resolvePicklistValue('Tag__c', tag, fallbacks);
            if (tagMulti != null) {
                e.put('Tag__c', tagMulti);
            }
        }
    }

    private static String resolvePicklistValue(
        String fieldApi,
        String preferred,
        List<String> fallbacks
    ) {
        if (!fieldExists(fieldApi)) {
            return null;
        }
        Schema.DescribeFieldResult d = fieldMap().get(fieldApi).getDescribe();
        if (d.getType() != Schema.DisplayType.PICKLIST && d.getType() != Schema.DisplayType.MULTIPICKLIST) {
            return preferred;
        }
        Set<String> candidates = new Set<String>();
        if (String.isNotBlank(preferred)) {
            candidates.add(preferred);
        }
        if (fallbacks != null) {
            candidates.addAll(fallbacks);
        }
        for (String cand : candidates) {
            for (Schema.PicklistEntry pe : d.getPicklistValues()) {
                if (!pe.isActive()) {
                    continue;
                }
                if (pe.getValue().equalsIgnoreCase(cand) || pe.getLabel().equalsIgnoreCase(cand)) {
                    return pe.getValue();
                }
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

    private static String formatDml(DmlException dml) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < dml.getNumDml(); i++) {
            parts.add(dml.getDmlFieldNames(i) + ' : ' + dml.getDmlMessage(i));
        }
        return parts.isEmpty() ? dml.getMessage() : String.join(parts, ' | ');
    }

    private static String rootMessage(Exception e) {
        if (e == null) {
            return 'erreur inconnue';
        }
        return e.getMessage();
    }

    /** AuraHandledException uniquement en contexte LWC / VF — sinon MissionEchangeException (REST, etc.). */
    private static void throwServiceError(String message) {
        if (isAuraOrVisualforceContext()) {
            throw new AuraHandledException(message);
        }
        throw new MissionEchangeException(message);
    }

    private static Boolean isAuraOrVisualforceContext() {
        try {
            System.Quiddity q = System.Request.getCurrent().getQuiddity();
            return q == System.Quiddity.AURA || q == System.Quiddity.VF;
        } catch (Exception e) {
            return false;
        }
    }

    private static void insertRecord(SObject row) {
        Database.insert(row, AccessLevel.SYSTEM_MODE);
    }

    private static void updateRecord(SObject row) {
        Database.update(row, AccessLevel.SYSTEM_MODE);
    }

    private static List<SObject> runSoql(String soql) {
        return Database.query(soql, AccessLevel.SYSTEM_MODE);
    }

    private static List<SObject> runSoql(String soql, Map<String, Object> binds) {
        return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
    }

    private static Map<String, Schema.SObjectField> fieldMap() {
        return SObjectType.Echange__c.fields.getMap();
    }

    private static void putIfExists(SObject row, String field, Object value) {
        String resolved = resolveFieldApi(field);
        if (resolved != null) {
            row.put(resolved, value);
        }
    }

    /** Champs SOQL pour requêtes SYSTEM_MODE : présence dans le schéma uniquement (pas de filtre FLS). */
    private static void addSelectField(
        List<String> fields,
        Map<String, Schema.SObjectField> fMap,
        String api
    ) {
        if (fMap != null && String.isNotBlank(api) && fMap.containsKey(api) && !fields.contains(api)) {
            fields.add(api);
        }
    }

    private static Boolean fieldExists(String api) {
        return String.isNotBlank(api) && fieldMap().containsKey(api);
    }

    private static String resolveFieldApi(String api) {
        return fieldExists(api) ? api : null;
    }

    private static String stringVal(Object o) {
        return o == null ? null : String.valueOf(o);
    }
}
