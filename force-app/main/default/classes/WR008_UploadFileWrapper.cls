/**
* @author 
* @date Created 2020
* @description WR008_UploadFileWrapper - Wrapper class for file upload data
*/
public class WR008_UploadFileWrapper {
    @AuraEnabled public String fileLabel { get; set; }
    @AuraEnabled public String finishUploadSuccessMessage { get; set; }
    @AuraEnabled public Boolean alreadyUploaded { get; set; }
    @AuraEnabled public Boolean disabled { get; set; }
    @AuraEnabled public String contentDocumentId { get; set; }
    @AuraEnabled public String title { get; set; }
    @AuraEnabled public Boolean allowMultipleUpload { get; set; }
    @AuraEnabled public Boolean required { get; set; }
    @AuraEnabled public List<UploadedFileInfo> uploadedFiles { get; set; }
    
    public WR008_UploadFileWrapper() {
        this.alreadyUploaded = false;
        this.disabled = false;
        this.fileLabel = '';
        this.finishUploadSuccessMessage = '';
        this.contentDocumentId = '';
        this.title = '';
        this.allowMultipleUpload = false;
        this.required = false;
        this.uploadedFiles = new List<UploadedFileInfo>();
    }
    
    // Inner class to hold uploaded file information
    public class UploadedFileInfo {
        @AuraEnabled public String contentDocumentId { get; set; }
        @AuraEnabled public String title { get; set; }
    }
}
