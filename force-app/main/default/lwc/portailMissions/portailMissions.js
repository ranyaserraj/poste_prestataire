import { LightningElement, track } from 'lwc';
import getMissions from '@salesforce/apex/PortailMissionsController.getMissions';

export default class PortailMissions extends LightningElement {

    @track currentView = 'list';
    @track activeMissionId = null;

    @track filterStatut = 'toutes';
    @track searchTerm = '';

    missions = [];

    connectedCallback(){
        getMissions()
        .then(data=>{
            this.missions = data.map(m => ({
            ...m,
            statusClass: this.getStatusClass(m.statut),
            badgeClass: `badge ${this.getStatusClass(m.statut)}`
}));
        })
        .catch(error=>{
            console.error(error);
        });
    }

    get isList(){ return this.currentView === 'list'; }
    get isDetail(){ return this.currentView === 'detail'; }

    get activeMission(){
        return this.missions.find(m => m.id === this.activeMissionId);
    }

    get filteredMissions(){
        return this.missions.filter(m => {
            return (this.filterStatut === 'toutes' || m.statut === this.filterStatut)
            && (
                (m.name || '').toLowerCase().includes(this.searchTerm.toLowerCase()) ||
                (m.nature || '').toLowerCase().includes(this.searchTerm.toLowerCase())
            );
        });
    }

    /* BOUTONS */
    get filterToutes(){ return this.filterStatut === 'toutes' ? 'fbtn on' : 'fbtn'; }
    get filterEncours(){ return this.filterStatut === 'En cours' ? 'fbtn on' : 'fbtn'; }
    get filterRapport(){ return this.filterStatut === 'Rapport remis' ? 'fbtn on' : 'fbtn'; }
    get filterCloture(){ return this.filterStatut === 'Clôturée' ? 'fbtn on' : 'fbtn'; }

    /* BADGES */
    getStatusClass(statut){
        if(statut === 'En cours') return 'b-enc';
        if(statut === 'Rapport remis') return 'b-rap';
        if(statut === 'Clôturée') return 'b-clo';
        return 'b-init';
    }

    handleMissionClick(e){
        this.activeMissionId = e.currentTarget.dataset.id;
        this.currentView = 'detail';
    }

    handleRetour(){
        this.currentView = 'list';
        this.activeMissionId = null;
    }

    handleSearch(e){
        this.searchTerm = e.target.value;
    }

    handleFilterToutes(){ this.filterStatut = 'toutes'; }
    handleFilterEncours(){ this.filterStatut = 'En cours'; }
    handleFilterRapport(){ this.filterStatut = 'Rapport remis'; }
    handleFilterCloture(){ this.filterStatut = 'Clôturée'; }
}