User portalUser = [SELECT Id FROM User WHERE Id = '005fj00000EimYjAAJ' LIMIT 1];
System.runAs(portalUser) {
    Id mid = 'a0Dfj00000PjrzREAR';
    List<MissionMessageController.MessageDto> rows =
        MissionMessageController.getMessages(mid);
    Integer gest = 0;
    Integer mine = 0;
    for (MissionMessageController.MessageDto d : rows) {
        if (d == null) continue;
        if (d.isMine == true) mine++;
        else gest++;
    }
    System.debug('PORTAL getMessages total=' + rows.size() + ' GS=' + gest + ' MINE=' + mine);
    for (MissionMessageController.MessageDto d : rows) {
        if (d == null) continue;
        System.debug('ROW ' + (d.isMine ? 'MINE' : 'GS') + ' | ' + (d.content == null ? '' : d.content.left(30)));
    }
}
