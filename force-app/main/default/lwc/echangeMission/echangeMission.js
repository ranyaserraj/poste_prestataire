import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMessages from '@salesforce/apex/MissionMessageController.getMessages';
import sendMessage from '@salesforce/apex/MissionMessageController.sendMessage';
import syncPendingOutbound from '@salesforce/apex/MissionMessageController.syncPendingOutbound';
import markMessageRead from '@salesforce/apex/MissionMessageController.markMessageRead';

const TAG_DEFS = [
  { label: 'Question technique', value: 'QUESTION_TECHNIQUE' },
  { label: 'Demande de pièces', value: 'DEMANDE_PIECES' },
  { label: 'Information', value: 'INFORMATION' },
];

const TAG_LABEL_BY_VALUE = Object.fromEntries(TAG_DEFS.map((t) => [t.value, t.label]));

/** Rafraîchissement automatique des messages gestionnaire (sans recharger la page). */
const INBOUND_POLL_MS = 12000;

function normalizeSfId(val) {
  if (val == null || val === '') return '';
  const s = String(val).trim();
  return /^[a-zA-Z0-9]{15,18}$/.test(s) ? s : '';
}

function isSalesforceRecordId(val) {
  if (val == null || val === '') return false;
  return /^[a-zA-Z0-9]{15,18}$/.test(String(val).trim());
}

function fmtDate(iso) {
  if (!iso) return '—';
  try {
    const d = new Date(iso);
    return d.toLocaleDateString('fr-FR', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return iso;
  }
}

function fmtDateTimeAbove(iso) {
  if (!iso) return '';
  try {
    const d = new Date(iso);
    const datePart = d.toLocaleDateString('fr-FR', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
    });
    const timePart = d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    return `${datePart}, ${timePart}`;
  } catch {
    return '';
  }
}

export default class EchangeMission extends LightningElement {
  @api embedded = false;

  @track _messages = [];
  @track _selectedTag = TAG_DEFS[0].value;
  @track _draft = '';
  @track _isSending = false;
  @track _error = '';
  /** Ids Echange__c en cours de renvoi manuel (syncPendingOutbound). */
  @track _retryingExchangeIds = {};

  _recordId;
  _missionId;
  _loadedForId;
  _loadSeq = 0;
  _sendMissionId;
  _pollTimerId = null;
  _lastThreadKey = '';

  @api
  get missionId() {
    return this._missionId;
  }
  set missionId(val) {
    this._applyMissionContext(normalizeSfId(val));
  }

  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(val) {
    this._applyMissionContext(normalizeSfId(val));
  }

  get _activeMissionId() {
    return normalizeSfId(this._missionId) || normalizeSfId(this._recordId);
  }

  _applyMissionContext(next) {
    if (!next || next === this._missionId) {
      return;
    }
    if (this._isSending) {
      return;
    }
    this._missionId = next;
    this._recordId = next;
    this._messages = [];
    this._error = '';
    this._loadedForId = null;
    this._lastThreadKey = '';
    this._loadSeq += 1;
    this._stopInboundPoll();
    this.loadThread();
    this._startInboundPoll();
  }

  connectedCallback() {
    const mid = this._activeMissionId;
    if (mid && this._loadedForId !== mid) {
      this.loadThread();
    }
    this._startInboundPoll();
  }

  disconnectedCallback() {
    this._stopInboundPoll();
  }

  get chatClass() {
    return this.embedded ? 'chat chat--embedded' : 'chat';
  }

  get tags() {
    return TAG_DEFS.map((t) => ({
      ...t,
      key: t.value,
      className: `tag${this._selectedTag === t.value ? ' tag--active' : ''}`,
      ariaPressed: this._selectedTag === t.value ? 'true' : 'false',
    }));
  }

  get thread() {
    return this._messages;
  }

  get hasThread() {
    return this._messages.length > 0;
  }

  get isSending() {
    return this._isSending;
  }

  get hasError() {
    return !!this._error;
  }

  get errorMessage() {
    return this._error;
  }

  get draft() {
    return this._draft;
  }

  get canSend() {
    return (
      !this._isSending &&
      !!this._selectedTag &&
      !!String(this._draft || '').trim() &&
      !!this._activeMissionId
    );
  }

  get sendDisabled() {
    return this._isSending || !this.canSend;
  }

  get hasSelectedTag() {
    return !!this._selectedTag;
  }

  _startInboundPoll() {
    this._stopInboundPoll();
    const mid = this._activeMissionId;
    if (!mid) {
      return;
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._pollTimerId = window.setInterval(() => {
      if (this._isSending || document.hidden) {
        return;
      }
      this.loadThread({ silent: true });
    }, INBOUND_POLL_MS);
  }

  _stopInboundPoll() {
    if (this._pollTimerId != null) {
      window.clearInterval(this._pollTimerId);
      this._pollTimerId = null;
    }
  }

  _threadKey(rows) {
    if (!rows || !rows.length) {
      return '0';
    }
    const last = rows[rows.length - 1];
    return `${rows.length}|${last.id}|${last.sentAtRaw || ''}`;
  }

  async loadThread(options = {}) {
    const silent = options?.silent === true;
    const scrollToRecent = options?.scrollToRecent !== false;
    const mid = this._activeMissionId;
    if (!mid) {
      this._messages = [];
      return;
    }
    const seq = ++this._loadSeq;
    if (!silent) {
      this._error = '';
    }
    try {
      const rows = await getMessages({ missionId: mid });
      if (seq !== this._loadSeq) {
        return;
      }
      let mapped = (rows || []).map((m, idx) => this._mapRow(m, { rowIndex: idx }));
      mapped = this._sortMapped(mapped);
      const prevKey = this._lastThreadKey;
      const nextKey = this._threadKey(mapped);
      const hasNewMessages = nextKey !== prevKey;

      this._messages = mapped;
      this._loadedForId = mid;
      this._lastThreadKey = nextKey;

      if (scrollToRecent && (hasNewMessages || !silent)) {
        this._scrollToBottom();
      }
      await this._markUnreadAsRead();
    } catch (e) {
      if (seq !== this._loadSeq) {
        return;
      }
      if (!silent) {
        this._messages = [];
        this._error = this._errMsg(e);
      }
    }
  }

  async _markUnreadAsRead() {
    const unread = this._messages.filter((m) => m.unread && m.apiId != null);
    for (const m of unread) {
      try {
        await markMessageRead({
          missionId: this._activeMissionId,
          messageId: m.apiId,
          echangeRecordId: m.sfExchangeId || null,
        });
        m.unread = false;
        m.showUnreadDot = false;
      } catch {
        /* non bloquant */
      }
    }
    if (unread.length) {
      this._messages = [...this._messages];
    }
  }

  _tagLabel(tagValue) {
    if (!tagValue) return '';
    const key = String(tagValue).trim();
    if (TAG_LABEL_BY_VALUE[key]) {
      return TAG_LABEL_BY_VALUE[key];
    }
    const upper = key.toUpperCase();
    if (TAG_LABEL_BY_VALUE[upper]) {
      return TAG_LABEL_BY_VALUE[upper];
    }
    if (TAG_DEFS.some((t) => t.value === key || t.label === key)) {
      return TAG_LABEL_BY_VALUE[key] || key;
    }
    return '';
  }

  _buildOptimisticRow(text, tag, pendingId) {
    const now = new Date().toISOString();
    const tagLabel = this._tagLabel(tag);
    const status = this._deliveryStatus(true, false, null, true);
    return {
      id: pendingId,
      apiId: null,
      sfExchangeId: null,
      side: 'right',
      bubbleClass: 'msg msg--right msg--mine msg--pending',
      text,
      tagLabel,
      hasTag: !!tagLabel,
      showSender: false,
      senderLabel: '',
      dateTimeLabel: fmtDateTimeAbove(now),
      dateMetaClass: 'msg-datetime msg-datetime--right',
      ...status,
      sentAtRaw: now,
      isPending: true,
      showManualRetry: true,
      retryKey: `mission-${this._activeMissionId || 'optimistic'}`,
      isRetrying: false,
      manualRetryTitle: 'Renvoyer au gestionnaire',
      resendButtonClass: 'btn-msg-resend',
    };
  }

  _deliveryStatus(mine, delivered, isRead, pending) {
    if (!mine) {
      return {
        showStatus: false,
        statusClass: '',
        statusLabel: '',
        statusTitle: '',
        showDeliveryWarning: false,
        deliveryTitle: '',
      };
    }
    if (pending) {
      return {
        showStatus: true,
        statusClass: 'msg-status msg-status--pending',
        statusLabel: '◷',
        statusTitle: 'Envoi en cours — ↻ pour renvoyer manuellement',
        showDeliveryWarning: false,
        deliveryTitle: '',
      };
    }
    if (delivered === false) {
      return {
        showStatus: false,
        statusClass: 'msg-status msg-status--warn',
        statusLabel: '',
        statusTitle: '',
        showDeliveryWarning: true,
        deliveryTitle: 'Non transmis au gestionnaire — utilisez ↻ pour renvoyer',
      };
    }
    if (isRead === true) {
      return {
        showStatus: true,
        statusClass: 'msg-status msg-status--read',
        statusLabel: '✓✓',
        statusTitle: 'Lu par le gestionnaire',
        showDeliveryWarning: false,
        deliveryTitle: '',
      };
    }
    return {
      showStatus: true,
      statusClass: 'msg-status msg-status--sent',
      statusLabel: '✓',
      statusTitle: 'Envoyé',
      showDeliveryWarning: false,
      deliveryTitle: '',
    };
  }

  _mapRow(m, options = {}) {
    const optimistic = options?.pending === true || m?.isPending === true;
    const syncPending =
      optimistic ||
      (m?.isMine === true &&
        String(m?.deliveryStatus || '').toUpperCase() === 'PENDING');
    const mine = optimistic || m?.isMine === true;
    const unread = !syncPending && !mine && m.isRead === false;
    const deliveredFlag = syncPending ? null : m.deliveredToGestionnaire;
    const side = mine ? 'right' : 'left';
    const sentAtRaw = m.sentAt;
    const author = mine ? '' : m.senderName || 'Gestionnaire';
    const tagLabel = this._tagLabel(m.tag);
    const status = this._deliveryStatus(mine, deliveredFlag, m.isRead, syncPending);
    const deliveryStatusNorm = String(m?.deliveryStatus || '').toUpperCase();
    const syncFailed =
      mine &&
      !syncPending &&
      deliveredFlag === false &&
      deliveryStatusNorm === 'FAILED';
    const notDelivered = syncFailed;
    const sfExchangeId =
      (isSalesforceRecordId(m.sfExchangeId) && m.sfExchangeId) ||
      (isSalesforceRecordId(m.id) && String(m.id)) ||
      null;
    const needsResend =
      syncPending ||
      syncFailed ||
      notDelivered ||
      deliveryStatusNorm === 'FAILED' ||
      deliveryStatusNorm === 'PENDING' ||
      (mine && m.deliveredToGestionnaire === false && deliveryStatusNorm !== 'SYNCED');
    const showManualRetry = mine && needsResend;
    const retryKey = sfExchangeId || (showManualRetry ? `mission-${this._activeMissionId || 'all'}` : null);
    const isRetrying = !!(retryKey && this._retryingExchangeIds[retryKey]);
    const rowIndex = options?.rowIndex != null ? options.rowIndex : 0;

    const rowKey =
      m.sfExchangeId ||
      (m.id != null
        ? `api-${m.id}-${side}`
        : `row-${rowIndex}-${side}-${sentAtRaw || ''}-${(m.content || '').slice(0, 24)}`);
    return {
      id: String(rowKey),
      apiId: m.id,
      sfExchangeId,
      side,
      bubbleClass: `msg msg--${side}${mine ? ' msg--mine' : ''}${notDelivered ? ' msg--not-delivered' : ''}`,
      text: m.content || '',
      tagLabel,
      hasTag: !!tagLabel,
      showSender: !mine,
      senderLabel: author,
      dateTimeLabel: fmtDateTimeAbove(sentAtRaw),
      dateMetaClass: `msg-datetime msg-datetime--${side}`,
      showUnreadDot: unread,
      unreadTitle: 'Non lu',
      ...status,
      sentAtRaw,
      isPending: syncPending,
      showManualRetry,
      retryKey,
      isRetrying,
      manualRetryTitle: isRetrying ? 'Renvoi en cours…' : 'Renvoyer au gestionnaire',
      resendButtonClass: `btn-msg-resend${isRetrying ? ' btn-msg-resend--busy' : ''}`,
    };
  }

  handleTagClick(event) {
    event.preventDefault();
    event.stopPropagation();
    const btn = event.currentTarget;
    const value = btn?.dataset?.value || btn?.getAttribute?.('data-value');
    if (value) {
      this._selectedTag = value;
    }
  }

  handleDraftChange(event) {
    this._draft = event.target.value;
  }

  handleSendClick() {
    if (!this._selectedTag) {
      this._toast('Tag requis', 'Choisissez un tag avant d\'envoyer.', 'warning');
      return;
    }
    if (!String(this._draft || '').trim()) {
      this._toast('Message vide', 'Saisissez un message avant d\'envoyer.', 'warning');
      return;
    }
    this.handleSend();
  }

  async handleSend() {
    if (this._isSending) {
      return;
    }
    const mid = this._activeMissionId;
    if (!this.canSend || !mid) {
      return;
    }
    const text = String(this._draft || '').trim();
    const tag = this._selectedTag;
    const pendingId = `pending-${Date.now()}`;
    this._draft = '';
    this._messages = [...this._messages, this._buildOptimisticRow(text, tag, pendingId)];
    this._scrollToBottom();
    this._isSending = true;
    this._sendMissionId = mid;
    this._error = '';
    try {
      const sent = await sendMessage({
        missionId: this._sendMissionId,
        content: text,
        tag,
      });
      if (sent) {
        const withoutPending = this._messages.filter((m) => m.id !== pendingId);
        this._messages = this._sortMapped([...withoutPending, this._mapRow(sent)]);
        this._scrollToBottom();
      }
      if (sent?.sfExchangeId && sent?.deliveredToGestionnaire !== true) {
        try {
          await syncPendingOutbound({
            missionId: this._sendMissionId,
            echangeRecordId: sent.sfExchangeId,
          });
        } catch (syncErr) {
          // eslint-disable-next-line no-console
          console.warn('[echangeMission] syncPendingOutbound', syncErr);
        }
      }
      try {
        await this.loadThread({ silent: true, scrollToRecent: true });
        this._ensureSentVisible(sent, pendingId);
        await this._pollThreadUntilSynced(sent?.sfExchangeId, 4);
      } catch (loadErr) {
        const withoutPending = this._messages.filter((m) => m.id !== pendingId);
        let fallback = withoutPending;
        if (sent) {
          fallback = this._sortMapped([...withoutPending, this._mapRow(sent)]);
        }
        this._messages = fallback;
        this._scrollToBottom();
        // eslint-disable-next-line no-console
        console.warn('[echangeMission] loadThread après envoi', loadErr);
      }
      this._scrollToBottom();
      this.dispatchEvent(new CustomEvent('messagesent'));
      if (sent?.deliveredToGestionnaire === false) {
        this._toast(
          'Non transmis au gestionnaire',
          sent?.deliveryError ||
            'Message enregistré sur le portail uniquement. Vérifiez la synchronisation de la mission (numeroMission).',
          'warning'
        );
      }
    } catch (e) {
      this._messages = this._messages.filter((m) => m.id !== pendingId);
      this._error = this._errMsg(e);
      this._toast('Envoi impossible', this._error, 'error');
    } finally {
      this._isSending = false;
      this._sendMissionId = null;
    }
  }

  handleRefresh() {
    this.loadThread({ scrollToRecent: true });
  }

  async handleManualResync(event) {
    event.preventDefault();
    event.stopPropagation();
    const sfIdRaw = event.currentTarget?.dataset?.sfExchangeId;
    const sfId = isSalesforceRecordId(sfIdRaw) ? sfIdRaw : null;
    const retryKey =
      event.currentTarget?.dataset?.retryKey ||
      sfId ||
      `mission-${this._activeMissionId || 'all'}`;
    const mid = this._activeMissionId;
    if (!mid || this._retryingExchangeIds[retryKey]) {
      return;
    }

    this._retryingExchangeIds = { ...this._retryingExchangeIds, [retryKey]: true };
    this._refreshRetryFlagsOnRows();

    try {
      const updated = await syncPendingOutbound({
        missionId: mid,
        echangeRecordId: sfId,
      });

      if (updated && sfId) {
        this._messages = this._sortMapped(
          this._messages.map((row) =>
            row.sfExchangeId === sfId ? this._mapRow(updated) : row
          )
        );
      } else {
        await this.loadThread({ silent: true, scrollToRecent: true });
      }

      const row = sfId
        ? this._messages.find((r) => r.sfExchangeId === sfId)
        : null;
      const delivered =
        updated?.deliveredToGestionnaire === true ||
        (row && !row.isPending && row.showDeliveryWarning !== true);

      if (delivered) {
        this._toast('Message transmis', 'Le gestionnaire a reçu votre message.', 'success');
      } else {
        this._toast(
          'Non transmis',
          updated?.deliveryError ||
            row?.deliveryTitle ||
            'L\'API gestionnaire est indisponible. Réessayez plus tard ou attendez le renvoi automatique.',
          'warning'
        );
      }
    } catch (e) {
      this._toast('Renvoi impossible', this._errMsg(e), 'error');
      try {
        await this.loadThread({ silent: true, scrollToRecent: true });
      } catch {
        /* ignore */
      }
    } finally {
      const next = { ...this._retryingExchangeIds };
      delete next[retryKey];
      this._retryingExchangeIds = next;
      this._refreshRetryFlagsOnRows();
    }
  }

  _refreshRetryFlagsOnRows() {
    this._messages = this._messages.map((row) => {
      if (!row.showManualRetry) {
        return row;
      }
      const key =
        row.retryKey ||
        row.sfExchangeId ||
        `mission-${this._activeMissionId || 'all'}`;
      const isRetrying = !!this._retryingExchangeIds[key];
      return {
        ...row,
        retryKey: key,
        isRetrying,
        manualRetryTitle: isRetrying ? 'Renvoi en cours…' : 'Renvoyer au gestionnaire',
        resendButtonClass: `btn-msg-resend${isRetrying ? ' btn-msg-resend--busy' : ''}`,
      };
    });
  }

  _toast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant,
      })
    );
  }

  _sortMapped(rows) {
    return [...rows].sort((a, b) => {
      const ta = a.sentAtRaw ? new Date(a.sentAtRaw).getTime() : 0;
      const tb = b.sentAtRaw ? new Date(b.sentAtRaw).getTime() : 0;
      if (ta !== tb) {
        return ta - tb;
      }
      return String(a.id).localeCompare(String(b.id));
    });
  }

  _ensureSentVisible(sent, pendingId) {
    if (!sent?.sfExchangeId) {
      return;
    }
    const withoutPending = this._messages.filter((m) => m.id !== pendingId);
    const exists = withoutPending.some((m) => m.sfExchangeId === sent.sfExchangeId);
    if (!exists) {
      this._messages = this._sortMapped([...withoutPending, this._mapRow(sent)]);
    }
  }

  /** Toujours afficher les messages les plus récents (bas du fil). */
  _scrollToBottom() {
    const run = () => {
      const thread = this.template?.querySelector?.('.thread');
      if (thread) {
        thread.scrollTop = thread.scrollHeight;
      }
    };
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    requestAnimationFrame(run);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    window.setTimeout(run, 0);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    window.setTimeout(run, 80);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    window.setTimeout(run, 200);
  }

  async _pollThreadUntilSynced(sfExchangeId, maxAttempts = 4) {
    if (!sfExchangeId || !this._activeMissionId) {
      return;
    }
    for (let i = 0; i < maxAttempts; i += 1) {
      const row = this._messages.find((m) => m.sfExchangeId === sfExchangeId);
      if (!row || row.isPending !== true) {
        return;
      }
      await new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(resolve, 1500);
      });
      try {
        await this.loadThread({ silent: true, scrollToRecent: true });
      } catch {
        return;
      }
    }
  }

  _errMsg(e) {
    const messages = [];
    const push = (m) => {
      if (m && String(m).trim() && !messages.includes(String(m).trim())) {
        messages.push(String(m).trim());
      }
    };

    if (!e) {
      return 'Erreur inconnue';
    }

    const body = e.body ?? e;
    if (typeof body?.message === 'string') {
      push(body.message);
    }
    if (Array.isArray(body)) {
      body.forEach((item) => push(item?.message));
    }
    if (body?.output?.errors) {
      body.output.errors.forEach((item) => push(item?.message));
    }
    if (body?.output?.fieldErrors) {
      Object.keys(body.output.fieldErrors).forEach((field) => {
        const errs = body.output.fieldErrors[field];
        if (Array.isArray(errs)) {
          errs.forEach((item) => push(`${field}: ${item?.message || item}`));
        }
      });
    }
    if (body?.fieldErrors) {
      Object.keys(body.fieldErrors).forEach((field) => {
        const errs = body.fieldErrors[field];
        if (Array.isArray(errs)) {
          errs.forEach((item) => push(`${field}: ${item?.message || item}`));
        }
      });
    }
    push(e.message);
    push(e.statusText);

    return messages.length ? messages.join(' — ') : 'Erreur inconnue';
  }
}
