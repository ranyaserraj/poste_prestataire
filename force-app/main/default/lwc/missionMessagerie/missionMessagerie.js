import { LightningElement, api } from 'lwc';

function normalizeId(val) {
  if (val == null || val === '') return '';
  const s = String(val).trim();
  return /^[a-zA-Z0-9]{15,18}$/.test(s) ? s : '';
}

export default class MissionMessagerie extends LightningElement {
  @api recordId;
  /** Id Mission__c explicite (prioritaire sur recordId si les deux sont fournis). */
  @api missionId;
  /** false = Avocat, mission non synchronisée, etc. */
  @api messagingEnabled = false;
  @api disabledMessage =
    'Messagerie indisponible pour cette mission.';

  get activeMissionId() {
    return normalizeId(this.missionId) || normalizeId(this.recordId);
  }

  get hasRecordId() {
    return !!this.activeMissionId;
  }

  get showChat() {
    return this.hasRecordId && this.messagingEnabled;
  }

  get showDisabled() {
    return this.hasRecordId && !this.messagingEnabled;
  }
}
