import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';

export default class UploadFileItem extends NavigationMixin(LightningElement) {
    @api recordId;
    @api sObjectName;
    @track isLoading = false;
    @track localUploadedFiles = [];
    @track _file;

    get isMobileDevice() {
        return FORM_FACTOR === 'Small';
    }


    @api
    get file() {
        return this._file;
    }
    set file(value) {
        this._file = value;
        // When parent updates file (e.g. after load), sync to local state
        // We preserve selection state if IDs match
        if (value && value.uploadedFiles) {
            this.syncLocalFiles(value.uploadedFiles);
        } else {
            this.localUploadedFiles = [];
        }
    }

    syncLocalFiles(newFiles) {
        // Map current selection state
        const selectionMap = new Map();
        this.localUploadedFiles.forEach(f => {
            if (f.selected) selectionMap.set(f.contentDocumentId, true);
        });

        // specific check: if we just deleted items, we might want to clear selection or keep it?
        // usually if we reload from server, we just reset selection unless we want to be fancy.
        // Simplified: Reset selection on data refresh to avoid ghost selections
        
        // However, if we are just entering selection mode, we want to copy.
        // Check if we are in specific mode? 
        
        // Let's just create a deep copy to allow mutation
        this.localUploadedFiles = newFiles.map(f => ({
            ...f,
            selected: false // Reset selection on new data load
        }));
    }
    
    @track isAccordionExpanded = false;
    @track isSelectionMode = false;

    get isDisabled() {
        if (this._file?.disabled) return true;
        if (this._file?.alreadyUploaded && !this._file?.allowMultipleUpload) return true;
        return false;
    }

    get isUploaded() {
        return this._file?.alreadyUploaded || false;
    }

    get fileLabel() {
        return this._file?.fileLabel || '';
    }

    get contentDocumentId() {
        return this._file?.contentDocumentId || '';
    }

    get isRequired() {
        return this._file?.required || false;
    }

    get uploadContainerClass() {
        return `upload-container ${this.isUploaded ? 'uploaded' : ''} ${this.isRequired ? 'required-file' : ''}`;
    }

    get allowMultiple() {
        return this._file?.allowMultipleUpload || false;
    }

    get uploadedFiles() {
        // Return local state which acts as the source of truth for UI
        return this.localUploadedFiles;
    }

    get cardClass() {
        return `upload-card ${this.hasUploadedFiles ? 'has-files' : ''}`;
    }

    get hasUploadedFiles() {
        return this.localUploadedFiles.length > 0;
    }

    get uploadedFilesCount() {
        return this.localUploadedFiles.length;
    }

    get filesCountLabel() {
        const count = this.localUploadedFiles.length;
        return count > 1 ? `${count} fichier(s)` : `${count} fichier`;
    }

    get accordionIconClass() {
        return `accordion-icon ${this.isAccordionExpanded ? 'expanded' : ''}`;
    }

    get filesListClass() {
        // If single file, force expanded view (no accordion behavior)
        if (!this.hasMultipleFiles && this.hasUploadedFiles) {
            return 'files-list-scroll expanded';
        }
        return `files-list-scroll ${this.isAccordionExpanded ? 'expanded' : ''}`;
    }

    get uniqueUploadName() {
        // Sanitize label for use in ID
        const safeLabel = (this._file?.fileLabel || 'default').replace(/[^a-zA-Z0-9-_]/g, '');
        return `fileUploader_${safeLabel}_${this._file?.uniqueId || ''}`;
    }

    get hasMultipleFiles() {
        return this.localUploadedFiles.length > 1;
    }

    get selectedFilesCount() {
        return this.localUploadedFiles.filter(f => f.selected).length;
    }

    get allSelected() {
        return this.localUploadedFiles.length > 0 && this.localUploadedFiles.every(f => f.selected);
    }

    get isDeleteDisabled() {
        return this.selectedFilesCount === 0;
    }

    get deleteBtnClass() {
        return `header-action-btn delete-btn ${this.isDeleteDisabled ? 'disabled' : ''}`;
    }

    get getFileItemClass() {
        return this.hasMultipleFiles ? 'file-item has-checkbox' : 'file-item';
    }

    toggleAccordion() {
        this.isAccordionExpanded = !this.isAccordionExpanded;
    }

    handleSelectAll(event) {
        event.stopPropagation();
        const isChecked = event.target.checked;
        // set all to the master checkbox state
        this.localUploadedFiles = this.localUploadedFiles.map(f => ({...f, selected: isChecked}));
    }

    handleDeleteFile(event) {
        event.stopPropagation();
        const fileId = event.target.dataset.fileId;
        
        const deleteEvent = new CustomEvent('deleteall', {
            detail: {
                fileWrapper: this._file,
                fileIds: [fileId] // Pass single ID
            },
            bubbles: true,
            composed: true
        });
        this.dispatchEvent(deleteEvent);
    }

    handleFileSelection(event) {
        event.stopPropagation(); // Stop propagation to avoid accordion toggle
        const fileId = event.target.dataset.fileId;
        const isChecked = event.target.checked;
        
        this.localUploadedFiles = this.localUploadedFiles.map(f => {
            if (f.contentDocumentId === fileId) {
                return {...f, selected: isChecked};
            }
            return f;
        });
    }

    handleDeleteSelected(event) {
        event.stopPropagation();
        
        const selectedFiles = this.localUploadedFiles.filter(f => f.selected);
        if (selectedFiles.length === 0) {
            return; 
        }
        
        const deleteEvent = new CustomEvent('deleteall', {
            detail: {
                fileWrapper: this._file,
                fileIds: selectedFiles.map(f => f.contentDocumentId)
            },
            bubbles: true,
            composed: true
        });
        this.dispatchEvent(deleteEvent);
        
        this.isSelectionMode = false;
    }

    handleDeleteAll(event) {
        event.stopPropagation();
        
        const deleteAllEvent = new CustomEvent('deleteall', {
            detail: {
                fileWrapper: this._file,
                fileIds: this.localUploadedFiles.map(f => f.contentDocumentId)
            },
            bubbles: true,
            composed: true
        });
        this.dispatchEvent(deleteAllEvent);
    }

    handlePreviewAll(event) {
        event.stopPropagation();
        
        const previewAllEvent = new CustomEvent('previewall', {
            detail: {
                fileWrapper: this._file,
                fileIds: this.localUploadedFiles.map(f => f.contentDocumentId)
            },
            bubbles: true,
            composed: true
        });
        this.dispatchEvent(previewAllEvent);
    }

    handleManageMetadata(event) {
        event.stopPropagation();
        const manageEvent = new CustomEvent('managemetadata', {
            bubbles: true,
            composed: true
        });
        this.dispatchEvent(manageEvent);
    }

    handleUploadFinished(event) {
        this.isLoading = true;
        
        const uploadEvent = new CustomEvent('uploadfinished', {
            detail: {
               fileWrapper: this._file,
               uploadedFiles: event.detail.files 
            },
             bubbles: true,
             composed: true
        });
        this.dispatchEvent(uploadEvent);
        
        setTimeout(() => {
            this.isLoading = false;
        }, 1000);
    }

    handlePreviewFile() {
        if (this.contentDocumentId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: {
                    pageName: 'filePreview'
                },
                state: {
                    selectedRecordId: this.contentDocumentId
                }
            });
        }
    }

    handlePreviewUploadedFile(event) {
        event.stopPropagation();
        const fileId = event.currentTarget.dataset.fileId;
        if (fileId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: {
                    pageName: 'filePreview'
                },
                state: {
                    selectedRecordId: fileId
                }
            });
        }
    }

    stopProp(event) {
        event.stopPropagation();
    }
}
