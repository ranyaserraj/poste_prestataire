# Poste prestataire — périmètre Médecin

Ce dépôt contient **uniquement** les métadonnées Salesforce liées au **portail médecin** (création de mission, détail, documents, chemins, jeux d’autorisations).

Le projet complet « PortailPrestataire » (tous les prestataires) reste en dehors de ce dépôt, pour garder une **traçabilité ciblée** sur le périmètre médecin.

## Contenu typique

- Classes Apex : `MissionMedecinController`, `MissionCreateMedecinGateController*`
- LWC : modales de création médecin, détail mission médecin, dashboard statique, etc.
- Permission sets : `Portail_Medecin_Mission`, `DocumentMedecin`
- Custom metadata, field sets et record type Mission **Médecin**, objet `Document_Medecin__c`, flow / path assistant associés

## Déploiement

Prérequis : l’objet `Mission__c` et les champs référencés existent déjà dans la cible (ce dépôt ne remplace pas tout le modèle de données).

```bash
sf project deploy start --source-dir force-app --target-org <alias>
```

API source : `sfdx-project.json` (v65).
