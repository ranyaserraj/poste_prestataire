import { LightningElement, api } from 'lwc';

export default class DeleteConfirmModal extends LightningElement {
    @api isOpen = false;
    @api title;
    @api message;

    get modalClass() {
        return this.isOpen ? 'slds-modal slds-fade-in-open' : 'slds-modal';
    }

    get backdropClass() {
        return this.isOpen ? 'slds-backdrop slds-backdrop_open' : 'slds-backdrop';
    }

    handleConfirm() {
        this.dispatchEvent(new CustomEvent('confirm'));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }
}

