import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getRelatedRecordId from '@salesforce/apex/UploadFileController.getRelatedRecordId';
import getFiles from '@salesforce/apex/UploadFileController.getFiles';
import renameLastFileToMatchMdt from '@salesforce/apex/UploadFileController.renameLastFileToMatchMdt';
import getSobjectName from '@salesforce/apex/UploadFileController.getSobjectName';
import deleteFile from '@salesforce/apex/UploadFileController.deleteFile';
import deleteFiles from '@salesforce/apex/UploadFileController.deleteFiles';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import PROFILE_NAME_FIELD from '@salesforce/schema/User.Profile.Name';

export default class UploadFileManager extends NavigationMixin(LightningElement) {
    @api recordId;
    @api configuredObjectApiName; // Renamed from objectApiName to avoid conflict
    @api objectApiName; // Standard LWC property for context-aware object name
    @api customLabel; // Optional: custom label for the header
    @api filterField; // Optional: API name of the field to filter by
    @api filter; // Optional: Static filter value passed from App Builder
    @api displayMode = 'RecordPage'; // RecordPage or Modal
    @api openByDefault = false;
    @api recordTypeField; // Deprecated - Logic is now automatic in Apex
    
    @track files = [];
    @track sObjectName = '';
    @track effectiveRecordId; // Resolved record ID (either current or related)
    @track isLoading = true;
    @track isAccordionOpen = false;
    @track componentReady = false;
    @track showDeleteModal = false;
    @track fileToDelete = null;
    @track filterValue;
    
    userProfileName;

    @wire(getRecord, { recordId: USER_ID, fields: [PROFILE_NAME_FIELD] })
    userRecord({ error, data }) {
        if (data) {
            this.userProfileName = getFieldValue(data, PROFILE_NAME_FIELD);
            console.log('userProfileName', this.userProfileName);
        } else if (error) {
            console.error('Error retrieving user profile name:', error);
        }
    }

    // Compute fields to fetch for filtering
    get recordFields() {
        if (this.filterField && this.sObjectName) {
            return [this.sObjectName + '.' + this.filterField];
        }
        return [];
    }

    // Fetch effective record (e.g. Account) to get the filter field value
    @wire(getRecord, { recordId: '$effectiveRecordId', fields: '$recordFields' })
    wiredContextRecord({ error, data }) {
        if (data) {
            if (this.filterField && this.sObjectName) {
                const newValue = getFieldValue(data, this.sObjectName + '.' + this.filterField);
                
                // Only reload if value actually changed to prevent loops
                // Check if newValue is different (handling nulls/undefined)
                if ((this.filterValue !== newValue) && (newValue !== undefined)) {
                    console.log('Filter Value Changed on Effective Record:', newValue);
                    this.filterValue = newValue;
                    if (this.componentReady) {
                        this.loadFiles();
                    }
                }
            }
        } else if (error) {
            console.error('Error loading filter field value:', error);
        }
    }

    connectedCallback() {
        console.log('configuredObjectApiName connectedCallback', this.configuredObjectApiName);
        console.log('objectApiName connectedCallback', this.objectApiName);
        console.log('recordId connectedCallback', this.recordId);
        
        this.initializeComponent();
        if (this.openByDefault) {
            this.isAccordionOpen = true;
        }

        // Écoute des évènements venant d'autres LWC pour ouvrir l'accordéon
        this.boundHandleMissingDocsEvent = this.handleMissingDocsEvent.bind(this);
        window.addEventListener('missingdocs', this.boundHandleMissingDocsEvent);
    }

    disconnectedCallback() {
        if (this.boundHandleMissingDocsEvent) {
            window.removeEventListener('missingdocs', this.boundHandleMissingDocsEvent);
        }
    }

    handleMissingDocsEvent(event) {
        if (event.detail && (event.detail.recordId === this.recordId || event.detail.recordId === this.effectiveRecordId)) {
            
            // Si l'événement cible un objet particulier (ex: DossierCommerciale__c) et que cette
            // instance d'uploadFileManager gère un autre objet configuré (ex: Compte), on l'ignore.
            if (event.detail.targetObjectApiName && this.sObjectName !== event.detail.targetObjectApiName) {
                return;
            }

            this.isAccordionOpen = true;
            
            // Scroll d'attention automatique
            setTimeout(() => {
                const header = this.template.querySelector('.accordion-header');
                if (header) header.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }, 100);
        }
    }

    async initializeComponent() {
        try {
            this.isLoading = true;
            await this.resolveContext();
            await this.loadFiles();
            this.componentReady = true;
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async resolveContext() {
        try {
            // 1. Determine Target Object Name
            if (this.configuredObjectApiName) {
                this.sObjectName = this.configuredObjectApiName;
            } else if (this.objectApiName) {
                this.sObjectName = this.objectApiName;
            } else if (this.recordId) {
                this.sObjectName = await getSobjectName({ recordId: this.recordId });
            } else {
                throw new Error('Either recordId, objectApiName, or configuredObjectApiName must be provided');
            }

            // 2. Resolve Effective Record ID
            // If configuredObjectApiName is present and differs from current context, try to resolve via lookup
            if (this.configuredObjectApiName && this.recordId) {
                
                // We need to know the current object name to compare
                let currentContextObject = this.objectApiName;
                if (!currentContextObject) {
                     currentContextObject = await getSobjectName({ recordId: this.recordId });
                }

                if (this.configuredObjectApiName !== currentContextObject) {
                    console.log(`Attempting to resolve related record ID from ${currentContextObject} to ${this.configuredObjectApiName}`);
                    
                    const relatedId = await getRelatedRecordId({
                        recordId: this.recordId,
                        targetObjectApiName: this.configuredObjectApiName
                    });

                    if (relatedId) {
                        this.effectiveRecordId = relatedId;
                        console.log('Resolved related effectiveRecordId:', this.effectiveRecordId);
                    } else {
                        console.warn('Could not find related record ID. Falling back to current recordId.');
                        this.effectiveRecordId = this.recordId;
                    }
                } else {
                    this.effectiveRecordId = this.recordId;
                }
            } else {
                this.effectiveRecordId = this.recordId;
            }

        } catch (error) {
            throw new Error('Failed to resolve context: ' + (error.body?.message || error.message));
        }
    }

    async loadFiles() {
        try {
            console.log('Loading files for Record:', this.effectiveRecordId, 'Object:', this.sObjectName, 'Filter:', this.filterValue, 'StaticFilter:', this.filter);

            const result = await getFiles({
                recordId: this.effectiveRecordId,
                objectApiName: this.sObjectName,
                filterValue: this.filterValue,
                filter: this.filter
            });
            this.files = result.map((file, index) => {
                
                // Sort uploaded files by name
                if (file.uploadedFiles && file.uploadedFiles.length > 0) {
                    file.uploadedFiles.sort((a, b) => a.title.localeCompare(b.title));
                }
                return {
                    ...file,
                    // Use stable ID based on label and index to prevents unnecessary re-renders
                    uniqueId: `${file.fileLabel.replace(/\s+/g, '_')}_${index}`
                };
            });
        } catch (error) {
            throw new Error('Failed to load files: ' + error.body.message);
        }
    }

    handleToggleAccordion() {
        this.isAccordionOpen = !this.isAccordionOpen;
    }

    handleUploadFinished(event) {
        const { fileWrapper, uploadedFiles } = event.detail;
        console.log('Uploaded files:', uploadedFiles);
        this.renameFile(fileWrapper, uploadedFiles ? uploadedFiles.length : 1);
    }

    handleDeleteFile(event) {
        const { fileId, fileWrapper } = event.detail;
        this.fileToDelete = [fileId]; // Store as array for consistency
        this.showDeleteModal = true;
    }

    handleDeleteAll(event) {
        const { fileIds, fileWrapper } = event.detail;
        this.fileToDelete = fileIds; // Store array of file IDs
        this.showDeleteModal = true;
    }

    handleModalConfirm() {
        this.showDeleteModal = false;
        if (this.fileToDelete && this.fileToDelete.length > 0) {
            this.performDelete(this.fileToDelete);
        }
    }

    handleModalCancel() {
        this.showDeleteModal = false;
        this.fileToDelete = null;
    }

    async performDelete(fileIds) {
        try {
            this.isLoading = true;
            
            const isMassDelete = Array.isArray(fileIds) && fileIds.length > 1;
            const idsToDelete = Array.isArray(fileIds) ? fileIds : [fileIds];
            
            if (isMassDelete) {
                // Batch delete
                await deleteFiles({ contentDocumentIds: idsToDelete });
            } else {
                // Single delete
                await deleteFile({ contentDocumentId: idsToDelete[0] });
            }
            
            // Reload files to refresh the list
            await this.loadFiles();
            
            const message = isMassDelete 
                ? `${idsToDelete.length} fichiers supprimés avec succès` 
                : 'Fichier supprimé avec succès';
            this.showToast('Succès', message, 'success');
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
            this.fileToDelete = null;
        }
    }

    handlePreviewAll(event) {
        const { fileIds } = event.detail;
        if (!fileIds || fileIds.length === 0) return;

        // Navigate to file preview with multiple IDs
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: {
                pageName: 'filePreview'
            },
            state: {
                selectedRecordId: fileIds[0], // Start with first file
                recordIds: fileIds.join(',') // Pass all IDs for carousel view
            }
        });
    }

    async renameFile(fileWrapper, fileCount) {
        try {
            const updatedFile = await renameLastFileToMatchMdt({
                recordId: this.effectiveRecordId,
                objectApiName: this.sObjectName,
                fileWrapper: fileWrapper
            });

            // Reload all files to get the updated list
            await this.loadFiles();
            
            const message = fileCount > 1 
                ? `${fileCount} fichiers téléchargés avec succès` 
                : 'Fichier téléchargé avec succès';

            this.showToast('Succès', message, 'success');
            this.refreshView();
        } catch (error) {
            this.handleError(error);
        }
    }

    handleError(error) {
        const errorMessage = error.body?.message || error.message || 'An unknown error occurred';
        this.showToast('Error', errorMessage, 'error', 'sticky');
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant,
                mode: mode
            })
        );
    }

    refreshView() {
        // Files are already reloaded in renameFile method
        // No need for additional refresh
    }

    get headerTitle() {
        // Use custom label if provided, otherwise default to 'Documents'
        if (this.customLabel) {
            return this.customLabel;
        }
        return 'Documents';
    }

    get accordionClass() {
        return this.isAccordionOpen ? 'accordion-header active' : 'accordion-header';
    }

    get panelClass() {
        return this.isAccordionOpen ? 'accordion-panel open' : 'accordion-panel';
    }

    get showAccordion() {
        return !this.openByDefault && this.displayMode !== 'Modal';
    }

    get deleteModalTitle() {
        const isMassDelete = this.fileToDelete && Array.isArray(this.fileToDelete) && this.fileToDelete.length > 1;
        return isMassDelete ? 'Confirmer la suppression multiple' : 'Confirmer la suppression';
    }

    get deleteModalMessage() {
        const isMassDelete = this.fileToDelete && Array.isArray(this.fileToDelete) && this.fileToDelete.length > 1;
        if (isMassDelete) {
            return `Êtes-vous sûr de vouloir supprimer ces ${this.fileToDelete.length} fichiers ?`;
        }
        return 'Êtes-vous sûr de vouloir supprimer ce fichier ?';
    }

    get hasFiles() {
        return this.files && this.files.length > 0;
    }

    get hasNoFiles() {
        return this.componentReady && (!this.files || this.files.length === 0);
    }


}
