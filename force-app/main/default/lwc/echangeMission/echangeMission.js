import { LightningElement, track } from 'lwc';

export default class EchangeMission extends LightningElement {
  // UI statique (sera remplacée par API plus tard)
  @track tags = ['Question technique', 'Demande de pièces', 'Information'];

  @track messages = [
    {
      id: 'm1',
      side: 'left',
      bubbleClass: 'msg msg--left',
      bodyClass: 'msg-body',
      metaClass: 'msg-meta',
      avatarClass: 'avatar avatar--left',
      avatarText: 'GS',
      author: 'GS',
      name: 'Mme Dubois',
      text: 'Mission assignée. La victime sera disponible le 22 avril pour la convocation.',
      meta: '09/04/2026 · 09h00',
    },
    {
      id: 'm2',
      side: 'right',
      bubbleClass: 'msg msg--right',
      bodyClass: 'msg-body msg-body--right',
      metaClass: 'msg-meta msg-meta--right',
      avatarClass: 'avatar avatar--right',
      avatarText: 'KA',
      author: 'Vous',
      name: 'KA',
      text: 'Bien reçu. Convocation planifiée pour le 22 avril à 10h00.',
      meta: '09/04/2026 · 11h30',
    },
    {
      id: 'm3',
      side: 'left',
      bubbleClass: 'msg msg--left',
      bodyClass: 'msg-body',
      metaClass: 'msg-meta msg-meta--unread',
      avatarClass: 'avatar avatar--left',
      avatarText: 'GS',
      author: 'GS',
      name: 'Mme Dubois',
      text: "Merci. N'oubliez pas de nous transmettre le rapport dans les 21 jours suivant la consultation.",
      meta: 'Non lu · 09/04/2026 · 11h45',
      unread: true,
    },
  ];

  get thread() {
    return this.messages;
  }

  handleTagClick() {
    // statique : pas d’action
  }

  handleSend() {
    // statique : pas d’action
  }
}

