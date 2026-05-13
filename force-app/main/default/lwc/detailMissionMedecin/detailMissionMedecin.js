import { LightningElement, api, wire, track } from 'lwc';
import getMissionDetails from '@salesforce/apex/MissionMedecinController.getMissionDetails';
import { CurrentPageReference } from 'lightning/navigation';

const TAB_DEFS = [
  { id: 'infos', label: 'Informations', icon: 'utility:info', badgeCount: 0 },
  { id: 'docs', label: 'Documents', icon: 'utility:attach', badgeCount: 2 },
  { id: 'msg', label: 'Messagerie', icon: 'utility:chat', badgeCount: 1 },
  { id: 'hon', label: 'Honoraires', icon: 'utility:moneybag', badgeCount: 0 },
  { id: 'hist', label: 'Historique', icon: 'utility:clock', badgeCount: 0 },
];

function fieldMapFromPayload(fields) {
  const m = {};
  (fields || []).forEach((f) => {
    const raw = f.apiName;
    if (!raw) return;
    m[raw] = f;
    const lower = raw.toLowerCase();
    if (!m[lower]) m[lower] = f;
  });
  return m;
}

function pickField(map, apiNames) {
  for (let i = 0; i < apiNames.length; i++) {
    const k = apiNames[i];
    const f = map[k] || map[(k || '').toLowerCase()];
    if (f != null && f.value !== undefined && f.value !== '') {
      return f.value;
    }
  }
  return null;
}

function isValidSalesforceId(id) {
  if (id == null || typeof id !== 'string') return false;
  const s = id.trim().replace(/[^a-zA-Z0-9]/g, '');
  return /^[a-zA-Z0-9]{15}$/.test(s) || /^[a-zA-Z0-9]{18}$/.test(s);
}

/**
 * LWR / navigation : missionId peut être un tableau, une string, ou un objet
 * (state Builder). Ne jamais envoyer un objet brut à Apex (→ « Apex request is invalid »).
 */
function unwrapMissionIdCandidate(raw) {
  if (raw == null) return undefined;
  let v = raw;
  if (Array.isArray(v)) {
    v = v.length ? v[0] : undefined;
  }
  if (v == null || v === '') return undefined;
  if (typeof v === 'object') {
    const inner = v.recordId ?? v.id ?? v.value ?? v.missionId ?? v.c__missionId;
    if (inner != null && inner !== v) {
      return unwrapMissionIdCandidate(inner);
    }
    return undefined;
  }
  return v;
}

/** LWR / query string : c__missionId peut être un tableau ou un type inattendu. */
function normalizeMissionIdParam(raw) {
  const v = unwrapMissionIdCandidate(raw);
  if (v == null || v === '') return undefined;
  const s = String(v).trim().replace(/[^a-zA-Z0-9]/g, '');
  return isValidSalesforceId(s) ? s : undefined;
}

function fmt(v) {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'boolean') return v ? 'Oui' : 'Non';
  return String(v);
}

/** Secours LWR : paramètres parfois absents de CurrentPageReference.state. */
function readMissionIdFromUrl() {
  const tryParse = (search) => {
    if (!search || search.length < 2) return undefined;
    const q = search.startsWith('?') ? search.slice(1) : search;
    let params;
    try {
      params = new URLSearchParams(q);
    } catch (e) {
      return undefined;
    }
    const keys = ['missionId', 'c__missionId', 'recordId', 'c__recordId'];
    for (let i = 0; i < keys.length; i++) {
      const n = normalizeMissionIdParam(params.get(keys[i]));
      if (n) return n;
    }
    return undefined;
  };
  let m = tryParse(typeof window !== 'undefined' ? window.location.search : '');
  if (m) return m;
  const hash = typeof window !== 'undefined' ? window.location.hash || '' : '';
  const qi = hash.indexOf('?');
  if (qi >= 0) {
    m = tryParse(hash.slice(qi));
  }
  return m;
}

export default class DetailMissionMedecin extends LightningElement {
  _missionId;
  _recordId;
  _loadSeq = 0;

  @api showBackButton = false;
  @api backLabel = 'Retour aux missions';

  @api
  get missionId() {
    return this._missionId;
  }
  set missionId(value) {
    const next = normalizeMissionIdParam(value);
    const prev = this._missionId;
    if (next === prev) {
      return;
    }
    this._missionId = next;

    if (!next) {
      this._resetEmptySelection();
      return;
    }
    this.isLoading = true;
    this.error = undefined;
    this.scheduleLoad();
  }

  /**
   * Support record pages / context record.
   * - On a Record Page, Experience/Lightning fournit souvent `recordId`.
   * - On privilégie `missionId` si déjà fourni explicitement.
   */
  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    const next = normalizeMissionIdParam(value);
    this._recordId = next;
    if (!this._missionId && next) {
      this.missionId = next;
    }
  }

  @track activeTab = 'infos';
  @track fields = [];
  @track missionTitle = '';
  @track subtitleText = '';
  @track badgeStatut = '';
  @track badgeBranche = '';
  @track badgeType = 'Médecin';
  @track summaryItems = [];
  @track leftCardFields = [];
  @track rightCardFields = [];

  error;
  isLoading = true;

  get hasMissionId() {
    return !!normalizeMissionIdParam(this._missionId);
  }

  connectedCallback() {
    if (!this._missionId) {
      const fromUrl = readMissionIdFromUrl();
      if (fromUrl) {
        this.missionId = fromUrl;
        return;
      }
    }
    if (normalizeMissionIdParam(this._missionId)) {
      this.scheduleLoad();
    } else {
      this.isLoading = false;
    }
  }

  @wire(CurrentPageReference)
  wiredPageRef(pageRef) {
    const state = pageRef?.state;
    const midRaw = state?.missionId || state?.c__missionId || state?.recordId || state?.c__recordId;
    const normalized = normalizeMissionIdParam(midRaw);
    if (normalized && normalized !== this._missionId) {
      this.missionId = normalized;
    }
  }

  scheduleLoad() {
    const seq = ++this._loadSeq;
    queueMicrotask(() => {
      if (seq !== this._loadSeq) {
        return;
      }
      this.loadMissionDetails();
    });
  }

  async loadMissionDetails() {
    const id = normalizeMissionIdParam(this._missionId);
    if (!id) {
      this.isLoading = false;
      return;
    }
    this.isLoading = true;
    this.error = undefined;
    try {
      const data = await getMissionDetails({ missionId: String(id) });
      this._applyMissionData(data);
      this.error = undefined;
    } catch (e) {
      this._handleLoadError(e);
    } finally {
      this.isLoading = false;
    }
  }

  _applyMissionData(data) {
    this.fields = data.fields || [];
    const map = fieldMapFromPayload(this.fields);
    const prestataireName = data.prestataireName != null ? String(data.prestataireName) : null;
    const prestataireSpecialite = data.prestataireSpecialite != null ? String(data.prestataireSpecialite) : null;
    const missionBranche = data.missionBranche != null ? String(data.missionBranche) : null;
    const missionNature = data.missionNature != null ? String(data.missionNature) : null;
    const typePrestataire = data.typePrestataire != null ? String(data.typePrestataire) : null;

    const titleRaw =
      pickField(map, [
        'Numero_mission__c',
        'Numero_Mission__c',
        'NUMERO_MISSION__C',
        'Numero_de_mission__c',
      ]) ?? data.missionName;
    this.missionTitle =
      titleRaw != null && String(titleRaw).trim() !== '' ? fmt(titleRaw) : 'Mission';

    const nat = fmt(missionNature ?? pickField(map, ['Nature_Mission__c']));
    const br = fmt(missionBranche ?? pickField(map, ['Branche__c']));
    if (nat !== '—' && br !== '—') this.subtitleText = `${nat} — ${br}`;
    else if (nat !== '—') this.subtitleText = nat;
    else if (br !== '—') this.subtitleText = br;
    else this.subtitleText = '';

    this.badgeStatut = fmt(pickField(map, ['Statut__c']));
    this.badgeBranche = fmt(missionBranche ?? pickField(map, ['Branche__c']));
    this.badgeType = typePrestataire && fmt(typePrestataire) !== '—' ? fmt(typePrestataire) : 'Médecin';

    const rawSummary = [
      { key: 'sum-prest', label: 'Prestataire', value: fmt(prestataireName), warn: false },
      { key: 'sum-type', label: 'Type', value: fmt(typePrestataire || 'Médecin'), warn: false },
      { key: 'sum-spec', label: 'Spécialité', value: fmt(prestataireSpecialite), warn: false },
      { key: 'sum-branch', label: 'Branche', value: fmt(missionBranche), warn: false },
      { key: 'sum-nature', label: 'Nature', value: fmt(missionNature), warn: false },
    ];
    this.summaryItems = rawSummary.map((row) => ({
      ...row,
      cellClass: row.warn ? 'dm-meta-cell dm-meta-cell--warn' : 'dm-meta-cell',
    }));

    const list = [...this.fields];
    const mid = Math.ceil(list.length / 2);
    this.leftCardFields = list.slice(0, mid).map((f) => ({
      key: f.apiName,
      label: f.label,
      value: fmt(f.value),
    }));
    this.rightCardFields = list.slice(mid).map((f) => ({
      key: f.apiName,
      label: f.label,
      value: fmt(f.value),
    }));
  }

  _handleLoadError(error) {
    // eslint-disable-next-line no-console
    console.error('[detailMissionMedecin] getMissionDetails', JSON.stringify(error));
    const body = error?.body;
    let raw =
      (typeof body?.message === 'string' && body.message) ||
      error?.message ||
      'Impossible de charger la mission (droits, field set ou réseau).';
    if (Array.isArray(body)) {
      raw = body.map((x) => x?.message || String(x)).join(' ') || raw;
    }
    const lower = String(raw).toLowerCase();
    const platformInvalid =
      raw === 'The Apex request is invalid.' || lower.includes('apex request is invalid');
    this.error = platformInvalid
      ? 'Identifiant de mission invalide ou requête refusée par le serveur. Rouvrez la mission depuis « Mes missions » ou rechargez la page.'
      : raw;
    this._clearPayload();
  }

  _resetEmptySelection() {
    this._loadSeq += 1;
    this.isLoading = false;
    this.error = undefined;
    this._clearPayload();
  }

  _clearPayload() {
    this.fields = [];
    this.leftCardFields = [];
    this.rightCardFields = [];
    this.summaryItems = [];
    this.missionTitle = '';
    this.subtitleText = '';
    this.badgeStatut = '';
    this.badgeBranche = '';
    this.badgeType = 'Médecin';
  }

  get hasLeftFields() {
    return (this.leftCardFields || []).length > 0;
  }

  get hasRightFields() {
    return (this.rightCardFields || []).length > 0;
  }

  get showStatutBadge() {
    return this.badgeStatut && this.badgeStatut !== '—';
  }

  get showBrancheBadge() {
    return this.badgeBranche && this.badgeBranche !== '—';
  }

  get tabsNav() {
    return TAB_DEFS.map((t) => ({
      ...t,
      key: t.id,
      isActive: this.activeTab === t.id,
      tabClass: `dm-tab${this.activeTab === t.id ? ' dm-tab--active' : ''}`,
      showBadge: (t.badgeCount || 0) > 0,
    }));
  }

  handleTabClick(event) {
    const id = event.currentTarget?.dataset?.id;
    if (id) this.activeTab = id;
  }

  handleBack() {
    this.dispatchEvent(new CustomEvent('back'));
  }

  get showInfos() {
    return this.activeTab === 'infos';
  }
  get showDocs() {
    return this.activeTab === 'docs';
  }
  get showMsg() {
    return this.activeTab === 'msg';
  }
  get showHon() {
    return this.activeTab === 'hon';
  }
  get showHist() {
    return this.activeTab === 'hist';
  }
}
