import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent }                     from 'lightning/platformShowToastEvent';
import basePath                               from '@salesforce/community/basePath';
import { getRecord, getFieldValue }           from 'lightning/uiRecordApi';
import { getObjectInfo }                      from 'lightning/uiObjectInfoApi';
import ACCOUNT_OBJECT                         from '@salesforce/schema/Account';
import ACCOUNT_RT_FIELD from '@salesforce/schema/Account.RecordTypeId';

import getGateInfo from '@salesforce/apex/MissionCreateMedecinGateControllerCopy.getGateInfo';

import getMissions              from '@salesforce/apex/MissionPortailController7.getMissions';
import getMissionRecordTypeName from '@salesforce/apex/MissionPortailController7.getMissionRecordTypeName';
import getStatutOptions         from '@salesforce/apex/MissionPortailController7.getStatutOptions';
import getBrancheOptions        from '@salesforce/apex/MissionPortailController7.getBrancheOptions';
import getColorMapping          from '@salesforce/apex/MissionPortailController7.getColorMapping';
import getDisplayColumns        from '@salesforce/apex/MissionPortailController7.getDisplayColumns';

/* ── UTILITAIRES ── */
function fmtDate(val) {
    if (!val) return '—';
    const [y, m, d] = val.split('-');
    return `${d}/${m}/${y}`;
}

const STATUT_LABELS = {
    'Initiee'         : 'Initiée',
    'En_cours'        : 'En cours',
    'Rapport_recu'    : 'Rapport reçu',
    'Rapport_attendu' : 'Rapport attendu',
    'Cloturee'        : 'Clôturée',
    'Annulee'         : 'Annulée'
};

/**
 * Mélange une couleur hex vers le blanc à hauteur de `ratio` (0 = couleur pure, 1 = blanc).
 * Utilisé pour générer le fond pastel du badge statut.
 */
function mixWithWhite(hex, ratio) {
    const num = parseInt((hex || '#a8b8c8').replace('#', ''), 16);
    const r = (num >> 16);
    const g = (num >> 8) & 0x00FF;
    const b = (num & 0x0000FF);
    const R = Math.round(r + (255 - r) * ratio);
    const G = Math.round(g + (255 - g) * ratio);
    const B = Math.round(b + (255 - b) * ratio);
    return '#' + (0x1000000 + R * 0x10000 + G * 0x100 + B).toString(16).slice(1);
}

function normalizeValue(value) {
    return value ? String(value).trim() : '';
}

function isValidSalesforceId(id) {
    if (id == null || typeof id !== 'string') return false;
    const s = id.trim();
    return /^[a-zA-Z0-9]{15}$/.test(s) || /^[a-zA-Z0-9]{18}$/.test(s);
}

/**
 * Assombrit une couleur hex de `ratio` vers le noir (0 = couleur pure, 1 = noir).
 * Utilisé pour la couleur du texte dans le badge statut.
 */
function darken(hex, ratio) {
    const num = parseInt((hex || '#a8b8c8').replace('#', ''), 16);
    const r = (num >> 16);
    const g = (num >> 8) & 0x00FF;
    const b = (num & 0x0000FF);
    const R = Math.round(r * (1 - ratio));
    const G = Math.round(g * (1 - ratio));
    const B = Math.round(b * (1 - ratio));
    return '#' + (0x1000000 + R * 0x10000 + G * 0x100 + B).toString(16).slice(1);
}

/**
 * Adds boolean type-flags to a column descriptor so the template
 * can use plain property access (col.isStatut) instead of the
 * illegal method-call syntax inside if:true directives.
 */
function tagColumn(col) {
    return {
        ...col,
        isNumeroMission : col.apiName === 'numeroMission',
        isBranche       : col.apiName === 'branche',
        isStatut        : col.apiName === 'statut',
        isDateNomination: col.apiName === 'dateNomination',
        isSinistre      : col.apiName === 'sinistre',
        isDossier       : col.apiName === 'dossier',
        isDocuments     : col.apiName === 'documents',
        isMessagerie    : col.apiName === 'messagerie',
        isHonoraires    : col.apiName === 'honoraires',
    };
}

export default class MissionPortail8 extends LightningElement {

    /* ── PROPS ── */
    @api recordId;

    /**
     * Variante de la fiche détail après clic sur une ligne.
     * 'medecin' = ouvre la page Experience dédiée **uniquement** si le compte prestataire
     *             connecté est un record type Médecin (sinon fiche inline générique).
     * 'default' = toujours fiche inline c-detail-mission.
     */
    @api detailVariant = 'default';

    /**
     * API Name de la page Experience (onglet Page → API Name).
     * Utilisé si la navigation par URL n’est pas possible (pathname sans /s/).
     */
    @api medecinDetailPageName = 'MissionMedecin';

    /**
     * Segment d’URL après le préfixe du site (champ **URL** de la page dans Experience Builder,
     * souvent en minuscules, ex. missionmedecin). Si vide, on dérive du nom API en minuscules.
     */
    @api medecinDetailUrlSlug;

    /** Record type Account (DeveloperName) issu du gate Apex — fiable en Experience Cloud. */
    @track gateAccountRtDevName = null;
    @track accountObjectInfo = null;

    @wire(getGateInfo)
    wiredGateInfo({ data }) {
        if (data?.accountRecordTypeDeveloperName != null) {
            this.gateAccountRtDevName = data.accountRecordTypeDeveloperName;
        }
    }

    @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
    wiredAccountObjectInfo({ data }) {
        this.accountObjectInfo = data || null;
    }

    _isMedecinPrestataireAccount() {
        const fromGate = (this.gateAccountRtDevName || '').trim().toLowerCase();
        if (fromGate) {
            return fromGate === 'medecin' || fromGate.includes('medecin');
        }
        if (!this.accountObjectInfo || !this.accountRecordTypeId) {
            return false;
        }
        const infos = this.accountObjectInfo.recordTypeInfos || {};
        const rt = Object.values(infos).find((i) => i?.recordTypeId === this.accountRecordTypeId);
        const dn = (rt?.developerName || '').toLowerCase();
        return dn === 'medecin' || dn.includes('medecin');
    }

    get useMedecinDetail() {
        return (this.detailVariant || 'default') === 'medecin' && this._isMedecinPrestataireAccount();
    }

    /* ── STATE ── */
    @track _missions      = [];
    @track _enrichedList  = [];
    @track statutOptions  = [];
    @track brancheOptions = [];
    @track displayColumns = [];
    @track filterStatut   = 'toutes';
    @track filterBranche  = 'toutes';
    @track searchTerm     = '';

    @track accountRecordTypeId   = null;
    @track missionRecordTypeName = null;
    @track colorMapping          = {};

    @track selectedMissionId = null;

    isLoading = true;
    hasError  = false;

    /* ── WIRE : RecordTypeId du compte ── */
    @wire(getRecord, { recordId: '$recordId', fields: [ACCOUNT_RT_FIELD] })
    wiredAccount({ data, error }) {
        if (data) {
            this.accountRecordTypeId = getFieldValue(data, ACCOUNT_RT_FIELD);
        }
    }

    /* ── WIRE : DeveloperName du RecordType de Mission ── */
    @wire(getMissionRecordTypeName, { accountRecordTypeId: '$accountRecordTypeId' })
    wiredMissionRtName({ data, error }) {
        if (data) {
            this.missionRecordTypeName = data;
        }
    }

    /* ── WIRE : Colonnes dynamiques ── */
    @wire(getDisplayColumns, { recordTypeName: '$missionRecordTypeName' })
    wiredDisplayColumns({ data, error }) {
        if (data) {
            this.displayColumns = data.map(col => tagColumn(col));
        } else if (error) {
            console.warn('⚠️  Erreur chargement colonnes:', error);
        }
    }

    /* ── WIRE : Couleurs dynamiques ── */
    @wire(getColorMapping)
    wiredColorMapping({ data, error }) {
        if (data) {
            this.colorMapping = data;
            // Re-enrich existing missions now that colors are available
            if (this._missions.length) {
                this._enrichedList = this._missions.map(m => this._enrich(m));
            }
        } else if (error) {
            console.warn('⚠️  Erreur couleurs:', error);
        }
    }

    /* ── WIRE : Statuts ── */
    @wire(getStatutOptions)
    wiredStatutOptions({ data, error }) {
        if (data && data.length > 0) {
            this.statutOptions = data;
        } else {
            this._buildFallbackStatuts();
        }
    }

    /* ── WIRE : Branches ── */
    @wire(getBrancheOptions)
    wiredBrancheOptions({ data, error }) {
        if (data && data.length > 0) {
            this.brancheOptions = data;
        } else {
            this._buildFallbackBranches();
        }
    }

    /* ── WIRE : Missions ── */
    @wire(getMissions)
    wiredMissions({ data, error }) {
        this.isLoading = false;
        if (data) {
            this._missions     = data;
            this._enrichedList = data.map(m => this._enrich(m));
            this._buildFallbackStatuts();
            this._buildFallbackBranches();
            this.hasError = false;
        } else if (error) {
            console.error('❌ Erreur missions:', error);
            this.hasError = true;
            this._loadTestMissions();
        }
    }

    /* ── MODE TEST ── */
    _loadTestMissions() {
        const testData = [
            { Id: '1', Numero_mission: 'MSN-2026-00053', Statut: 'En_cours',        Branche: 'RC',           Date_nomination: '2026-04-10' },
            { Id: '2', Numero_mission: 'MSN-2026-00048', Statut: 'Rapport_recu',    Branche: 'AT',           Date_nomination: '2026-03-01' },
            { Id: '3', Numero_mission: 'MSN-2026-00042', Statut: 'Cloturee',        Branche: 'Autocorporel', Date_nomination: '2026-02-15' },
            { Id: '4', Numero_mission: 'MSN-2026-00056', Statut: 'En_cours',        Branche: 'RC',           Date_nomination: '2026-04-20' },
            { Id: '5', Numero_mission: 'MSN-2026-00060', Statut: 'Initiee',         Branche: 'AT',           Date_nomination: '2026-04-25' },
            { Id: '6', Numero_mission: 'MSN-2026-00035', Statut: 'Annulee',         Branche: 'Autocorporel', Date_nomination: '2026-01-10' },
        ];
        this._missions     = testData;
        this._enrichedList = testData.map(m => this._enrich(m));
        this.isLoading     = false;
        this._buildFallbackStatuts();
        this._buildFallbackBranches();
    }

    /* ── FALLBACKS PICKLIST ── */
    _buildFallbackStatuts() {
        const vals = new Set(this._missions.map(m => normalizeValue(m.Statut)).filter(Boolean));
        this.statutOptions = [{ label: 'Tous les statuts', value: 'toutes' }];
        vals.forEach(v => this.statutOptions.push({ label: STATUT_LABELS[v] || v, value: v }));
    }

    _buildFallbackBranches() {
        const vals = new Set(this._missions.map(m => normalizeValue(m.Branche)).filter(Boolean));
        this.brancheOptions = [{ label: 'Toutes les branches', value: 'toutes' }];
        vals.forEach(v => this.brancheOptions.push({ label: v, value: v }));
    }

    /**
     * Enrichit chaque mission avec :
     *  - statutStyle  : style inline pour le badge statut (background pastel + texte assombri)
     *  - bdotStyle    : style inline pour le point coloré du statut
     *  - brancheStyle : style inline pour le texte de la branche — COULEUR SEULE, sans fond
     *
     * Pour la branche : on applique directement la couleur de la palette sans fond,
     * légèrement assombrie pour garantir le contraste sur fond blanc.
     */
    _enrich(m) {
        const statutKey  = normalizeValue(m.Statut);
        const brancheKey = normalizeValue(m.Branche);
        const displayStatut = STATUT_LABELS[statutKey] || statutKey || '—';

        // ── Statut : badge avec fond pastel et texte assombri ──
        const statutColor = this.colorMapping[`statut_${statutKey}`] || '#706e6b';
        const statutBg    = mixWithWhite(statutColor, 0.93);
        const statutText  = darken(statutColor, 0.48);

        // ── Branche : texte coloré ──
        // On assombrit légèrement (35%) pour un bon contraste sur fond blanc.
        const brancheColor    = this.colorMapping[`branche_${brancheKey}`] || '#706e6b';
        const brancheTextOnly = darken(brancheColor, 0.35);

        return {
            ...m,
            _statutRaw       : statutKey,
            _brancheRaw      : brancheKey,
            StatutLabel      : displayStatut,
            dateNominationFmt: fmtDate(m.Date_nomination),
            // Styles inline — seule méthode LWC approuvée pour les couleurs 100% dynamiques
            statutStyle : `background:${statutBg};color:${statutText};`,
            bdotStyle   : `background:${statutColor};`,
            // Branche : couleur du texte uniquement, fond transparent
            brancheStyle: `color:${brancheTextOnly};font-weight:600;`,
        };
    }

    /* ── MISSIONS FILTRÉES ── */
    get missionsAffichees() {
        let result = [...this._enrichedList];
        if (this.filterStatut !== 'toutes') {
            result = result.filter(m => m._statutRaw === this.filterStatut);
        }
        if (this.filterBranche !== 'toutes') {
            result = result.filter(m => m._brancheRaw === this.filterBranche);
        }
        if (this.searchTerm) {
            const term = this.searchTerm.toLowerCase();
            result = result.filter(m =>
                m.Numero_mission?.toLowerCase().includes(term) ||
                m.StatutLabel?.toLowerCase().includes(term)    ||
                m.Branche?.toLowerCase().includes(term)
            );
        }
        return result;
    }

    get hasMissions()   { return this.missionsAffichees.length > 0; }
    get missionsCount() { return this.missionsAffichees.length; }
    get totalCount()    { return this._missions.length; }

    /** Préfixe community jusqu’à …/s (ex. /monSite/s) pour construire une URL stable. */
    _communityPathUpToS() {
        const path = window.location.pathname || '';
        const idx = path.indexOf('/s/');
        if (idx === -1) {
            return '';
        }
        return path.slice(0, idx + 2);
    }

    /**
     * Ajuste basePath (@salesforce/community) selon le style d’URL du site :
     * - Aura / certains sites : …/MonSite/s/Page → le pathname contient /s/.
     * - LWR (ex. my.site.com/PP/Page) : pas de /s/ ; un basePath /PP/s ferait une URL invalide.
     */
    _normalizeCommunityBasePath(raw) {
        let p = typeof raw === 'string' ? raw.trim().replace(/\/+$/, '') : '';
        if (!p) {
            return '';
        }
        if (!p.startsWith('/')) {
            p = `/${p}`;
        }
        const path = window.location.pathname || '';
        const siteUsesS = path.includes('/s/');
        if (!siteUsesS) {
            p = p.replace(/\/s$/i, '');
        } else if (!/\/s$/i.test(p)) {
            p = `${p}/s`;
        }
        return p.replace(/\/{2,}/g, '/');
    }

    /** Repli : premier segment du pathname (ex. /PP/missions → /PP) pour my.site.com. */
    _pathnameSiteRootPrefix() {
        const path = (window.location.pathname || '').replace(/\/+$/, '');
        const segs = path.split('/').filter(Boolean);
        if (!segs.length) {
            return '';
        }
        return `/${segs[0]}`;
    }

    _navigateMedecinDetailPage(missionId) {
        const pageName = normalizeValue(this.medecinDetailPageName) || 'MissionMedecin';
        const slugFromApi = pageName.replace(/__c$/i, '');
        const slugExplicit = normalizeValue(this.medecinDetailUrlSlug);
        // Champ « URL » de la page Experience = en général tout en minuscules (ex. missionmedecin), alors que le nom API garde des majuscules.
        const slug = slugExplicit || slugFromApi.toLowerCase();
        // LWR : le param peut être `missionId` (Builder) ou `c__missionId` (héritage Aura) — on envoie les deux.
        const q = `missionId=${encodeURIComponent(missionId)}&c__missionId=${encodeURIComponent(missionId)}`;
        const pathSeg = encodeURIComponent(slug);
        const origin = window.location.origin;

        let bp = this._normalizeCommunityBasePath(basePath);
        if (!bp) {
            bp = this._pathnameSiteRootPrefix();
        }
        if (bp) {
            window.location.assign(`${origin}${bp}/${pathSeg}?${q}`);
            return;
        }

        const legacy = this._communityPathUpToS();
        if (legacy) {
            window.location.assign(`${origin}${legacy}/${pathSeg}?${q}`);
            return;
        }

        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Navigation impossible',
                message:
                    'Impossible de déterminer l’URL du site (base community). Vérifiez que ce composant est bien sur une page Experience.',
                variant: 'error',
                mode: 'dismissable',
            }),
        );
    }

    /* ── HANDLERS ── */
    handleFilterStatut(evt)  { this.filterStatut  = evt.target.value; }
    handleFilterBranche(evt) { this.filterBranche = evt.target.value; }
    handleSearch(evt)        { this.searchTerm    = evt.target.value; }

    /**
     * Navigue vers la page FlexiPage "missionDetails" avec l'ID de la mission.
     * La page missionDetails doit être un Lightning Page qui accepte le paramètre "missionId".
     */
    handleRowClick(evt) {
        const id = evt.currentTarget.dataset.id;
        if (!isValidSalesforceId(id)) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Mission non ouvrable',
                    message:
                        'Cette ligne a un identifiant invalide (souvent des données de test). Utilisez une mission issue de Salesforce pour ouvrir la fiche.',
                    variant: 'warning',
                    mode: 'dismissable',
                }),
            );
            return;
        }
        // Variante médecin : page Experience dédiée seulement pour comptes prestataire « Médecin ».
        if (this.useMedecinDetail) {
            this._navigateMedecinDetailPage(id);
            return;
        }

        // Variante défaut : affichage inline
        this.selectedMissionId = id;
    }

    handleRetour() {
        this.selectedMissionId = null;
    }
}