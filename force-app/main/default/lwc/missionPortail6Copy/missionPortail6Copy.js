import { LightningElement, wire, track, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';

import ACCOUNT_RT_FIELD from '@salesforce/schema/Account.RecordTypeId';
import MISSION_OBJECT from '@salesforce/schema/Mission__c';
import BRANCHE_FIELD from '@salesforce/schema/Mission__c.Branche__c';
import STATUT_FIELD from '@salesforce/schema/Mission__c.Statut__c';

import getMissions from '@salesforce/apex/MissionPortailController6Copy.getMissions';
import getMissionRecordTypeId from '@salesforce/apex/MissionPortailController6Copy.getMissionRecordTypeId';
import getStatutOptions from '@salesforce/apex/MissionPortailController6Copy.getStatutOptions';
import getBrancheOptions from '@salesforce/apex/MissionPortailController6Copy.getBrancheOptions';

/* ── UTILITAIRES ── */
function fmtDate(val) {
  if (!val) return '—';
  const [y, m, d] = val.split('-');
  return `${d}/${m}/${y}`;
}

function normalizeKey(str) {
  return (str || '').toLowerCase().replace(/[\s_\-]+/g, '');
}

const STATUT_LABELS = {
  Initiee: 'Initiée',
  En_cours: 'En cours',
  Rapport_recu: 'Rapport reçu',
  Rapport_attendu: 'Rapport attendu',
  Cloturee: 'Clôturée',
  Annulee: 'Annulée',
};

export default class MissionPortail6Copy extends NavigationMixin(LightningElement) {
  /* ── PROPS ── */
  // ✅ MODE ACCOUNT (Record Page) — ACTIF
  @api recordId;

  /* ── STATE ── */
  @track _missions = [];
  @track _enrichedList = [];
  @track statutOptions = [];
  @track brancheOptions = [];
  @track filterStatut = 'toutes';
  @track filterBranche = 'toutes';
  @track searchTerm = '';

  @track accountRecordTypeId = null;
  @track missionRecordTypeId = null;

  isLoading = true;
  hasError = false;

  /* ── ÉTAPE 1 : Récupérer le RecordTypeId du compte ── */
  // ✅ MODE ACCOUNT — wirer le recordId du compte
  @wire(getRecord, { recordId: '$recordId', fields: [ACCOUNT_RT_FIELD] })
  wiredAccount({ data }) {
    if (data) {
      this.accountRecordTypeId = getFieldValue(data, ACCOUNT_RT_FIELD);
      // eslint-disable-next-line no-console
      console.log('✅ RecordTypeId du compte:', this.accountRecordTypeId);
    }
  }

  /* ── ÉTAPE 2 : Convertir en RecordTypeId de Mission__c (via Apex) ── */
  @wire(getMissionRecordTypeId, { accountRecordTypeId: '$accountRecordTypeId' })
  wiredMissionRtId({ data, error }) {
    if (data) {
      this.missionRecordTypeId = data;
    } else if (error) {
      this.missionRecordTypeId = null;
    }
  }

  /* ── ÉTAPE 3a : Infos objet Mission__c ── */
  @wire(getObjectInfo, { objectApiName: MISSION_OBJECT })
  missionObjectInfo;

  /* ── ÉTAPE 3b : Picklist STATUT — chargé directement depuis Apex ── */
  @wire(getStatutOptions)
  wiredStatutOptions({ data }) {
    if (data && data.length > 0) {
      // eslint-disable-next-line no-console
      console.log('✅ Statuts Apex chargés:', data);
      this.statutOptions = data;
    } else {
      // eslint-disable-next-line no-console
      console.warn('⚠️  Statuts vides — sera construit à partir des missions');
      this._buildFallbackStatuts();
    }
  }

  /* ── ÉTAPE 3c : Picklist BRANCHE — chargé directement depuis Apex ── */
  @wire(getBrancheOptions)
  wiredBrancheOptions({ data }) {
    if (data && data.length > 0) {
      // eslint-disable-next-line no-console
      console.log('✅ Branches Apex chargées:', data);
      this.brancheOptions = data;
    } else {
      // eslint-disable-next-line no-console
      console.warn('⚠️  Branches vides — sera construit à partir des missions');
      this._buildFallbackBranches();
    }
  }

  /* ── ÉTAPE 4 : Missions ── */
  // ✅ MODE PORTAIL — Apex récupère lui-même l'utilisateur connecté
  @wire(getMissions)
  wiredMissions({ data, error }) {
    this.isLoading = false;
    if (data) {
      // eslint-disable-next-line no-console
      console.log('✅ Missions chargées:', data);
      this._missions = data;
      this._enrichedList = data.map((m) => this._enrich(m));
      this._buildFallbackStatuts();
      this._buildFallbackBranches();
      this.hasError = false;
    } else if (error) {
      // eslint-disable-next-line no-console
      console.error('❌ Erreur missions:', error);
      this.hasError = true;
      this._loadTestMissions();
    }
  }

  /* ── MODE TEST ── */
  connectedCallback() {
    // ✅ MODE PORTAIL — le wire gère tout, pas besoin de test ici
  }

  _loadTestMissions() {
    const testData = [
      { Id: '1', Numero_mission: 'MSN-2026-00053', Statut: 'En_cours', Branche: 'RC', Date_nomination: '2026-04-10' },
      { Id: '2', Numero_mission: 'MSN-2026-00048', Statut: 'Rapport_recu', Branche: 'AT', Date_nomination: '2026-03-01' },
      { Id: '3', Numero_mission: 'MSN-2026-00042', Statut: 'Cloturee', Branche: 'Autocorporel', Date_nomination: '2026-02-15' },
      { Id: '4', Numero_mission: 'MSN-2026-00056', Statut: 'En_cours', Branche: 'RC', Date_nomination: '2026-04-20' },
      { Id: '5', Numero_mission: 'MSN-2026-00060', Statut: 'Initiee', Branche: 'AT', Date_nomination: '2026-04-25' },
      { Id: '6', Numero_mission: 'MSN-2026-00035', Statut: 'Annulee', Branche: 'Autocorporel', Date_nomination: '2026-01-10' },
    ];
    // eslint-disable-next-line no-console
    console.warn('⚠️  Mode TEST activé — Aucune mission Apex trouvée');
    this._missions = testData;
    this._enrichedList = testData.map((m) => this._enrich(m));
    this.isLoading = false;
    this._buildFallbackStatuts();
    this._buildFallbackBranches();
  }

  /* ── FALLBACKS PICKLIST ── */
  _buildFallbackStatuts() {
    const vals = new Set(this._missions.map((m) => m.Statut).filter(Boolean));
    this.statutOptions = [{ label: 'Tout les statuts', value: 'toutes' }];
    vals.forEach((v) => this.statutOptions.push({ label: STATUT_LABELS[v] || v, value: v }));
  }

  _buildFallbackBranches() {
    const vals = new Set(this._missions.map((m) => m.Branche).filter(Boolean));
    this.brancheOptions = [{ label: 'Toutes les branches', value: 'toutes' }];
    vals.forEach((v) => this.brancheOptions.push({ label: v, value: v }));
  }

  /* ── ENRICHISSEMENT ── */
  _enrich(m) {
    const statutKey = normalizeKey(m.Statut);
    const brancheKey = normalizeKey(m.Branche);
    const displayStatut = STATUT_LABELS[m.Statut] || m.Statut || '—';

    return {
      ...m,
      _statutRaw: m.Statut,
      _brancheRaw: m.Branche,
      StatutLabel: displayStatut,
      dateNominationFmt: fmtDate(m.Date_nomination),
      statusBadgeClass: `badge badge-statut-${statutKey || 'default'}`,
      brancheBadgeClass: `badge badge-branche-${brancheKey || 'default'}`,
    };
  }

  /* ── MISSIONS FILTRÉES ── */
  get missionsAffichees() {
    let result = [...this._enrichedList];
    if (this.filterStatut !== 'toutes') {
      result = result.filter((m) => m._statutRaw === this.filterStatut);
    }
    if (this.filterBranche !== 'toutes') {
      result = result.filter((m) => m._brancheRaw === this.filterBranche);
    }
    if (this.searchTerm) {
      const term = this.searchTerm.toLowerCase();
      result = result.filter(
        (m) =>
          m.Numero_mission?.toLowerCase().includes(term) ||
          m.StatutLabel?.toLowerCase().includes(term) ||
          m.Branche?.toLowerCase().includes(term)
      );
    }
    return result;
  }

  get hasMissions() {
    return this.missionsAffichees.length > 0;
  }

  get totalCount() {
    return this._missions.length;
  }

  get pagiInfo() {
    return `${this.missionsAffichees.length} sur ${this.totalCount}`;
  }

  /* ── HANDLERS ── */
  handleNew() {
    // Placeholder
    // eslint-disable-next-line no-alert
    alert('Créer une nouvelle mission');
  }
  handleFilterStatut(evt) {
    this.filterStatut = evt.target.value;
  }
  handleFilterBranche(evt) {
    this.filterBranche = evt.target.value;
  }
  handleSearch(evt) {
    this.searchTerm = evt.target.value;
  }

  handleRowClick(evt) {
    const missionId = evt.currentTarget.dataset.id;
    this[NavigationMixin.Navigate]({
      type: 'standard__recordPage',
      attributes: { recordId: missionId, actionName: 'view' },
    });
  }
}

