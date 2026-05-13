import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class CreerMission extends LightningElement {
    @track showModal = false;

    // Ouverture du modal
    handleClick() {
        console.log('Ouverture du modal demandée');
        this.showModal = true;
    }

    // Fermeture (backdrop ou croix)
    handleCloseModal() {
        console.log('Fermeture du modal');
        this.showModal = false;
    }

    // Annulation depuis le formulaire enfant
    handleAnnuler() {
        console.log('Annulation depuis le formulaire');
        this.showModal = false;
    }

    // Succès : mission créée
    handleSuccess(event) {
        console.log('Mission créée avec succès, ID:', event.detail.id);
        this.showModal = false;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Succès',
                message: `Mission créée ! ID: ${event.detail.id}`,
                variant: 'success'
            })
        );
    }
}