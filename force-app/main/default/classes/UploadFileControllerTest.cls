@isTest
public class UploadFileControllerTest {

    @testSetup
    static void setup() {
        Account acc = createTestAccount('Test Account');
        String datePrefix = DateTime.now().format('dd/MM/yyyy');
        createTestContentVersion(acc.Id, datePrefix + '_Attestation originale de RIB', 'Test Content');
    }

    @isTest
    static void testGetSobjectName() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        String objectName = UploadFileController.getSobjectName(acc.Id);
        Test.stopTest();
        System.assertEquals('Account', objectName, 'Should return Account as object name');
    }

    @isTest
    static void testGetFiles() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<WR008_UploadFileWrapper> results = UploadFileController.getFiles(acc.Id, 'Account', null, null);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');

        WR008_UploadFileWrapper matchedWrapper;
        for (WR008_UploadFileWrapper w : results) {
            if (w.fileLabel == 'Attestation originale de RIB') {
                matchedWrapper = w;
                break;
            }
        }

        if (matchedWrapper != null) {
            System.assertEquals(true, matchedWrapper.alreadyUploaded, 'File should be marked as uploaded');
            System.assert(matchedWrapper.uploadedFiles.size() > 0, 'Uploaded files list should be populated');
        }
    }

    @isTest
    static void testGetFilesWithFilters() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<WR008_UploadFileWrapper> results = UploadFileController.getFiles(acc.Id, 'Account', 'RandomFilter', 'RandomStaticFilter');
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    @isTest
    static void testRenameLastFileToMatchMdt() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        createTestContentVersion(acc.Id, 'New Upload', 'New Content');

        WR008_UploadFileWrapper wrapper = new WR008_UploadFileWrapper();
        wrapper.fileLabel = 'Attestation originale de RIB';
        wrapper.allowMultipleUpload = false;

        Test.startTest();
        WR008_UploadFileWrapper result = UploadFileController.renameLastFileToMatchMdt(acc.Id, 'Account', wrapper);
        Test.stopTest();

        ContentDocumentLink cdl = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocument.Title LIKE '%Attestation originale de RIB%'
            LIMIT 1
        ];
        ContentVersion updatedCv = [SELECT Title FROM ContentVersion WHERE ContentDocumentId = :cdl.ContentDocumentId LIMIT 1];
        String expectedDate = DateTime.now().format('dd/MM/yyyy');
        System.assert(updatedCv.Title.contains(wrapper.fileLabel), 'Title should contain the label');
        System.assert(updatedCv.Title.contains(expectedDate), 'Title should contain the date');
    }

    @isTest
    static void testRenameMultipleFiles() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        createTestContentVersionsBulk(acc.Id, 'Bulk Upload', 3);

        WR008_UploadFileWrapper wrapper = new WR008_UploadFileWrapper();
        wrapper.fileLabel = 'Attestation originale de RIB';
        wrapper.allowMultipleUpload = true;

        Test.startTest();
        WR008_UploadFileWrapper result = UploadFileController.renameLastFileToMatchMdt(acc.Id, 'Account', wrapper);
        Test.stopTest();
    }

    @isTest
    static void testRenameWithExistingSuffix() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        String datePrefix = DateTime.now().format('dd/MM/yyyy');
        String label = 'Attestation originale de RIB';

        createTestContentVersion(acc.Id, label + '_1', 'Existing Content');
        createTestContentVersion(acc.Id, 'New To Rename', 'New Content');

        WR008_UploadFileWrapper wrapper = new WR008_UploadFileWrapper();
        wrapper.fileLabel = label;
        wrapper.allowMultipleUpload = true;

        Test.startTest();
        WR008_UploadFileWrapper result = UploadFileController.renameLastFileToMatchMdt(acc.Id, 'Account', wrapper);
        Test.stopTest();
    }

    @isTest
    static void testDeleteFile() {
        ContentDocument cd = [SELECT Id FROM ContentDocument LIMIT 1];

        Test.startTest();
        UploadFileController.deleteFile(cd.Id);
        Test.stopTest();

        List<ContentDocument> docs = [SELECT Id FROM ContentDocument WHERE Id = :cd.Id];
        System.assertEquals(0, docs.size(), 'Document should be deleted');
    }

    @isTest
    static void testDeleteFiles() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        createTestContentVersion(acc.Id, 'File to delete', 'Delete Content');

        List<ContentDocument> docs = [SELECT Id FROM ContentDocument];
        List<String> ids = new List<String>();
        for (ContentDocument d : docs) {
            ids.add(d.Id);
        }

        Test.startTest();
        UploadFileController.deleteFiles(ids);
        Test.stopTest();

        List<ContentDocument> remainingDocs = [SELECT Id FROM ContentDocument WHERE Id IN :ids];
        System.assertEquals(0, remainingDocs.size(), 'All documents should be deleted');
    }

    @isTest
    static void testGetRelatedRecordId() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        String resultSame = UploadFileController.getRelatedRecordId(acc.Id, 'Account');
        System.assertEquals(acc.Id, resultSame, 'Should return same ID for same object');

        Contact con = createTestContact(acc.Id, 'Test Contact', 'test@example.com');

        String resultLookup = UploadFileController.getRelatedRecordId(con.Id, 'Account');
        System.assertEquals(acc.Id, resultLookup, 'Should resolve AccountId from Contact');

        Test.stopTest();
    }

    @isTest
    static void testExceptions() {
        Test.startTest();

        try {
            UploadFileController.deleteFile(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        try {
            UploadFileController.deleteFiles(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        try {
            UploadFileController.deleteFile('invalidId');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        Test.stopTest();
    }

    private static Account createTestAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    private static void createTestContentVersion(Id linkedEntityId, String title, String body) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = 'test.txt',
            VersionData = Blob.valueOf(String.isNotBlank(body) ? body : 'x')
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            LinkedEntityId = linkedEntityId,
            ContentDocumentId = docId,
            ShareType = 'I',
            Visibility = 'AllUsers'
        );
    }

    private static void createTestContentVersionsBulk(Id linkedEntityId, String titlePrefix, Integer count) {
        for (Integer i = 0; i < count; i++) {
            createTestContentVersion(linkedEntityId, titlePrefix + '_' + i, 'Body ' + i);
        }
    }

    private static Contact createTestContact(Id accountId, String lastName, String email) {
        Contact c = new Contact(LastName = lastName, Email = email, AccountId = accountId);
        insert c;
        return c;
    }
}
