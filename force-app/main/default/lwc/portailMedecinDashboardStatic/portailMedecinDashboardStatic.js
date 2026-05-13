import { LightningElement, track } from 'lwc';

export default class PortailMedecinDashboardStatic extends LightningElement {
  @track activeNav = 'dashboard';

  get navClasses() {
    const base = 'sideItem';
    const active = ' sideItem--active';
    return {
      dashboard: base + (this.activeNav === 'dashboard' ? active : ''),
      missions: base + (this.activeNav === 'missions' ? active : ''),
      honoraires: base + (this.activeNav === 'honoraires' ? active : ''),
      documents: base + (this.activeNav === 'documents' ? active : ''),
      messagerie: base + (this.activeNav === 'messagerie' ? active : ''),
      instructions: base + (this.activeNav === 'instructions' ? active : ''),
    };
  }

  setNav(event) {
    this.activeNav = event?.currentTarget?.dataset?.id || 'dashboard';
  }

  noop() {
    // Intentionally empty: this is a static prototype.
  }
}