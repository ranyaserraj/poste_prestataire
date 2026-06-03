import { LightningElement, api, wire } from 'lwc';
import getMessagingGate from '@salesforce/apex/MissionMessageController.getMessagingGate';

const DEFAULT_DISABLED_MESSAGE =
  'Messagerie indisponible pour cette mission.';

function normalizeId(val) {
  if (val == null || val === '') return '';
  const s = String(val).trim();
  return /^[a-zA-Z0-9]{15,18}$/.test(s) ? s : '';
}

export default class MissionMessagerie extends LightningElement {
  @api recordId;
  /** Id Mission__c explicite (prioritaire sur recordId si les deux sont fournis). */
  @api missionId;

  _parentOverridesEnabled = false;
  _parentOverridesDisabledMessage = false;
  _parentMessagingEnabled = false;
  _parentDisabledMessage = DEFAULT_DISABLED_MESSAGE;

  _gateMessagingEnabled = false;
  _gateDisabledMessage = DEFAULT_DISABLED_MESSAGE;
  _gateLoaded = false;

  @api
  get messagingEnabled() {
    return this._parentMessagingEnabled;
  }
  set messagingEnabled(value) {
    this._parentOverridesEnabled = true;
    this._parentMessagingEnabled = value === true;
  }

  @api
  get disabledMessage() {
    return this._parentDisabledMessage;
  }
  set disabledMessage(value) {
    if (value != null && String(value).trim() !== '') {
      this._parentOverridesDisabledMessage = true;
      this._parentDisabledMessage = String(value).trim();
    }
  }

  @wire(getMessagingGate, { missionId: '$wiredMissionId' })
  wiredGate({ data, error }) {
    if (this._parentOverridesEnabled) {
      return;
    }
    if (data) {
      this._gateMessagingEnabled = data.messagingEnabled === true;
      this._gateDisabledMessage =
        data.disabledMessage != null &&
        String(data.disabledMessage).trim() !== ''
          ? String(data.disabledMessage).trim()
          : DEFAULT_DISABLED_MESSAGE;
      this._gateLoaded = true;
      return;
    }
    if (error) {
      this._gateMessagingEnabled = false;
      this._gateDisabledMessage =
        error?.body?.message || DEFAULT_DISABLED_MESSAGE;
      this._gateLoaded = true;
    }
  }

  get wiredMissionId() {
    const id = this.activeMissionId;
    return id || undefined;
  }

  get activeMissionId() {
    return normalizeId(this.missionId) || normalizeId(this.recordId);
  }

  get hasRecordId() {
    return !!this.activeMissionId;
  }

  get effectiveMessagingEnabled() {
    if (this._parentOverridesEnabled) {
      return this._parentMessagingEnabled === true;
    }
    return this._gateMessagingEnabled === true;
  }

  get effectiveDisabledMessage() {
    if (this._parentOverridesDisabledMessage) {
      return this._parentDisabledMessage;
    }
    return this._gateDisabledMessage;
  }

  get showLoading() {
    return (
      this.hasRecordId &&
      !this._parentOverridesEnabled &&
      !this._gateLoaded
    );
  }

  get showChat() {
    return this.hasRecordId && this.effectiveMessagingEnabled;
  }

  get showDisabled() {
    if (!this.hasRecordId) {
      return false;
    }
    if (this._parentOverridesEnabled) {
      return !this.effectiveMessagingEnabled;
    }
    return this._gateLoaded && !this.effectiveMessagingEnabled;
  }
}
