import { LightningElement, wire, track } from 'lwc';
import getMyMissions from '@salesforce/apex/PortailMissionController.getMyMissions';

export default class PortailMissionList extends LightningElement {
    @track missions = [];
    @track filteredMissions = [];
    searchKey = '';
    currentFilter = 'all';

    @track tabs = [
        { label: 'Toutes', value: 'all', className: 'nav-link on' },
        { label: 'En cours', value: 'En cours', className: 'nav-link' },
        { label: 'Clôturées', value: 'Clôturée', className: 'nav-link' }
    ];

    @wire(getMyMissions)
    wiredMissions({ error, data }) {
        if (data) {
            this.missions = data.map(m => ({
                ...m,
                // On pré-calcule les classes CSS pour garder le style source
                badgeClass: m.Statut__c === 'Clôturée' ? 'badge status-gray' : 'badge status-blue',
                formattedDate: m.Date_nomination__c ? new Date(m.Date_nomination__c).toLocaleDateString() : ''
            }));
            this.applyFilters();
        }
    }

    handleSearchChange(event) {
        this.searchKey = event.target.value.toLowerCase();
        this.applyFilters();
    }

    handleTabClick(event) {
        const selected = event.target.dataset.filter;
        this.currentFilter = selected;
        
        // Update UI Tabs
        this.tabs = this.tabs.map(t => ({
            ...t,
            className: t.value === selected ? 'nav-link on' : 'nav-link'
        }));
        
        this.applyFilters();
    }

    applyFilters() {
        this.filteredMissions = this.missions.filter(m => {
            const matchesSearch = m.Name.toLowerCase().includes(this.searchKey) || 
                                 (m.Numero_sinistre__c && m.Numero_sinistre__c.toLowerCase().includes(this.searchKey));
            const matchesTab = this.currentFilter === 'all' || m.Statut__c === this.currentFilter;
            return matchesSearch && matchesTab;
        });
    }

    navigateToDetail(event) {
        const missionId = event.currentTarget.dataset.id;
        // Navigation vers la page de détail (à configurer plus tard)
    }
}