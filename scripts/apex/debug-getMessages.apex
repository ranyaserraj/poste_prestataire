Id mid = 'a0Dfj00000PjrzREAR';
List<MissionEchangeLocalService> x = null;
List<MissionMessageController.MessageDto> local =
    MissionEchangeLocalService.getMessages(mid);
Integer gest = 0;
Integer mine = 0;
for (MissionMessageController.MessageDto d : local) {
    if (d == null) continue;
    if (d.isMine == true) mine++;
    else gest++;
    System.debug('LOCAL ' + (d.isMine ? 'MINE' : 'GS') + ' | ' + d.content?.left(40) + ' | role=' + d.senderRole);
}
System.debug('LOCAL total=' + local.size() + ' gestionnaire=' + gest + ' mine=' + mine);
