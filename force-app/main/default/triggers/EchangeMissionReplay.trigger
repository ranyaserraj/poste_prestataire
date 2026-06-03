trigger EchangeMissionReplay on Echange__c (after insert) {
    MissionEchangeReplayTriggerHandler.afterInsert(Trigger.new);
}
