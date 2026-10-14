# Design decisions — FinTrack Perf & Scale

## Matrice RACI et modèle de rôles

Le briefing impose « 5 rôles séparés selon la matrice RACI » sans fournir ladite
matrice. Voici celle retenue pour justifier le découpage du script 01.

**Convention :** R = Réalise, A = Approuve (responsable final), C = Consulté, I = Informé.

| Activité | Data Engineer | Analytics Engineer | Data Analyst | Ops / SRE | Finance / Compliance |
|----------|:---:|:---:|:---:|:---:|:---:|
| Provisionner l'infrastructure Snowflake | R | I | — | A | I |
| Charger les données brutes (RAW) | R/A | I | — | C | — |
| Modéliser staging et marts | C | R/A | C | — | I |
| Définir les règles métier (catégories, rapprochement) | I | C | R | — | A |
| Consommer les marts (BI, dashboards) | — | C | R/A | — | C |
| Exploration ad-hoc | C | C | R | — | C |
| Orchestrer et superviser la production | C | C | I | R/A | I |
| Arbitrer les coûts Snowflake | C | C | I | R | A |
| Valider la piste d'audit réglementaire | C | C | I | I | R/A |

### Traduction en rôles Snowflake

| Rôle | Porté par | Droits | Warehouse |
|------|-----------|--------|-----------|
| `FINTRACK_INGESTION_ROLE` | Data Engineer | Écriture sur `RAW` | `WH_INGESTION` |
| `FINTRACK_TRANSFORM_ROLE` | Analytics Engineer, dbt en prod | Lecture `RAW`, écriture `STAGING` / `MARTS_*` / `SNAPSHOTS` / `AUDIT` | `WH_TRANSFORM` |
| `FINTRACK_REPORTING_ROLE` | Data Analyst, outils BI | Lecture seule sur les `MARTS_*` | `WH_REPORTING` |
| `FINTRACK_ADHOC_ROLE` | Exploration, debug | Lecture seule sur toute la base | `WH_ADHOC` |
| `FINTRACK_DEV_ROLE` | Développement local, CI | Tous droits sur `FINTRACK_DEV`, lecture sur `FINTRACK_PROD` | `WH_DEV` |

**Principe directeur :** un rôle par *intention d'usage*, pas par personne. Une même
personne cumule plusieurs rôles ; c'est le rôle actif qui détermine le warehouse, donc
l'imputation du coût. C'est ce qui rend la facturation lisible par activité.

**Écarts constatés sur le script fourni**, à corriger si le provisioning doit être rejoué :

1. **Les rôles ne sont rattachés à aucune hiérarchie.** La bonne pratique Snowflake veut
   que les rôles custom soient accordés à `SYSADMIN`. Ici ils sont orphelins, et les objets
   appartiennent à `ACCOUNTADMIN`.
2. **Le script 02 n'est pas exécutable par le rôle qu'il déclare.** Il commence par
   `USE ROLE FINTRACK_TRANSFORM_ROLE`, lequel n'a ni droit de création sur `RAW` ni `USAGE`
   sur `WH_INGESTION`. Il a dû être exécuté en `ACCOUNTADMIN`.
3. **Les tables créées par un rôle ne sont pas lisibles par les autres** sans grant
   explicite : un `GRANT ALL ON SCHEMA` ne couvre pas les tables déjà existantes.
4. **Les future grants au niveau base sont neutralisés** par ceux au niveau schéma. Les
   lignes `GRANT … ON FUTURE TABLES IN DATABASE` pour `ADHOC` et `DEV` sont donc sans
   effet sur `RAW` et les `MARTS_*`, qui portent leurs propres future grants.
5. **`WH_DEV` n'est rattaché à aucun resource monitor** : les runs de développement
   échappent au plafond de crédits.

---

## Modélisation

### Choix Kimball vs Data Vault

**Kimball retenu.** Le besoin est analytique et les consommateurs sont des outils BI
(Metabase, Hightouch) qui attendent des faits et des dimensions. Data Vault aurait son
intérêt pour l'historisation fine et l'intégration de sources hétérogènes, mais il impose
une couche de présentation supplémentaire — donc des modèles en plus sur un pipeline qu'on
doit justement accélérer. L'historisation réglementaire est couverte par les snapshots dbt
et `dim_comptes_scd2`, sans adopter le paradigme complet.

### Grain des tables de faits
- `fct_transactions` : une ligne = une transaction validée ou en_attente,
  non-reversal
- `fct_virements` : une ligne = une **leg** de virement (sortante OU entrante, donc
  exactement 2 lignes par virement exécuté)

Le grain en legs permet d'agréger les mouvements par compte sans se préoccuper du sens :
un `SUM(montant_signe)` groupé par compte donne directement le flux net. Les frais sont
portés par la seule leg sortante, l'émetteur les supportant ; les imputer aux deux legs
les compterait deux fois.

---

## Limites connues

### Lignes fantômes dans `fct_transactions`

Le grain retenu filtre `statut in ('validee', 'en_attente')`. Combiné à la
stratégie `merge`, ce filtre produit des lignes obsolètes :

1. une transaction `en_attente` est insérée dans le fait ;
2. la source la passe à `rejetee` ;
3. elle sort du périmètre du SELECT, donc du jeu source du MERGE ;
4. le MERGE ne met à jour que ce qu'il reçoit et **ne supprime jamais** : la
   ligne reste dans le fait avec son ancien statut.

Le fait affirme alors qu'une transaction est en attente alors que la source dit
qu'elle est rejetée. **Aucun test dbt ne peut détecter cet écart** : la ligne est
cohérente avec elle-même, seule une confrontation à la source le révélerait.

**Impacts mesurables :**

| Impact | Détail |
|--------|--------|
| KPI de rejet inexploitables | `mart_tenant_kpis_daily.nb_transactions_rejetees` renvoie structurellement 0 |
| Taux de validation surestimé | son dénominateur exclut les échecs |
| Piste d'audit incomplète | les transactions rejetées n'apparaissent nulle part en aval |
| Dérive silencieuse dans le temps | le volume de lignes fantômes croît à chaque cycle |

**Décision : limite documentée, non corrigée.** Le grain défini au cadrage est
conservé. Deux correctifs restent possibles si le besoin métier se confirme :

- **A — élargir le grain** à tous les statuts et filtrer dans les marts via des
  drapeaux dérivés (`is_validee`, `is_echec`, `is_en_cours`). Corrige les KPI et
  complète la piste d'audit, au prix d'un fait environ 8 % plus volumineux et
  d'un changement de contrat pour les consommateurs.
- **B — conserver le grain** et ajouter un post-hook supprimant du fait les
  lignes dont le statut est sorti du périmètre dans la fenêtre courante. Grain
  inchangé, mais une mécanique supplémentaire à maintenir, et le post-hook doit
  rester cohérent avec la fenêtre de lookback.

**Détection en attendant :** un test de réconciliation périodique entre
`fct_transactions` et `raw_transactions` sur la tranche récente permettrait de
mesurer la dérive sans changer le modèle. À envisager au Sprint 6 avec
Elementary.

---

### Hiérarchie des catégories

`dim_categories` résout l'arbre par CTE récursive et expose `niveau`, `chemin_complet`
et `id_racine`. Deux garde-fous :

- **Orphelins** : une catégorie active dont le parent est inactif ou absent est rattachée
  à l'ancre comme racine, et marquée `is_orphelin`. Sans ce traitement elle disparaîtrait
  du référentiel sans aucun signal.
- **Cycles** : la profondeur est bornée à 10 niveaux. Snowflake ne limite pas les itérations
  d'une CTE récursive — un cycle A → B → A tourne jusqu'au `STATEMENT_TIMEOUT_IN_SECONDS`.

L'ancre utilise une **anti-jointure** et non un `NOT IN (select …)` : Snowflake rejette les
sous-requêtes dans l'ancre d'une CTE récursive, et un `NOT IN` sur colonne nullable renvoie
faux pour toutes les lignes dès qu'un seul NULL est présent.

### Bridge tables

`bridge_comptes_titulaires` — relation many-to-many entre comptes et personnes physiques,
nécessaire pour ventiler les dépenses d'un compte joint. Porte un `allocation_factor`
(somme = 1 par compte) et une historisation `date_debut` / `date_fin`.

*À implémenter (US 2.2) : le générateur ne produit pas encore les titulaires.*

## Matérialisations

| Modèle | Matérialisation | Raison |
|--------|-----------------|--------|
| stg_transactions | incremental (merge) | 50-100M lignes, updates de statut post-insertion |
| fct_transactions | incremental (merge) | idem, colonnes update ciblées via merge_update_columns |
| int_transactions_normalisees | ephemeral | évite matérialisation intermédiaire coûteuse |
| int_fx_rates_daily | table | petit volume, requêté par tous les faits |
| mart_solde_journalier | table | complexité window function, à évaluer en incremental si dérive |

## Clustering keys

| Table | Clustering key | Justification |
|-------|----------------|---------------|
| raw_transactions | (tenant_id, DATE_TRUNC('MONTH', date_transaction)) | Filtres BI dominants |
| raw_comptes | (tenant_id, date_ouverture) | Multi-tenant, requêtes par cohorte |
| raw_fx_rates | (date_cotation) | Toujours filtré par date |

## SCD Type 2

Pattern retenu pour `dim_comptes_scd2` : stratégie `check` avec `check_cols`.
Colonnes surveillées : statut, kyc_level, aml_flag, email, type_compte,
customer_segment, is_pep.

**Pourquoi `check` et non `timestamp`.** La documentation dbt recommande
`timestamp`, qui ne suit qu'une colonne et absorbe les évolutions de schéma. Mais
elle suppose un `updated_at` fiable : un changement de statut sans
rafraîchissement de l'horodatage passerait inaperçu. Sur des attributs
réglementaires (KYC, AML), rater un changement est inacceptable. `check` compare
les valeurs elles-mêmes — plus coûteux, mais exhaustif.

**Conventions de bornes :**
- intervalle `[date_debut_validite, date_fin_validite[`, borne haute **exclue** ;
- version courante : `date_fin_validite = 9999-12-31`, jamais NULL ;
- surrogate key = hash(compte_id, date_debut_validite), identifiant de **version**.

**L'historisation est prospective.** Un snapshot n'enregistre que les changements
survenus après sa mise en service : il ne reconstitue pas le passé. La profondeur
d'audit disponible est donc bornée par la date de démarrage du snapshot, et non
par l'ancienneté des comptes. À mettre en production avant tout besoin d'audit —
cela ne se rattrape pas.

## Multi-devises

**Convention de cotation :** `int_fx_rates_daily` cote **EUR → devise**, soit le
nombre d'unités de la devise pour 1 EUR (1 EUR = 7,45 DKK).
La conversion vers l'euro se fait donc par **division** : `montant / taux`.

Inverser ce sens est le bug corrigé en US 4.2 — invisible sur l'euro (taux = 1),
qui représente 55 % des transactions, et spectaculaire sur le yen (×174).

Le fait expose `taux_change_retenu` et `is_taux_referentiel` : sans le taux
effectivement appliqué, aucun calcul n'est rejouable a posteriori, ce qu'exige le
rapprochement comptable.

Le calendrier FX est densifié par report du dernier cours connu (week-ends,
fériés), avec un indicateur `is_taux_reporte`, et ses bornes sont déduites des
données plutôt que codées en dur — des dates figées créent un trou silencieux dès
que les données débordent la fenêtre prévue.

## Convention de nommage

- `stg_<entity>` : staging
- `int_<action>_<entity>` : intermediate
- `dim_<entity>` : dimension
- `fct_<entity>` : fact
- `bridge_<entity1>_<entity2>` : bridge
- `mart_<domain>_<subject>` : mart consommable

## Query tags

Format : `team=<team>|project=<project>|target=<target>`

Positionné automatiquement via `on-run-start`.
