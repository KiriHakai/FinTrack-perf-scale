# Contrats et versioning des modèles publics

Ce document définit ce que FinTrack garantit à ses consommateurs de données, et
la procédure appliquée lorsqu'une de ces garanties doit changer.

---

## 1. Pourquoi des contrats

Un modèle marqué `access: public` est une **interface**, au même titre qu'une API.
Ses consommateurs — Metabase, Hightouch, les notebooks de l'équipe Data Science,
et demain les tenants eux-mêmes — écrivent des requêtes contre un schéma qu'ils
supposent stable.

Sans contrat, renommer une colonne ou changer son type est une opération d'une
ligne côté producteur, et une panne silencieuse côté consommateur : le dashboard
ne tombe pas, il affiche des chiffres faux ou une colonne vide.

Avec `contract.enforced: true`, dbt compare le schéma produit par le modèle à sa
déclaration YAML **avant** d'écrire en base. Toute divergence fait échouer le
build, dans la CI, avant la mise en production.

---

## 2. Modèles sous contrat

| Modèle | Version courante | Contrat | Consommateurs déclarés |
|--------|------------------|---------|------------------------|
| `fct_transactions` | **v1** (`latest`) | ✅ enforcé | Metabase, Hightouch, Data Science |
| `fct_transactions` | v2 (préversion) | ✅ enforcé | — (phase de test) |
| `dim_comptes` | v1 | ⬜ non enforcé | Metabase, synchronisation CRM |
| `mart_tenant_kpis_daily` | v1 | ⬜ non enforcé | Dashboard exécutif |

Les contrats sont activés progressivement, en commençant par le modèle le plus
exposé. Verrouiller un schéma encore instable crée surtout de la friction : la
documentation dbt elle-même met en garde contre une adoption trop précoce des
fonctionnalités de gouvernance.

---

## 3. Ce qui casse un contrat, et ce qui ne le casse pas

| Changement | Rupture ? | Traitement |
|------------|:---------:|------------|
| Supprimer une colonne | **Oui** | Nouvelle version |
| Renommer une colonne | **Oui** | Nouvelle version |
| Changer le type d'une colonne | **Oui** | Nouvelle version |
| Restreindre la nullabilité | **Oui** | Nouvelle version |
| **Ajouter** une colonne | Non | Modification directe |
| Corriger le calcul d'une colonne existante | Non au sens du contrat | Voir ci-dessous |
| Changer la matérialisation | Non | Modification directe |

### Le cas ambigu : une colonne qui change de valeurs sans changer de type

La correction FX du Sprint 4 en est l'illustration. `montant_eur` a conservé son
nom et son type `NUMBER`, mais ses valeurs ont été divisées par le taux au lieu
d'être multipliées : un montant en yens a été divisé par 174.

**Aucun contrat n'aurait détecté ce changement.** Le contrat garantit une
structure, pas une sémantique. Pourtant, du point de vue d'un dashboard financier,
l'impact est bien plus violent qu'un renommage de colonne — qui, lui, aurait au
moins produit une erreur visible.

Trois conséquences pratiques :

1. **Les contrats ne remplacent pas les tests.** Ils sont complémentaires : le
   contrat protège la forme, les tests protègent le fond.
2. **Une correction de calcul sur un modèle public doit être annoncée**, même si
   elle ne casse techniquement rien. La règle retenue : tout changement qui
   modifie les valeurs de plus de 1 % des lignes fait l'objet d'une notification
   aux consommateurs, au même titre qu'une rupture.
3. **Un test de non-régression sur les valeurs** vaut mieux qu'un test de plage.
   `accepted_range(0, 100000000)` laissait passer un montant 57 fois trop élevé ;
   `assert_fx_montant_eur_coherent` le détecte.

---

## 4. Preuve que le contrat protège

Un contrat qui n'a jamais échoué ne prouve rien. Rupture provoquée
volontairement sur `fct_transactions` : la colonne `montant_eur` renommée en
`montant_euros`, sans toucher au YAML.

```
Compilation Error in model fct_transactions
  This model has an enforced contract that failed.
  Please ensure the name, data_type, and number of columns in your contract
  match the columns in your model's definition.

| column_name   | definition_type | contract_type | mismatch_reason       |
| ------------- | --------------- | ------------- | --------------------- |
| MONTANT_EUR   |                 | FIXED         | missing in definition |
| MONTANT_EUROS | FIXED           |               | missing in contract   |

Done. PASS=2 WARN=0 ERROR=1 SKIP=1
```

Trois enseignements de cette sortie :

**L'échec survient avant toute écriture.** L'erreur est levée à la compilation,
dans `assert_columns_equivalent`, avant le `CREATE`. La table en base conserve
son schéma d'origine et ses données. Sans contrat, dbt aurait recréé la table
avec la colonne renommée — et tous les dashboards référençant `montant_eur`
auraient cessé de fonctionner, sans la moindre alerte côté pipeline.

**La propagation est stoppée.** `fct_transactions_v2` passe en `SKIP` : dbt
n'exécute pas les modèles aval d'un nœud en échec. Une rupture reste donc
confinée à son point d'origine.

**Le diagnostic est exploitable tel quel.** Le tableau nomme la colonne attendue,
celle produite, et la nature de l'écart. En CI, ce message suffit à un relecteur
de PR pour comprendre la rupture sans ouvrir le modèle.

C'est exactement le comportement recherché : la rupture est détectée **dans la
CI, sur une pull request**, et non en production par un consommateur dont le
rapport affiche une colonne vide.

---

## 5. Procédure de migration

### Étape 1 — Créer la nouvelle version

Le fichier suit la convention `<modele>_v<n>.sql`. Lorsqu'une version ne fait
qu'ajouter ou retirer des colonnes, elle est définie comme une **projection** de
la version existante plutôt qu'une copie du SQL :

```sql
-- models/marts/core/fct_transactions_v2.sql
select
    *,
    case when type_operation = 'debit' and marchand_nom is not null
         then round(montant_eur / 1.20, 2) end as montant_hors_taxes
from {{ ref('fct_transactions', v=1) }}
```

La logique métier n'existe ainsi qu'à un seul endroit, et les deux versions ne
peuvent pas diverger.

### Étape 2 — Déclarer la version sans la promouvoir

```yaml
models:
  - name: fct_transactions
    latest_version: 1          # v1 reste la référence
    config:
      contract: {enforced: true}
    versions:
      - v: 1
        config:
          alias: fct_transactions   # conserve l'emplacement physique historique
      - v: 2
        columns:
          - include: all
          - name: montant_hors_taxes
            data_type: number
```

`ref('fct_transactions')` continue de résoudre vers v1. Les consommateurs
volontaires testent v2 en épinglant explicitement `ref('fct_transactions', v=2)`.

### Étape 3 — Notifier et ouvrir la fenêtre de migration

| Étape | Délai | Action |
|-------|-------|--------|
| Annonce | J | Publication de la v2, communication aux consommateurs déclarés |
| Test | J à J+30 | Les consommateurs valident leurs requêtes contre v2 |
| Bascule | J+30 | `latest_version: 2` — `ref()` non épinglé résout désormais vers v2 |
| Dépréciation | J+30 | `deprecation_date` posée sur v1, **au minimum 30 jours plus tard** |
| Retrait | J+60 minimum | Suppression de v1 |

`deprecation_date` fait émettre un avertissement par dbt à tout projet qui
référence encore la version concernée. C'est le mécanisme qui transforme une
intention en signal automatique.

### Étape 4 — Retirer l'ancienne version

Supprimer le fichier et son entrée `versions:`. La relation en base disparaît au
run suivant.

---

## 6. Emplacement physique des tables — le piège

**Par défaut, dbt matérialise chaque version sous l'alias `<modele>_v<n>`.**
Activer le versioning sur un modèle existant renomme donc sa table : les outils
qui pointent sur `MARTS_CORE.FCT_TRANSACTIONS` ne la trouveraient plus.

C'est l'inverse de l'effet recherché : on introduit le versioning pour *éviter*
de casser les consommateurs, et son activation les casserait tous.

D'où `alias: fct_transactions` sur v1, qui conserve l'emplacement historique.
v2 se matérialise, elle, en `fct_transactions_v2`.

Lors de la bascule vers v2, deux options :
- **déplacer l'alias** sur v2 et laisser v1 devenir `fct_transactions_v1` — les
  consommateurs non migrés basculent alors sans le savoir, ce qui n'est acceptable
  que si la v2 est compatible ;
- **laisser les alias en place** et exiger une migration explicite — plus sûr,
  plus lent.

La seconde est retenue : un consommateur doit changer sa requête consciemment.

> dbt 1.12 propose `latest_version_pointer`, une vue portant le nom de base du
> modèle et pointant toujours vers la dernière version. Elle entre en collision
> avec un `alias` identique au nom de base (erreur `dbt1005`) : elle n'est donc
> pas activée ici, l'alias sur v1 remplissant le même office pendant la fenêtre
> de migration.

---

## 7. Note sur le cas présent

**Ajouter `montant_hors_taxes` n'est pas une rupture de contrat.** La
documentation dbt est explicite : ajouter une colonne ne nécessite pas de
nouvelle version.

La v2 est néanmoins créée ici pour deux raisons :

1. **Elle répond à l'US 6.2**, qui demande explicitement une version
   additionnelle avec un champ supplémentaire.
2. **Elle met le mécanisme en place avant d'en avoir besoin.** Le jour où une
   vraie rupture surviendra — et le Sprint 3 a montré que les lignes fantômes de
   `fct_transactions` imposeront tôt ou tard un élargissement du grain, qui en
   est une —, la procédure sera rodée et les consommateurs habitués.

Dans un contexte réel, cette colonne aurait été ajoutée directement à v1, avec
une simple annonce. Multiplier les versions pour des changements non bloquants
encombre le dépôt et l'entrepôt : la documentation dbt recommande une cadence
prévisible, une à deux fois par an, plutôt qu'une version par modification.

---

## 8. Exposures — la pièce manquante

Ce document liste les consommateurs **à la main**, ce qui est fragile : rien ne
garantit que la liste reste à jour.

dbt permet de les déclarer formellement via des `exposures`, ce qui apporte :
- leur apparition dans le graphe de lignage et la documentation générée ;
- la sélection `dbt build --select +exposure:nom_du_dashboard` pour ne
  reconstruire que ce dont un consommateur dépend ;
- un propriétaire identifié, à prévenir en cas de rupture.

**Non implémenté à ce stade** — les consommateurs (Metabase, Hightouch) sont
fictifs dans le cadre de cette mission. À mettre en place dès que des
consommateurs réels existent, avant d'ouvrir la première fenêtre de migration.
