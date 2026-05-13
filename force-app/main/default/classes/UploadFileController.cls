/**
* @author 
* @date Création 27/11/2020
* @date Modification 
* @description UploadFileController - Upload file
*/
public with sharing class UploadFileController{
    
    @AuraEnabled
    public static List<WR008_UploadFileWrapper> getFiles( Id recordId, String objectApiName, String filterValue, String filter ){
        List<WR008_UploadFileWrapper> filesWrapper = new List<WR008_UploadFileWrapper>();
        
        // Automatic record type detection
        String recordType = '';
        if (recordId != null) {
            try {
                String sObjName = recordId.getSObjectType().getDescribe().getName();
                if (recordId.getSObjectType().getDescribe().fields.getMap().containsKey('RecordTypeId')) {
                    String query = 'SELECT RecordType.DeveloperName FROM ' + sObjName + ' WHERE Id = :recordId LIMIT 1';
                    List<SObject> records = Database.query(query);
                    if (!records.isEmpty()) {
                        SObject rt = records[0].getSObject('RecordType');
                        if (rt != null) {
                            recordType = (String)rt.get('DeveloperName');
                        }
                    }
                }
            } catch (Exception e) {
                System.debug('Error fetching record type: ' + e.getMessage());
            }
        }

        List<ContentDocumentLink> ContvList = new List<ContentDocumentLink>();

        Map<String, List<ContentDocumentLink>> mapFileNameContentDocLinks = new Map<String, List<ContentDocumentLink>>();
        
        try{
            String soqlQuery = 'Select Id, ContentDocumentId, LinkedEntityId, ContentDocument.Title From ContentDocumentLink WHERE LinkedEntityId =:recordId';
            List<ContentDocumentLink> recordContentDocumentLinks = new List<ContentDocumentLink>((List<ContentDocumentLink>)Database.query(soqlQuery));
        
            for(ContentDocumentLink contentDocumentLink : recordContentDocumentLinks){
                List<String> fileNameSections = contentDocumentLink.ContentDocument.Title.split('_');
                system.debug('fileNameSections'+fileNameSections);
                if(fileNameSections != null && fileNameSections.size() > 1){
                    String fileLabel = fileNameSections[1];
                    if(!mapFileNameContentDocLinks.containsKey(fileLabel)){
                        mapFileNameContentDocLinks.put(fileLabel, new List<ContentDocumentLink>());
                    }
                    mapFileNameContentDocLinks.get(fileLabel).add(contentDocumentLink);
                    system.debug('fileNameSections[1]'+fileNameSections[1]);
                }
            
            }
            
            List<DA_UploadFile__mdt> ListMetadata=new List<DA_UploadFile__mdt>();
                
            List<DA_UploadFile__mdt> filesSettings = new List<DA_UploadFile__mdt>((List<DA_UploadFile__mdt>) Database.query('Select Label__c,SuccessMessage__c,DeveloperName,AllowMultipleUpload__c, Filter_Field_API_Name__c, Filtre__c, RecordType__c, Required__c from DA_UploadFile__mdt where ObjectName__c =:objectApiName ORDER BY Label__c, Required__c ASC'));

            for(DA_UploadFile__mdt fileSetting : filesSettings){
                // Filtering Logic: Include if no filter defined OR matches provided value
                // Check 1: Dynamic Filter Field (e.g. Type_de_marchand__c renamed to Filter_Field_API_Name__c)
                if (String.isNotBlank(fileSetting.Filter_Field_API_Name__c) && fileSetting.Filter_Field_API_Name__c != filterValue) {
                    continue;
                }
                
                // Check 2: Static Filter (new 'filter' parameter)
                // Assuming the metadata field is named Filtre__c based on user request "named filter"
                if (String.isNotBlank(fileSetting.Filtre__c) && fileSetting.Filtre__c != filter) {
                    continue;
                }

                // Check 3: Record Type Filter
                if (String.isNotBlank(fileSetting.RecordType__c) && fileSetting.RecordType__c != recordType) {
                    continue;
                }

                WR008_UploadFileWrapper fileWrapper = new WR008_UploadFileWrapper();
                fileWrapper.fileLabel 					= fileSetting.Label__c;
                fileWrapper.finishUploadSuccessMessage	= fileSetting.SuccessMessage__c;
                fileWrapper.allowMultipleUpload			= fileSetting.AllowMultipleUpload__c != null ? fileSetting.AllowMultipleUpload__c : false;
                fileWrapper.required                    = fileSetting.Required__c != null ? fileSetting.Required__c : false;
    
                
                if(mapFileNameContentDocLinks.containsKey(fileSetting.Label__c)){
                    List<ContentDocumentLink> uploadedDocs = mapFileNameContentDocLinks.get(fileSetting.Label__c);
                    fileWrapper.alreadyUploaded = true;
                    
                    // Populate the uploadedFiles list
                    for(ContentDocumentLink cdl : uploadedDocs){
                        WR008_UploadFileWrapper.UploadedFileInfo fileInfo = new WR008_UploadFileWrapper.UploadedFileInfo();
                        fileInfo.contentDocumentId = cdl.ContentDocumentId;
                        fileInfo.title = cdl.ContentDocument.Title;
                        fileWrapper.uploadedFiles.add(fileInfo);
                    }
                    
                    // Keep backward compatibility: set first file as the main one
                    if(uploadedDocs.size() > 0){
                        fileWrapper.contentDocumentId = uploadedDocs[0].ContentDocumentId;
                        fileWrapper.title = uploadedDocs[0].ContentDocument.Title;
                    }
                }else{
                    fileWrapper.alreadyUploaded = false;
                }
                filesWrapper.add(fileWrapper);
            }
            
        }
        catch(Exception ex){
            throw new AuraHandledException(ex.getMessage());
        }
        return filesWrapper;
    }

    @AuraEnabled
    public static WR008_UploadFileWrapper renameLastFileToMatchMdt( Id recordId, String objectApiName, WR008_UploadFileWrapper fileWrapper ){
        String fileName = '';
        List<ContentVersion> contentVersions = new List<ContentVersion>();
        Integer filesProcessed = 0;
        
        try {
            String dateString = DateTime.now().format('dd/MM/yyyy');
            fileName = dateString + '_' + fileWrapper.fileLabel.trim();
            
            Set<Id> recordContentDocIds = new Set<Id>();
            for(ContentDocumentLink cdl : [SELECT ContentDocumentId 
                                           FROM ContentDocumentLink 
                                           WHERE LinkedEntityId = :recordId]) {
                recordContentDocIds.add(cdl.ContentDocumentId);
            }
            
            for(ContentVersion cv :[SELECT Id, Title, CreatedDate, CreatedBy.Id, ContentDocument.Id, ContentDocumentId 
                                    FROM ContentVersion 
                                    WHERE CreatedBy.Id = :UserInfo.getUserId() 
                                    AND ContentDocumentId IN :recordContentDocIds
                                    ORDER BY CreatedDate DESC 
                                    LIMIT 50]){
                contentVersions.add(cv);
            }
            
            Integer filesToProcess = fileWrapper.allowMultipleUpload ? 10 : 1;
            
            Integer maxExistingNumber = 0;
            for(ContentDocumentLink cdl : [SELECT ContentDocument.Title 
                                           FROM ContentDocumentLink 
                                           WHERE LinkedEntityId = :recordId]) {
                
                String title = cdl.ContentDocument.Title;
                if(title.startsWithIgnoreCase(fileName)) {
                     String remainder = title.substring(fileName.length());
                     if(remainder.startsWith('_')) {
                         String suffix = remainder.substring(1);
                         if(suffix.isNumeric()) {
                             Integer fileNumber = Integer.valueOf(suffix);
                             if(fileNumber > maxExistingNumber) {
                                 maxExistingNumber = fileNumber;
                             }
                         }
                     }
                }
            }
            
            Pattern datePattern = Pattern.compile('\\d{2}/\\d{2}/\\d{4}_.*');
            Integer currentFileNumber = maxExistingNumber;
            
            if(!contentVersions.isEmpty()){
                List<ContentVersion> versionsToUpdate = new List<ContentVersion>();
                
                for(Integer i = 0; i < contentVersions.size() && filesProcessed < filesToProcess; i++){
                    ContentVersion cv = contentVersions[i];
                    Matcher dateMatcher = datePattern.matcher(cv.Title);
                    Boolean isAlreadyRenamed = dateMatcher.matches();
                    
                    if(!isAlreadyRenamed){
                        currentFileNumber++;
                        cv.Title = fileWrapper.allowMultipleUpload ? (fileName + '_' + currentFileNumber) : fileName;
                        versionsToUpdate.add(cv);
                        filesProcessed++;
                        
                        if(filesProcessed == 1){
                            fileWrapper.alreadyUploaded = true;
                            fileWrapper.disabled = !fileWrapper.allowMultipleUpload;
                            fileWrapper.title = cv.Title;
                            fileWrapper.contentDocumentId = cv.ContentDocument.Id;
                        }
                    }
                }
                
                if(!versionsToUpdate.isEmpty()){
                    update versionsToUpdate;
                }
            }
            
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
        return fileWrapper;
    }

    @AuraEnabled
    public static String getSobjectName( Id recordId){
        return recordId.getSObjectType().getDescribe().getName();
    }
    
    @AuraEnabled
    public static void deleteFile(String contentDocumentId) {
        try {
            if (String.isBlank(contentDocumentId)) {
                throw new AuraHandledException('Content Document ID is required.');
            }
            
            List<ContentDocument> docsToDelete = [
                SELECT Id 
                FROM ContentDocument 
                WHERE Id = :contentDocumentId 
                LIMIT 1
            ];
            
            if (docsToDelete.isEmpty()) {
                throw new AuraHandledException('File not found.');
            }
            
            delete docsToDelete;
            
        } catch (DmlException e) {
            throw new AuraHandledException('Error deleting file: ' + e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Error: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteFiles(List<String> contentDocumentIds) {
        try {
            if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
                throw new AuraHandledException('Content Document IDs are required.');
            }
            
            List<ContentDocument> docsToDelete = [
                SELECT Id 
                FROM ContentDocument 
                WHERE Id IN :contentDocumentIds
            ];
            
            if (docsToDelete.isEmpty()) {
                throw new AuraHandledException('No files found to delete.');
            }
            
            delete docsToDelete;
            
        } catch (DmlException e) {
            throw new AuraHandledException('Error deleting files: ' + e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Error: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String getRelatedRecordId(Id recordId, String targetObjectApiName) {
        if (recordId == null || String.isBlank(targetObjectApiName)) {
            return null;
        }

        try {
            Schema.SObjectType currentSObjectType = recordId.getSObjectType();
            String currentObjectName = currentSObjectType.getDescribe().getName();
            
            if (currentObjectName.equalsIgnoreCase(targetObjectApiName)) {
                return recordId;
            }

            Map<String, Schema.SObjectField> fieldsMap = currentSObjectType.getDescribe().fields.getMap();
            String lookupFieldApiName = null;

            for (String fieldName : fieldsMap.keySet()) {
                Schema.DescribeFieldResult fieldDescribe = fieldsMap.get(fieldName).getDescribe();
                if (fieldDescribe.getType() == Schema.DisplayType.REFERENCE) {
                    for (Schema.SObjectType referenceTo : fieldDescribe.getReferenceTo()) {
                        if (referenceTo.getDescribe().getName().equalsIgnoreCase(targetObjectApiName)) {
                            lookupFieldApiName = fieldDescribe.getName();
                            break;
                        }
                    }
                }
                if (lookupFieldApiName != null) {
                    break; 
                }
            }

            if (lookupFieldApiName != null) {
                String query = 'SELECT ' + lookupFieldApiName + ' FROM ' + currentObjectName + ' WHERE Id = :recordId LIMIT 1';
                SObject record = Database.query(query);
                return (String) record.get(lookupFieldApiName);
            }
            
            return null;

        } catch (Exception e) {
            throw new AuraHandledException('Error resolving related record ID: ' + e.getMessage());
        }
    }

}
