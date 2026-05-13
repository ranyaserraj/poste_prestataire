import { LightningElement, api, track } from 'lwc';
import { createRecord, getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import userId from '@salesforce/user/Id';
import { wire } from 'lwc';
import { getObjectInfo, getPicklistValuesByRecordType } from 'lightning/uiObjectInfoApi';
import USER_CONTACT_ID from '@salesforce/schema/User.ContactId';
import CONTACT_ACCOUNT_ID from '@salesforce/schema/Contact.AccountId';
import MISSION_OBJECT_SCHEMA from '@salesforce/schema/Mission__c';
import ACCOUNT_OBJECT from '@salesforce/schema/Account';
import ACCOUNT_BRANCHES from '@salesforce/schema/Account.Branches__c';
import ACCOUNT_RECORD_TYPE_ID from '@salesforce/schema/Account.RecordTypeId';
import getGateInfo from '@salesforce/apex/MissionCreateMedecinGateControllerCopy.getGateInfo';

const MISSION_OBJECT = 'Mission__c';

function stripDiacritics(s) {
  return String(s || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim();
}

function normalizeLdsErrors(err) {
  // Inspired by LDS error shapes (pageErrors, fieldErrors, output.errors, etc.)
  const messages = [];

  const pushMsg = (m) => {
    if (!m) return;
    const s = String(m).trim();
    if (s && !messages.includes(s)) messages.push(s);
  };

  if (!err) return ['Une erreur est survenue.'];

  // UI API / LDS often returns { body: { message, output: { errors, fieldErrors } } }
  const body = err.body ?? err;

  if (Array.isArray(body)) {
    body.forEach((e) => pushMsg(e?.message));
  } else {
    pushMsg(body?.message);
    pushMsg(err?.message);

    const output = body?.output;
    const pageErrors = output?.errors || body?.pageErrors;
    if (Array.isArray(pageErrors)) {
      pageErrors.forEach((e) => pushMsg(e?.message));
    }

    const fieldErrors = output?.fieldErrors || body?.fieldErrors;
    if (fieldErrors && typeof fieldErrors === 'object') {
      Object.values(fieldErrors).forEach((arr) => {
        if (Array.isArray(arr)) arr.forEach((e) => pushMsg(e?.message));
      });
    }
  }

  return messages.length ? messages : ['Une erreur est survenue.'];
}

/** Valeur Time pour createRecord : accepte HH:mm, ms depuis minuit (bug), ou fragment ISO. */
function normalizeTimeForCreate(value) {
  if (value == null || value === '') return undefined;
  const s = String(value).trim();
  if (!s) return undefined;
  if (/^\d+$/.test(s)) {
    const n = Number(s);
    if (!Number.isFinite(n) || n < 0) return undefined;
    const msInDay = 24 * 60 * 60 * 1000;
    const ms = n % msInDay;
    const totalSec = Math.floor(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const sec = totalSec % 60;
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}.000`;
  }
  if (s.includes('T')) {
    const afterT = s.split('T')[1] || '';
    const hms = afterT.split('.')[0];
    if (hms && /^\d{2}:\d{2}/.test(hms)) {
      const parts = hms.split(':');
      const hh = (parts[0] || '00').padStart(2, '0');
      const mm = (parts[1] || '00').padStart(2, '0');
      const ss = (parts[2] || '00').split('.')[0].padStart(2, '0');
      return `${hh}:${mm}:${ss}.000`;
    }
  }
  if (/^\d{1,2}:\d{2}(:\d{2})?/.test(s)) {
    const parts = s.split(':');
    if (parts.length === 2) {
      return `${parts[0].padStart(2, '0')}:${parts[1]}:00.000`;
    }
    if (parts.length >= 3) {
      const ss = (parts[2] || '00').split('.')[0];
      return `${parts[0].padStart(2, '0')}:${parts[1]}:${ss.padStart(2, '0')}.000`;
    }
  }
  return s;
}

export default class MissionCreateMedecinModalEmbed extends LightningElement {
  @track isOpen = false;
  @track isSaving = false;
  @track errorMessage = '';

  // Wizard
  @track currentStep = 1;
  @track errors = {};

  // Info step includes Branche + Nature + fields
  @track branche = '';

  // Step 2: Informations
  @track nature = '';
  @track numeroPolice = '';
  @track dateNomination = '';
  @track dateSurvenance = '';
  @track typeSinistre = '';
  @track numeroSinistre = '';
  @track referenceDossier = '';
  @track sinistreNonOuvert = false;
  @track heureDebut = '';
  @track heureFin = '';
  @track nombreDossiers = '';
  @track nomSociete = '';

  // Step 3: Personnes impliquées
  @track persons = [];
  @track personType = '';
  @track civilite = '';
  @track nom = '';
  @track prenom = '';
  @track dateNaissance = '';
  @track etatSante = '';

  @track prestataireAccountId = null;
  @track contactId = null;
  @track missionRecordTypeId = null;
  @track picklistByRt = null;

  /** Compte prestataire (Contact.AccountId) */
  @track accountBranchesRaw = '';
  @track accountRecordTypeId = null;
  @track accountObjectInfo = null;
  @track accountRecordTypeDevNameApex = null;

  get branchesAgreesTokens() {
    if (!this.accountBranchesRaw) return [];
    return String(this.accountBranchesRaw)
      .split(';')
      .map((t) => t.trim())
      .filter(Boolean);
  }

  get isMedecinAccount() {
    if (!this.accountObjectInfo || !this.accountRecordTypeId) return false;
    const infos = this.accountObjectInfo.recordTypeInfos || {};
    const rt = Object.values(infos).find((i) => i?.recordTypeId === this.accountRecordTypeId);
    const dn = (rt?.developerName || '').toLowerCase();
    return dn === 'medecin' || dn.includes('medecin');
  }

  get isMedecinAccountApex() {
    const d = (this.accountRecordTypeDevNameApex || '').trim();
    if (!d) return false;
    const lower = d.toLowerCase();
    return lower === 'medecin' || lower.includes('medecin');
  }

  /** Soumission réservée aux comptes Médecin (branches filtrées côté Apex / compte). */
  get canCreateMission() {
    // Prefer Apex-derived devName (more reliable with Community FLS),
    // fallback to LDS recordTypeId->devName mapping when available.
    const rtOk = this.accountRecordTypeDevNameApex ? this.isMedecinAccountApex : this.isMedecinAccount;
    return !!this.prestataireAccountId && rtOk;
  }

  /** Branches mission = intersection picklist Mission__c.Branche__c et Account.Branches__c */
  computeBrancheOptionsList() {
    const allValues = this.picklistByRt?.picklistFieldValues?.Branche__c?.values;
    if (!Array.isArray(allValues)) return [];

    const tokens = this.branchesAgreesTokens;

    // Debug logs (embed)
    // eslint-disable-next-line no-console
    console.log('branchesAgreesTokens:', JSON.stringify(tokens));
    // eslint-disable-next-line no-console
    console.log('allValues picklist:', JSON.stringify(allValues.map((v) => v.value)));

    if (!tokens || tokens.length === 0) return [];

    const filtered = allValues.filter((v) =>
      tokens.some((t) => {
        const tt = String(t || '').toLowerCase();
        const vv = String(v?.value || '').toLowerCase();
        const ll = String(v?.label || '').toLowerCase();
        return tt === vv || tt === ll;
      })
    );

    // eslint-disable-next-line no-console
    console.log('filtered branches:', JSON.stringify(filtered.map((v) => v.value)));

    return filtered.map((v) => ({ label: v.label, value: v.value }));
  }

  get brancheOptions() {
    return this.computeBrancheOptionsList();
  }

  get isBrancheLocked() {
    return this.brancheOptions.length === 1;
  }

  syncBrancheFromAccount() {
    const options = this.computeBrancheOptionsList();

    // eslint-disable-next-line no-console
    console.log('syncBrancheFromAccount options:', JSON.stringify(options));

    // Si 1 seule branche autorisée → pré-sélectionner automatiquement
    if (options.length === 1 && !this.branche) {
      this.branche = options[0].value;
    }
  }

  get isSante() {
    return stripDiacritics(this.branche) === 'sante';
  }

  get isAT() {
    return stripDiacritics(this.branche) === 'at';
  }

  @wire(getObjectInfo, { objectApiName: MISSION_OBJECT_SCHEMA })
  wiredMissionInfo({ data, error }) {
    if (error) {
      // eslint-disable-next-line no-console
      console.error('wiredMissionInfo error:', JSON.stringify(error));
      return;
    }
    if (!data) return;
    const rts = data.recordTypeInfos || {};
    // eslint-disable-next-line no-console
    console.log(
      'Record Types disponibles:',
      JSON.stringify(Object.values(rts).map((rt) => ({ name: rt.name, id: rt.recordTypeId })))
    );
    const med = Object.values(rts).find((rt) => {
      const dn = (rt?.developerName || '').toLowerCase();
      return dn === 'medecin' || dn.includes('medecin');
    });
    this.missionRecordTypeId = med?.recordTypeId || data.defaultRecordTypeId;
    // eslint-disable-next-line no-console
    console.log('missionRecordTypeId:', this.missionRecordTypeId);
  }

  @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
  wiredAccountObjectInfo({ data }) {
    this.accountObjectInfo = data || null;
    this.syncBrancheFromAccount();
  }

  @wire(getGateInfo)
  wiredGateInfo({ data }) {
    if (!data) return;
    // eslint-disable-next-line no-console
    console.warn('[medecinNouvellesMission-embed] gateInfo raw:', JSON.stringify(data));
    // Always trust the server for account linkage + record type dev name + branches
    this.prestataireAccountId = data.accountId || this.prestataireAccountId || null;
    this.accountRecordTypeDevNameApex = data.accountRecordTypeDeveloperName || null;
    // Only override branches if Apex returned something (string or null)
    this.accountBranchesRaw = data.branches ?? this.accountBranchesRaw;
    // eslint-disable-next-line no-console
    console.warn('[medecinNouvellesMission-embed] branches raw:', this.accountBranchesRaw);
    this.syncBrancheFromAccount();
  }

  @wire(getRecord, { recordId: '$prestataireAccountId', fields: [ACCOUNT_BRANCHES, ACCOUNT_RECORD_TYPE_ID] })
  wiredAccountRecord({ data }) {
    if (!this.prestataireAccountId) {
      this.accountBranchesRaw = '';
      this.accountRecordTypeId = null;
      return;
    }
    if (!data) return;
    // In Experience Cloud, LDS can return undefined for fields lacking FLS.
    // Don't overwrite Apex-derived values with blanks.
    const ldsBranches = getFieldValue(data, ACCOUNT_BRANCHES);
    if (ldsBranches !== undefined && ldsBranches !== null) {
      this.accountBranchesRaw = ldsBranches || '';
    }
    const ldsRtId = getFieldValue(data, ACCOUNT_RECORD_TYPE_ID);
    if (ldsRtId !== undefined && ldsRtId !== null) {
      this.accountRecordTypeId = ldsRtId || null;
    }
    this.syncBrancheFromAccount();
  }

  @wire(getPicklistValuesByRecordType, {
    objectApiName: MISSION_OBJECT_SCHEMA,
    recordTypeId: '$missionRecordTypeId',
  })
  wiredPicklists({ data, error }) {
    if (error) {
      // eslint-disable-next-line no-console
      console.error('wiredPicklists error:', JSON.stringify(error));
      return;
    }
    if (data) {
      // eslint-disable-next-line no-console
      console.log('picklist loaded successfully');
      // eslint-disable-next-line no-console
      console.log(
        'Branche values:',
        JSON.stringify(data.picklistFieldValues?.Branche__c?.values?.map((v) => v.value))
      );
      this.picklistByRt = data;
      // Appelle syncBrancheFromAccount maintenant que la picklist EST chargée
      this.syncBrancheFromAccount();
    }
  }

  get natureOptions() {
    const values = this.picklistByRt?.picklistFieldValues?.Nature_Mission__c?.values;
    if (!Array.isArray(values)) return [];

    const controllerValues = this.picklistByRt?.picklistFieldValues?.Nature_Mission__c?.controllerValues;
    const brancheValue = this.branche;
    const brancheLabel = (this.brancheOptions || []).find((o) => o.value === brancheValue)?.label;
    const rawKey = controllerValues?.[brancheValue] ?? (brancheLabel ? controllerValues?.[brancheLabel] : undefined);
    let key = rawKey === undefined || rawKey === null ? undefined : Number(rawKey);

    if (key === undefined || Number.isNaN(key)) {
      const controlling = this.picklistByRt?.picklistFieldValues?.Branche__c?.values;
      if (Array.isArray(controlling)) {
        const idxByValue = controlling.findIndex((v) => v?.value === brancheValue);
        if (idxByValue >= 0) key = idxByValue;
        else if (brancheLabel) {
          const idxByLabel = controlling.findIndex((v) => v?.label === brancheLabel);
          if (idxByLabel >= 0) key = idxByLabel;
        }
        if ((key === undefined || Number.isNaN(key)) && brancheValue) {
          const bnorm = stripDiacritics(brancheValue);
          const idxNorm = controlling.findIndex(
            (v) => stripDiacritics(v?.value) === bnorm || stripDiacritics(v?.label) === bnorm
          );
          if (idxNorm >= 0) key = idxNorm;
        }
      }
    }
    if (key === undefined || key === null || Number.isNaN(Number(key))) return [];

    return values
      .filter((v) => this.isValidForController(v?.validFor, key))
      .map((v) => ({ label: v.label, value: v.value }));
  }

  isValidForController(validFor, controllerIndex) {
    if (!validFor && validFor !== '') return true;
    try {
      const idx = Number(controllerIndex);
      if (Array.isArray(validFor)) {
        return validFor.map((n) => Number(n)).includes(idx);
      }

      const bytes = this.base64ToBytes(validFor);
      const byteIndex = Math.floor(idx / 8);
      const bitIndex = idx % 8;
      const b = bytes?.[byteIndex] ?? 0;
      return (b & (1 << (7 - bitIndex))) !== 0;
    } catch {
      return true;
    }
  }

  base64ToBytes(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  get typeSinistreOptions() {
    return [
      { label: 'AT', value: 'AT' },
      { label: 'MP (Maladie Professionnelle)', value: 'MP' },
    ];
  }

  get personTypeOptions() {
    return [
      { label: 'Victime', value: 'Victime' },
      { label: 'Assuré', value: 'Assuré' },
      { label: 'Tiers', value: 'Tiers' },
    ];
  }

  get civiliteOptions() {
    return [
      { label: 'M.', value: 'M.' },
      { label: 'Mme', value: 'Mme' },
    ];
  }

  get etatSanteOptions() {
    return [
      { label: 'Non blessé', value: 'Non blessé' },
      { label: 'Blessé', value: 'Blessé' },
      { label: 'Décédé', value: 'Décédé' },
      { label: 'Indemne', value: 'Indemne' },
    ];
  }

  get isSanteVacationSiege() {
    return this.isSante && stripDiacritics(this.nature) === stripDiacritics('Vacation sur siège');
  }

  get isSanteVacationSite() {
    return this.isSante && stripDiacritics(this.nature) === stripDiacritics('Vacation sur site');
  }

  get isATControle() {
    return this.isAT && stripDiacritics(this.nature) === stripDiacritics('Contrôle médicale');
  }

  get isATVacation() {
    const nk = stripDiacritics(this.nature);
    return this.isAT && nk === 'vacation' && !nk.includes(' sur ');
  }

  get isInfoStep() {
    return this.currentStep === 1;
  }
  get isPersonsStep() {
    return this.currentStep === 2;
  }

  get needsPersonsStep() {
    return this.isATControle;
  }

  get showPersonsStep() {
    // UX: show 2nd step only when it can be needed (AT branch). For Santé => 1 step.
    return this.isAT;
  }

  get maxStep() {
    return this.needsPersonsStep ? 2 : 1;
  }

  get showNext() {
    return this.isInfoStep && this.needsPersonsStep;
  }

  get showSubmit() {
    if (this.isInfoStep) return !this.needsPersonsStep;
    return this.isPersonsStep;
  }

  get isPrevDisabled() {
    return this.isSaving || this.currentStep === 1;
  }

  get isNextDisabled() {
    return this.isSaving || !this.validateCurrentStep({ silent: true });
  }

  get isSubmitDisabled() {
    // Modal visible for everyone, but submit only allowed for Médecin accounts
    return this.isSaving || !this.canCreateMission || !this.validateAll({ silent: true });
  }

  get isInfoStepComplete() {
    return this.isInformationsValid({ silent: true });
  }
  get isPersonsStepComplete() {
    if (!this.needsPersonsStep) return true;
    return this.persons.length > 0;
  }

  /** Fil d’étapes texte (autoMissionnementAvocat .step / .step.active / .step.done) */
  get stepClassMedecinInfo() {
    if (!this.showPersonsStep) {
      return 'step';
    }
    if (this.currentStep === 1) {
      return 'step active';
    }
    return 'step done';
  }
  get stepClassMedecinPersons() {
    return this.currentStep === 2 ? 'step active' : 'step';
  }
  get stepClassMedecinSingle() {
    return this.currentStep === 1 ? 'step active' : 'step done';
  }

  // Field state CSS
  get isPoliceOk() {
    return !!this.numeroPolice?.trim();
  }
  get isSinistreOk() {
    return !!this.numeroSinistre?.trim();
  }

  fieldClassFor(name, { success = false } = {}) {
    const base = [];
    if (this.errors?.[name]) base.push('fieldErrorState');
    if (success) base.push('fieldSuccessState');
    return base.join(' ');
  }

  get fieldClassBranche() {
    return this.fieldClassFor('branche');
  }
  get fieldClassNature() {
    return this.fieldClassFor('nature');
  }
  get fieldClassNomSociete() {
    return this.fieldClassFor('nomSociete');
  }
  get fieldClassNumeroPolice() {
    return this.fieldClassFor('numeroPolice', { success: this.isPoliceOk });
  }
  get fieldClassHeureDebut() {
    return this.fieldClassFor('heureDebut');
  }
  get fieldClassHeureFin() {
    return this.fieldClassFor('heureFin');
  }
  get fieldClassNombreDossiers() {
    return this.fieldClassFor('nombreDossiers');
  }
  get fieldClassTypeSinistre() {
    return this.fieldClassFor('typeSinistre');
  }
  get fieldClassDateSurvenance() {
    return this.fieldClassFor('dateSurvenance');
  }
  get fieldClassDateNomination() {
    return this.fieldClassFor('dateNomination');
  }
  get fieldClassNumeroSinistre() {
    return this.fieldClassFor('numeroSinistre', { success: this.isSinistreOk });
  }
  get fieldClassPersonType() {
    return this.fieldClassFor('personType');
  }
  get fieldClassCivilite() {
    return this.fieldClassFor('civilite');
  }
  get fieldClassNom() {
    return this.fieldClassFor('nom');
  }
  get fieldClassPrenom() {
    return this.fieldClassFor('prenom');
  }
  get fieldClassDateNaissance() {
    return this.fieldClassFor('dateNaissance');
  }

  get hasPersons() {
    return this.persons.length > 0;
  }

  /** Ouvre la modale (appelée par le parent ; pas de bouton interne). */
  @api
  open() {
    this.isOpen = true;
    this.currentStep = 1;
    this.errors = {};
    // Keep modal UI clean (no banner). Authorization is enforced on submit.
    this.errorMessage = '';
  }

  @api
  close() {
    if (this.isSaving) return;
    this.isOpen = false;
    this.errorMessage = '';
    this.errors = {};
  }

  prev() {
    if (this.isSaving) return;
    this.errorMessage = '';
    this.currentStep = Math.max(1, this.currentStep - 1);
  }

  next() {
    if (this.isSaving) return;
    this.errorMessage = '';
    const ok = this.validateCurrentStep({ silent: false });
    if (!ok) return;
    this.currentStep = Math.min(this.maxStep, this.currentStep + 1);
  }

  handleBrancheChange(e) {
    this.branche = e.detail.value;
    // Reset step2/step3 data when branch changes
    this.nature = '';
    this.numeroPolice = '';
    this.nomSociete = '';
    this.heureDebut = '';
    this.heureFin = '';
    this.nombreDossiers = '';
    this.typeSinistre = '';
    this.dateSurvenance = '';
    this.dateNomination = '';
    this.numeroSinistre = '';
    this.referenceDossier = '';
    this.persons = [];
    this.clearErrors(['branche']);
    this.currentStep = 1;
  }

  handleNatureChange(e) {
    this.nature = e.detail.value;
    this.clearErrors(['nature']);
    // Reset conditional inputs when nature changes
    this.nomSociete = '';
    this.heureDebut = '';
    this.heureFin = '';
    this.nombreDossiers = '';
    this.typeSinistre = '';
    this.dateSurvenance = '';
    this.dateNomination = '';
    this.numeroSinistre = '';
    this.referenceDossier = '';
    this.persons = [];
  }
  handleNumeroPoliceChange(e) {
    this.numeroPolice = e.detail.value;
    this.clearErrors(['numeroPolice']);
  }
  handleDateNominationChange(e) {
    this.dateNomination = e.detail.value;
    this.clearErrors(['dateNomination']);
  }
  handleSinistreNonOuvertChange(e) {
    this.sinistreNonOuvert = !!e.target.checked;
  }
  handleHeureDebutChange(e) {
    this.heureDebut = e.detail.value;
    this.clearErrors(['heureDebut']);
  }
  handleHeureFinChange(e) {
    this.heureFin = e.detail.value;
    this.clearErrors(['heureFin']);
  }
  handleNombreDossiersChange(e) {
    this.nombreDossiers = e.detail.value;
    this.clearErrors(['nombreDossiers']);
  }
  handleNomSocieteChange(e) {
    this.nomSociete = e.detail.value;
    this.clearErrors(['nomSociete']);
  }
  handleTypeSinistreChange(e) {
    this.typeSinistre = e.detail.value;
    this.clearErrors(['typeSinistre']);
  }
  handleDateSurvenanceChange(e) {
    this.dateSurvenance = e.detail.value;
    this.clearErrors(['dateSurvenance']);
  }
  handleNumeroSinistreChange(e) {
    this.numeroSinistre = e.detail.value;
    this.clearErrors(['numeroSinistre']);
  }
  handleReferenceDossierChange(e) {
    this.referenceDossier = e.detail.value;
  }

  handlePersonTypeChange(e) {
    this.personType = e.detail.value;
    this.clearErrors(['personType', 'persons']);
  }
  handleCiviliteChange(e) {
    this.civilite = e.detail.value;
    this.clearErrors(['civilite', 'persons']);
  }
  handleNomChange(e) {
    this.nom = e.detail.value;
    this.clearErrors(['nom', 'persons']);
  }
  handlePrenomChange(e) {
    this.prenom = e.detail.value;
    this.clearErrors(['prenom', 'persons']);
  }
  handleDateNaissanceChange(e) {
    this.dateNaissance = e.detail.value;
    this.clearErrors(['dateNaissance', 'persons']);
  }
  handleEtatSanteChange(e) {
    this.etatSante = e.detail.value;
  }

  clearErrors(keys = []) {
    if (!this.errors) this.errors = {};
    const next = { ...this.errors };
    keys.forEach((k) => {
      if (next[k]) delete next[k];
    });
    this.errors = next;
  }

  setError(key, msg, { silent } = { silent: false }) {
    const next = { ...(this.errors || {}) };
    next[key] = msg;
    this.errors = next;
    if (!silent) this.errorMessage = 'Veuillez corriger les champs en rouge.';
  }

  isInformationsValid({ silent } = { silent: true }) {
    const errs = {};
    if (this.canCreateMission) {
      if (this.branchesAgreesTokens.length === 0) {
        errs.branche = 'Aucune branche agréée sur votre compte.';
      } else if (this.brancheOptions.length === 0) {
        errs.branche = 'Vos branches agréées ne correspondent à aucune branche de mission disponible.';
      }
    }
    if (!this.branche) errs.branche = errs.branche || 'Champ obligatoire.';
    if (!this.nature) errs.nature = 'Champ obligatoire.';

    if (this.isSante) {
      if (this.isSanteVacationSite && !this.nomSociete?.trim()) {
        errs.nomSociete = 'Champ obligatoire.';
      }
      if (!this.heureDebut) errs.heureDebut = 'Champ obligatoire.';
      if (!this.heureFin) errs.heureFin = 'Champ obligatoire.';
      if (this.nombreDossiers === '' || this.nombreDossiers === null || this.nombreDossiers === undefined) {
        errs.nombreDossiers = 'Champ obligatoire.';
      }
    }

    if (this.isATControle) {
      if (!this.typeSinistre) errs.typeSinistre = 'Champ obligatoire.';
      if (!this.dateSurvenance) errs.dateSurvenance = 'Champ obligatoire.';
      if (!this.dateNomination) errs.dateNomination = 'Champ obligatoire.';
    }

    if (this.isATVacation) {
      if (!this.heureDebut) errs.heureDebut = 'Champ obligatoire.';
      if (!this.heureFin) errs.heureFin = 'Champ obligatoire.';
      if (this.nombreDossiers === '' || this.nombreDossiers === null || this.nombreDossiers === undefined) {
        errs.nombreDossiers = 'Champ obligatoire.';
      }
    }

    const ok = Object.keys(errs).length === 0;
    if (!ok && !silent) {
      this.errors = { ...(this.errors || {}), ...errs };
      this.errorMessage = 'Veuillez corriger les champs en rouge.';
    }
    return ok;
  }

  validateCurrentStep({ silent } = { silent: true }) {
    if (this.currentStep === 1) return this.isInformationsValid({ silent });
    if (this.currentStep === 2) {
      if (this.needsPersonsStep && this.persons.length === 0) {
        this.setError('persons', 'Au moins une personne est obligatoire.', { silent });
        return false;
      }
      return true;
    }
    return true;
  }

  validateAll({ silent } = { silent: true }) {
    const ok1 = this.isInformationsValid({ silent });
    const ok2 =
      !this.needsPersonsStep ||
      this.persons.length > 0 ||
      (this.setError('persons', 'Au moins une personne est obligatoire.', { silent }), false);
    return ok1 && ok2;
  }

  addPerson() {
    this.errorMessage = '';
    const errs = {};
    if (!this.personType) errs.personType = 'Champ obligatoire.';
    if (!this.civilite) errs.civilite = 'Champ obligatoire.';
    if (!this.nom?.trim()) errs.nom = 'Champ obligatoire.';
    if (!this.prenom?.trim()) errs.prenom = 'Champ obligatoire.';
    if (!this.dateNaissance) errs.dateNaissance = 'Champ obligatoire.';
    const ok = Object.keys(errs).length === 0;
    if (!ok) {
      this.errors = { ...(this.errors || {}), ...errs };
      this.errorMessage = 'Veuillez corriger les champs en rouge.';
      return;
    }

    const key = `${this.nom.trim().toLowerCase()}|${this.prenom.trim().toLowerCase()}|${this.dateNaissance}`;
    const exists = this.persons.some((p) => p.key === key);
    if (exists) {
      this.setError('persons', 'Cette personne existe déjà (Nom + Prénom + Date de naissance).', { silent: false });
      return;
    }

    const person = {
      key,
      personType: this.personType,
      civilite: this.civilite,
      nom: this.nom.trim(),
      prenom: this.prenom.trim(),
      dateNaissance: this.dateNaissance,
      etatSante: this.etatSante || '',
    };

    this.persons = [...this.persons, person];

    // Reset inputs
    this.personType = '';
    this.civilite = '';
    this.nom = '';
    this.prenom = '';
    this.dateNaissance = '';
    this.etatSante = '';
    this.clearErrors(['personType', 'civilite', 'nom', 'prenom', 'dateNaissance', 'persons']);
  }

  removePerson(e) {
    const key = e?.target?.dataset?.key;
    if (!key) return;
    this.persons = (this.persons || []).filter((p) => p.key !== key);
    this.clearErrors(['persons']);
  }

  buildPersonnesImpliqueesValue() {
    if (!Array.isArray(this.persons) || this.persons.length === 0) return '';
    return this.persons
      .map((p) =>
        [
          p.personType || '',
          p.civilite || '',
          p.nom || '',
          p.prenom || '',
          p.dateNaissance || '',
          p.etatSante || '',
        ].join('|')
      )
      .join('\n');
  }

  @wire(getRecord, { recordId: userId, fields: [USER_CONTACT_ID] })
  wiredUser({ data }) {
    // If LDS can't read User.ContactId in Community context, don't overwrite.
    if (!data) return;
    const cid = getFieldValue(data, USER_CONTACT_ID);
    this.contactId = cid || this.contactId || null;
  }

  @wire(getRecord, { recordId: '$contactId', fields: [CONTACT_ACCOUNT_ID] })
  wiredContact({ data }) {
    // If LDS can't read Contact.AccountId in Community context, don't overwrite Apex-derived values.
    if (!data) return;
    const aid = getFieldValue(data, CONTACT_ACCOUNT_ID);
    this.prestataireAccountId = aid || this.prestataireAccountId || null;
  }

  async save() {
    this.errorMessage = '';
    if (!this.canCreateMission) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Accès refusé',
          message: 'La création de mission est réservée aux comptes Médecin.',
          variant: 'warning',
        })
      );
      return;
    }
    const ok = this.validateAll({ silent: false });
    if (!ok) return;

    this.isSaving = true;

    try {
      const now = new Date();
      const yyyy = now.getFullYear();
      const mm = String(now.getMonth() + 1).padStart(2, '0');
      const dd = String(now.getDate()).padStart(2, '0');

      const brancheLabel = this.isSante ? 'Santé' : this.isAT ? 'AT' : 'Mission';
      const natureLabel =
        (this.natureOptions || []).find((o) => o.value === this.nature)?.label || this.nature || '';
      const name = `Auto-missionnement ${brancheLabel} — ${natureLabel} (${yyyy}-${mm}-${dd})`;

      const fields = {
        Name: name,
        RecordTypeId: this.missionRecordTypeId,
        Type_Prestataire__c: 'Medecin',
        Branche__c: this.branche,
        Nature_Mission__c: this.nature,
        Type_de_mission__c: 'Auto-missionnement',
        Type_de_prestation__c: 'Prémission',
      };

      if (this.prestataireAccountId) {
        fields.Prestataire__c = this.prestataireAccountId;
      }

      fields.Sinistre_non_ouvert__c = this.sinistreNonOuvert;

      if (this.numeroPolice?.trim()) {
        fields.Numero_police__c = this.numeroPolice.trim();
      }

      if (this.nomSociete?.trim()) fields.Nom_societe__c = this.nomSociete.trim();
      const hd = normalizeTimeForCreate(this.heureDebut);
      const hf = normalizeTimeForCreate(this.heureFin);
      if (hd) fields.Heure_debut_passage__c = hd;
      if (hf) fields.Heure_fin_passage__c = hf;
      if (this.nombreDossiers !== '' && this.nombreDossiers !== null && this.nombreDossiers !== undefined) {
        fields.Nombre_dossiers__c = Number(this.nombreDossiers);
      }

      if (this.typeSinistre) fields.Type_Sinistre__c = this.typeSinistre;
      if (this.dateSurvenance) fields.Date_survenance__c = this.dateSurvenance;
      if (this.dateNomination) fields.Date_nomination__c = this.dateNomination;
      if (this.numeroSinistre?.trim()) fields.Numero_sinistre__c = this.numeroSinistre.trim();
      if (this.referenceDossier?.trim()) {
        fields.Reference_dossier_prestataire__c = this.referenceDossier.trim();
      }

      const personnes = this.buildPersonnesImpliqueesValue();
      if (personnes) fields.Personnes_impliquees__c = personnes;

      let created;
      try {
        created = await createRecord({ apiName: MISSION_OBJECT, fields });
      } catch (e1) {
        const minimalFields = { Name: name };
        if (this.missionRecordTypeId) minimalFields.RecordTypeId = this.missionRecordTypeId;
        if (this.prestataireAccountId) {
          minimalFields.Prestataire__c = this.prestataireAccountId;
        }
        minimalFields.Branche__c = this.branche;
        minimalFields.Type_Prestataire__c = 'Medecin';
        minimalFields.Nature_Mission__c = this.nature;
        minimalFields.Type_de_mission__c = 'Auto-missionnement';
        minimalFields.Type_de_prestation__c = 'Prémission';
        minimalFields.Sinistre_non_ouvert__c = this.sinistreNonOuvert;
        if (this.numeroPolice?.trim()) {
          minimalFields.Numero_police__c = this.numeroPolice.trim();
        }
        if (this.dateNomination) minimalFields.Date_nomination__c = this.dateNomination;
        if (personnes) minimalFields.Personnes_impliquees__c = personnes;
        const hd2 = normalizeTimeForCreate(this.heureDebut);
        const hf2 = normalizeTimeForCreate(this.heureFin);
        if (hd2) minimalFields.Heure_debut_passage__c = hd2;
        if (hf2) minimalFields.Heure_fin_passage__c = hf2;
        created = await createRecord({ apiName: MISSION_OBJECT, fields: minimalFields });
      }

      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Mission créée',
          message: 'Mission créée',
          variant: 'success',
        })
      );

      this.isOpen = false;
      void created;
    } catch (e) {
      const msgs = normalizeLdsErrors(e);
      this.errorMessage =
        msgs.join(' | ') +
        ' — Vérifie que ton utilisateur a le droit de créer des Missions (CRUD) et de modifier les champs utilisés (FLS).';
    } finally {
      this.isSaving = false;
    }
  }
}

