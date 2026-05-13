import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import basePath from '@salesforce/community/basePath';
import USER_ID from '@salesforce/user/Id';
import NAME_FIELD from '@salesforce/schema/User.Name';
import TECH_TYPE_FIELD from '@salesforce/schema/User.tech_typePrestataire__c';

export default class PortalHeader extends NavigationMixin(LightningElement) {
    @api portalTitle = 'Portail Prestataires';
    
    userData;
    userName = 'Chargement...';
    userType = 'Chargement...';
    userInitials = '...';
    isMenuOpen = false;

    @wire(getRecord, { recordId: USER_ID, fields: [NAME_FIELD, TECH_TYPE_FIELD] })
    wiredUser({ error, data }) {
        if (data) {
            const fullName = getFieldValue(data, NAME_FIELD);
            this.userName = fullName;
            this.userType = getFieldValue(data, TECH_TYPE_FIELD) || 'Prestataire';
            this.userInitials = this.calculateInitials(fullName);
        } else if (error) {
            console.error(error);
            this.userName = 'Erreur';
            this.userType = 'Erreur';
        }
    }

    toggleMenu() {
        this.isMenuOpen = !this.isMenuOpen;
    }

    handleLogout() {
        // Defines the definitive logout URL for the current community
        const logoutUrl = `${basePath}/secur/logout.jsp`;
        window.location.replace(logoutUrl);
    }

    get displayTitle() {
        return `Portail Prestataires`;
    }

    get displayInfo() {
        return `${this.userType} | ${this.userName}`;
    }

    calculateInitials(name) {
        if (!name) return '??';
        const parts = name.split(' ');
        if (parts.length >= 2) {
            return (parts[0][0] + parts[1][0]).toUpperCase();
        }
        return name.substring(0, 2).toUpperCase();
    }
}