import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
// Ajouter les imports en haut
import getTypeSinistre  from '@salesforce/apex/AutoMissionnementAvocatController.getTypeSinistre';
import getNatureDossier from '@salesforce/apex/AutoMissionnementAvocatController.getNatureDossier';
import getJuridictions  from '@salesforce/apex/AutoMissionnementAvocatController.getJuridictions';
import getBranches from '@salesforce/apex/AutoMissionnementAvocatController.getBranches';
import getNaturesMission from '@salesforce/apex/AutoMissionnementAvocatController.getNaturesMission';
import createMission from '@salesforce/apex/AutoMissionnementAvocatController.createMission';

export default class AutoMissionnementAvocat extends LightningElement {

    // ─── Navigation étapes ───
    @track currentStep = 1;
    @track isLoading   = false;
    @track isSuccess   = false;
    missionCreeeId     = '';

    // ─── Données formulaire ───
    @track formData = {
        branche              : '',
        natureMission        : '',
        typeSinistre         : '',
        numeroPolice         : '',
        numeroSinistre       : '',
        dateSurvenance       : '',
        dateNomination       : '',
        numeroDossier        : '',
        anneeDossier         : '',
        numOrdre             : '',
        numChambre           : '',
        // Phase toujours fixée à 1ère instance pour l'auto-missionnement
        degreTribunal        : '1ère instance',
        juridiction          : '',
        natureDossier        : '',
        referencePrestataire : '',
    };

    // ─── Personnes ───
    @track personnes   = [];
    @track newPersonne = {
        type          : '',
        civilite      : '',
        nom           : '',
        prenom        : '',
        dateNaissance : '',
        etatSante     : '',
    };

    // ─── Options picklists ───
    @track brancheOptions = [];
    @track natureOptions  = [];

    // Juridiction filtrée : uniquement TPI pour 1ère instance
@track typeSinistreOptions  = [];
@track natureDossierOptions = [];
@track juridictionOptions   = [];
    // ─── Erreurs ───
    @track errors = {};

    // ─────────────────────────────────────────────
    // LIFECYCLE
    // ─────────────────────────────────────────────
connectedCallback() {
    getBranches()
        .then(result => { this.brancheOptions = result; })
        .catch(() => { this.showToast('Erreur', 'Impossible de charger les branches', 'error'); });

    getTypeSinistre()
        .then(result => { this.typeSinistreOptions = result; })
        .catch(() => { this.showToast('Erreur', 'Impossible de charger les types de sinistre', 'error'); });

    getNatureDossier()
        .then(result => { this.natureDossierOptions = result; })
        .catch(() => { this.showToast('Erreur', 'Impossible de charger les natures de dossier', 'error'); });

    getJuridictions()
        .then(result => { this.juridictionOptions = result; })
        .catch(() => { this.showToast('Erreur', 'Impossible de charger les juridictions', 'error'); });
}

    // ─────────────────────────────────────────────
    // GETTERS — Navigation étapes
    // ─────────────────────────────────────────────
    get isStep1() { return this.currentStep === 1 && !this.isSuccess; }
    get isStep2() { return this.currentStep === 2 && !this.isSuccess; }
    get isStep3() { return this.currentStep === 3 && !this.isSuccess; }

    get stepClass1() {
        return this.currentStep === 1 ? 'step active' : 'step done';
    }
    get stepClass2() {
        if (this.currentStep === 2) return 'step active';
        if (this.currentStep > 2)  return 'step done';
        return 'step';
    }
    get stepClass3() {
        return this.currentStep === 3 ? 'step active' : 'step';
    }

    // ─────────────────────────────────────────────
    // GETTERS — Affichage conditionnel sections judiciaires
    // ─────────────────────────────────────────────
    get showTypeSinistre() {
        return this.formData.branche === 'AT';
    }

    get showJudiciaireComplet() {
        const b = this.formData.branche;
        const n = this.formData.natureMission;
        return (
            b === 'RD' ||
            b === 'AT' ||
            (b === 'Autocorporel' && n === 'Défense compagnie')
        );
    }

    get showJudiciairePartiel() {
        const b = this.formData.branche;
        const n = this.formData.natureMission;
        return (
            b === 'Autocorporel' &&
            n !== 'Défense compagnie' &&
            n !== ''
        );
    }

    get showDossierParsed() {
        return this.formData.anneeDossier !== '';
    }

    get isNatureDisabled() {
        return this.formData.branche === '';
    }

    get hasPersonnes() {
        return this.personnes.length > 0;
    }

    // ─────────────────────────────────────────────
    // HANDLERS — Étape 1
    // ─────────────────────────────────────────────
    handleBrancheChange(event) {
        this.formData = {
            ...this.formData,
            branche       : event.target.value,
            natureMission : '',
        };
        this.errors        = { ...this.errors, branche: '' };
        this.natureOptions = [];

        if (this.formData.branche) {
            getNaturesMission({ branche: this.formData.branche })
                .then(result => {
                    this.natureOptions = result;
                })
                .catch(() => {
                    this.showToast('Erreur', 'Impossible de charger les natures', 'error');
                });
        }
    }

    handleNatureChange(event) {
        this.formData = { ...this.formData, natureMission: event.target.value };
        this.errors   = { ...this.errors, natureMission: '' };
    }

    // ─────────────────────────────────────────────
    // HANDLERS — Champs génériques
    // ─────────────────────────────────────────────
    handleFieldChange(event) {
        const field   = event.target.dataset.field;
        this.formData = { ...this.formData, [field]: event.target.value };
        this.errors   = { ...this.errors, [field]: '' };
    }

    handleDossierChange(event) {
        const val   = event.target.value;
        const parts = val.split('/');
        this.formData = {
            ...this.formData,
            numeroDossier : val,
            anneeDossier  : parts[0] ? parts[0].trim() : '',
            numOrdre      : parts[1] ? parts[1].trim() : '',
            numChambre    : parts[2] ? parts[2].trim() : '',
        };
    }

    // ─────────────────────────────────────────────
    // HANDLERS — Personnes étape 3
    // ─────────────────────────────────────────────
    handlePersonneField(event) {
        const field      = event.target.dataset.field;
        this.newPersonne = { ...this.newPersonne, [field]: event.target.value };
    }

    handleAjouterPersonne() {
        if (
            !this.newPersonne.type         ||
            !this.newPersonne.civilite     ||
            !this.newPersonne.nom          ||
            !this.newPersonne.prenom       ||
            !this.newPersonne.dateNaissance
        ) {
            this.errors = {
                ...this.errors,
                personne: 'Veuillez renseigner tous les champs obligatoires.'
            };
            return;
        }

        const doublon = this.personnes.find(p =>
            p.nom.toLowerCase()    === this.newPersonne.nom.toLowerCase()    &&
            p.prenom.toLowerCase() === this.newPersonne.prenom.toLowerCase() &&
            p.dateNaissance        === this.newPersonne.dateNaissance
        );
        if (doublon) {
            this.errors = { ...this.errors, personne: 'Cette personne est déjà dans la liste.' };
            return;
        }

        this.personnes = [ ...this.personnes, { ...this.newPersonne, key: Date.now() } ];
        this.newPersonne = { type: '', civilite: '', nom: '', prenom: '', dateNaissance: '', etatSante: '' };
        this.errors = { ...this.errors, personne: '', personnesListe: '' };
    }

    handleSupprimerPersonne(event) {
        const idx      = parseInt(event.target.dataset.index, 10);
        this.personnes = this.personnes.filter((_, i) => i !== idx);
    }

    // ─────────────────────────────────────────────
    // NAVIGATION étapes
    // ─────────────────────────────────────────────
    handleSuivant() {
        if (this.currentStep === 1 && !this.validerEtape1()) return;
        if (this.currentStep === 2 && !this.validerEtape2()) return;
        this.currentStep++;
    }

    handlePrecedent() {
        this.currentStep--;
    }

    handleAnnuler() {
        this.dispatchEvent(new CustomEvent('annuler'));
    }

    handleNouvelleMission() {
        this.currentStep   = 1;
        this.isSuccess     = false;
        this.natureOptions = [];
        this.formData      = {
            branche              : '',
            natureMission        : '',
            typeSinistre         : '',
            numeroPolice         : '',
            numeroSinistre       : '',
            dateSurvenance       : '',
            dateNomination       : '',
            numeroDossier        : '',
            anneeDossier         : '',
            numOrdre             : '',
            numChambre           : '',
            degreTribunal        : '1ère instance',
            juridiction          : '',
            natureDossier        : '',
            referencePrestataire : '',
        };
        this.personnes = [];
        this.errors    = {};
    }

    // ─────────────────────────────────────────────
    // VALIDATION
    // ─────────────────────────────────────────────
    validerEtape1() {
        const errs = {};

        if (!this.formData.branche)
            errs.branche = 'La branche est obligatoire.';

        if (!this.formData.natureMission)
            errs.natureMission = 'La nature de mission est obligatoire.';

        if (this.formData.branche === 'AT' && !this.formData.typeSinistre)
            errs.typeSinistre = 'Le type de sinistre est obligatoire pour la branche AT.';

        this.errors = errs;
        return Object.keys(errs).length === 0;
    }

    validerEtape2() {
        const errs = {};

        if (!this.formData.dateSurvenance)
            errs.dateSurvenance = 'La date de survenance est obligatoire.';

        if (!this.formData.dateNomination)
            errs.dateNomination = 'La date de nomination est obligatoire.';

        this.errors = errs;
        return Object.keys(errs).length === 0;
    }

    // ─────────────────────────────────────────────
    // SOUMISSION
    // ─────────────────────────────────────────────
    handleSoumettre() {
        if (this.personnes.length === 0) {
            this.errors = {
                ...this.errors,
                personnesListe: 'Au moins une personne impliquée est obligatoire.'
            };
            return;
        }

        this.isLoading = true;

        const personnesStr = this.personnes
            .map(p => `${p.type}|${p.civilite}|${p.nom}|${p.prenom}|${p.dateNaissance}|${p.etatSante}`)
            .join('\n');

        const mission = {
            Branche__c                    : this.formData.branche,
            Nature_Mission__c             : this.formData.natureMission,
            Type_de_sinistre__c           : this.formData.typeSinistre         || null,
            Numero_police__c              : this.formData.numeroPolice          || null,
            Numero_sinistre__c            : this.formData.numeroSinistre        || null,
            Date_survenance__c            : this.formData.dateSurvenance        || null,
            Date_de_nomination__c         : this.formData.dateNomination        || null,
            Numero_de_dossier_tribunal__c : this.formData.numeroDossier         || null,
            Annee_dossier__c              : this.formData.anneeDossier
                                            ? parseInt(this.formData.anneeDossier, 10)
                                            : null,
            Numero_ordre_dossier__c       : this.formData.numOrdre              || null,
            Numero_de_chambre__c          : this.formData.numChambre            || null,
            Degre_de_tribunal__c          : '1ère instance', // Toujours fixé
            Juridiction__c                : this.formData.juridiction           || null,
            Nature_de_dossier__c          : this.formData.natureDossier         || null,
            ReferencePrestataire__c       : this.formData.referencePrestataire  || null,
            Personnes_impliquees__c       : personnesStr,
            Type_Prestataire__c           : 'Avocat',
            ParentId__c                   : null, // Toujours null = mission mère
        };

        createMission({ mission })
            .then(id => {
                this.missionCreeeId = id;
                this.isSuccess      = true;
                this.isLoading      = false;
                this.dispatchEvent(new CustomEvent('success', { detail: { id } }));
            })
            .catch(error => {
                this.isLoading = false;
                this.showToast('Erreur', error.body?.message || 'Erreur lors de la création', 'error');
            });
    }

    // ─────────────────────────────────────────────
    // HELPER
    // ─────────────────────────────────────────────
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}