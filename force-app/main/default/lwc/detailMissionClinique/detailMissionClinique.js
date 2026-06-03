import { LightningElement, wire, track } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getMissionDetails from '@salesforce/apex/MissionController.getMissionDetails';

const BADGE_FIELDS = ['Statut__c', 'Branche__c'];

export default class DetailMissionClinique extends LightningElement {

    @track _resolvedMissionId;
    @track activeTab = 'informations';
    @track headerFields = [];
    @track detailFields = [];
    @track missionName = '';
    @track _error;
    @track _isLoading = true;

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (pageRef?.state?.c__missionId) {
            this._resolvedMissionId = pageRef.state.c__missionId;
        }
    }

    @wire(getMissionDetails, { missionId: '$_resolvedMissionId' })
    wiredMission({ data, error }) {
        this._isLoading = false;
        if (data) {
            this.missionName  = data.missionName || '';
            this.headerFields = (data.headerFields || []).map(f => ({
                ...f,
                isBadge: BADGE_FIELDS.includes(f.apiName),
                sepKey: f.apiName + '_sep'
            }));
            this.detailFields = data.detailFields || [];
            this._error = undefined;
        } else if (error) {
            this._error = error.body?.message || 'Erreur inconnue';
        }
    }

    get isLoading() { return this._isLoading; }
    get hasError()  { return !this._isLoading && !!this._error; }
    get isReady()   { return !this._isLoading && !this._error; }

    get badgeFields() { return this.headerFields.filter(f => f.isBadge); }
    get metaFields()  { return this.headerFields.filter(f => !f.isBadge).map(f => ({ ...f, sepKey: f.apiName + '_sep' })); }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isInformations() { return this.activeTab === 'informations'; }
    get isHonoraires()   { return this.activeTab === 'honoraires'; }
    get isDocuments()    { return this.activeTab === 'documents'; }
    get isMessagerie()   { return this.activeTab === 'messagerie'; }
    get isHistorique()   { return this.activeTab === 'historique'; }

    get informationsClass() { return 'dma-tab' + (this.isInformations ? ' dma-tab--active' : ''); }
    get honorairesClass()   { return 'dma-tab' + (this.isHonoraires   ? ' dma-tab--active' : ''); }
    get documentsClass()    { return 'dma-tab' + (this.isDocuments    ? ' dma-tab--active' : ''); }
    get messagerieClass()   { return 'dma-tab' + (this.isMessagerie   ? ' dma-tab--active' : ''); }
    get historiqueClass()   { return 'dma-tab' + (this.isHistorique   ? ' dma-tab--active' : ''); }
    get generalFields() {
        const half = Math.ceil(this.detailFields.length / 2);
        return this.detailFields.slice(0, half);
    }

    get specificFields() {
        const half = Math.ceil(this.detailFields.length / 2);
        return this.detailFields.slice(half);
    }
}