import { LightningElement } from 'lwc';

/**
 * Détail mission — statique (maquette). Le bouton Retour utilise l’historique navigateur.
 */
export default class MissionDetailMedecin extends LightningElement {
  handleBack() {
    if (window.history.length > 1) {
      window.history.back();
      return;
    }
    // Fallback Community racine site
    const base = window.location.pathname.split('/s/')[0] || '';
    window.location.assign(`${base}/s/`);
  }
}
