# Performance Log — FinTrack Perf & Scale

Journal de performance de la mission. Document livrable obligatoire.

---

## 1. Chargement initial

### Contexte d'exécution

| Paramètre | Valeur |
|-----------|--------|
| Date | 13/10/2026 (rechargement complet après correction du générateur) |
| Scale généré | **M** (1 000 000 transactions, 20 000 comptes, 8 tenants) |
| Warehouse | `WH_INGESTION` — taille **LARGE** |
| Rôle | `ACCOUNTADMIN` (voir § Écart de provisioning) |
| Base / schéma | `FINTRACK_PROD.RAW` |
| Fichiers source | 9 CSV gzippés, dont `raw_transactions` découpé en 2 parts |

> Ce chargement remplace celui du 01/10/2026. Le jeu de données a été régénéré
> après correction de six défauts du générateur (cohérence multi-tenant, plages
> de dates, taux de change, transactions de test, `_loaded_at`, hiérarchie des
> catégories) et ajout des titulaires (US 2.2). Les mesures antérieures ne sont
> donc plus comparables.

### Volumétrie chargée

| Table | Lignes | Taille fichier (Mo, gzip) |
|-------|--------|---------------------------|
| raw_tenants | 8 | < 0,01 |
| raw_categories | 45 | < 0,01 |
| raw_fx_rates | 7 137 | 0,08 |
| raw_virements | 2 000 | 0,12 |
| raw_compte_titulaires | 23 313 | 0,25 |
| raw_titulaires | 23 313 | 0,78 |
| raw_comptes | 20 000 | 2,67 |
| raw_transactions_part1 | 500 000 | 152,4 |
| raw_transactions_part2 | 500 000 | 152,4 |
| **Total** | **1 075 816** | **≈ 309 Mo** |

`raw_transactions` non compressé pèse 950 Mo : **ratio de compression gzip ≈ 3:1**.

### Chaîne complète génération → upload → chargement

| Étape | Durée | Commentaire |
|-------|-------|-------------|
| Génération Python (scale M) | **8 min 16 s** | monothread, dominé par les appels Faker |
| PUT (upload client → stage interne) | **5 min 51 s** | 9 fichiers, 309 Mo, `PARALLEL=8` → ≈ 0,9 Mo/s |
| COPY INTO (8 tables) | **18,0 s** | voir détail ci-dessous |
| **Total** | **≈ 14 min 25 s** | dont **97 % hors Snowflake** |

**Le goulot d'étranglement n'est pas Snowflake.** Le chargement proprement dit
représente 18 secondes sur près de 15 minutes. Tout le reste est de la génération
locale et du transfert réseau depuis le poste client.

En production, ce profil disparaît : les fichiers sont déposés par le système
source sur un stockage objet (S3, Azure Blob, GCS) et lus via un **external stage**,
sans transiter par un poste de travail. Le PUT depuis un client est un artefact
d'environnement de test — à ne pas confondre avec un problème de performance de
la plateforme.

### Durées de COPY par table

| Table | Durée (s) | Lignes |
|-------|-----------|--------|
| raw_tenants | 1,65 | 8 |
| raw_categories | 0,77 | 45 |
| raw_fx_rates | 1,00 | 7 137 |
| raw_comptes | 1,46 | 20 000 |
| **raw_transactions** (2 fichiers, 1 COPY) | **10,29** | **1 000 000** |
| raw_titulaires | 1,19 | 23 313 |
| raw_compte_titulaires | 0,93 | 23 313 |
| raw_virements | 0,70 | 2 000 |
| **Total** | **18,0** | **1 075 816** |

**Aucune ligne rejetée** : `row_parsed = row_count` sur les deux parts de
transactions, malgré `ON_ERROR = 'CONTINUE'`.

### Récapitulatif par scale

| Scale | Taille CSV (Go, gzip) | Durée génération | Durée PUT | Durée COPY | Erreurs |
|-------|-----------------------|------------------|-----------|------------|---------|
| M | 0,31 | **8 min 16 s** | **5 min 51 s** | **18,0 s** | **0** |
| L | | | | | |
| XL | | | | | |

### Contrôle d'intégrité US 2.2

La somme des `allocation_factor` par compte, sur les rattachements en cours,
vaut 1 pour **l'intégralité des 23 313 rattachements** — la requête de contrôle
ne renvoie aucune ligne. L'invariant de ventilation est donc vérifié dès le RAW,
avant toute transformation dbt.

### Incidents et enseignements

**1. Clustering key incompatible avec COPY INTO** — résolu définitivement

```
SQL compilation error: Function 'TRUNCTIMESTAMPTOMonth' not supported within a COPY
```

Snowflake ne sait pas évaluer une clustering key basée sur une fonction
(`DATE_TRUNC`) pendant un chargement bulk : la requête est rejetée à la
compilation, avant lecture de la moindre ligne.

Les clauses `CLUSTER BY` de `raw_transactions` et `raw_virements` ont été
**commentées dans `02_ddl_raw_tables.sql`** plutôt que contournées par un
`ALTER TABLE … DROP CLUSTERING KEY` à chaque rechargement.

**Justification :** aucune requête du pipeline n'interroge le RAW par tenant et
par mois — les modèles staging le lisent intégralement et filtrent sur
`_loaded_at`. Le reclustering automatique aurait consommé des crédits en continu
sans bénéfice de pruning mesurable. Le clustering est conservé là où il sert :
sur `fct_transactions` (Sprint 3).

**2. Métadonnées de chargement : trois séries de COPY, deux sans effet**

`QUERY_HISTORY` montre trois séries de COPY, dont les deux premières à
**0 ligne chargée** malgré un statut `SUCCESS`. Ce n'est pas un échec :

- Snowflake conserve 64 jours les métadonnées de chargement de chaque fichier
  d'un stage et **ignore par défaut les fichiers déjà chargés**. C'est la
  protection native contre les doublons.
- Ces métadonnées sont attachées à la **table cible**. Le `CREATE OR REPLACE TABLE`
  du script 02 les réinitialise : c'est pourquoi la troisième série a effectivement
  chargé les données.

Deux conséquences opérationnelles :
- Un rechargement exige soit `FORCE = TRUE`, soit un `REMOVE @stage` suivi d'un
  nouveau PUT, soit la recréation des tables cibles.
- Un `CREATE OR REPLACE STAGE` **détruit les fichiers déjà uploadés** — ici,
  6 minutes de PUT à refaire. Un avertissement a été ajouté dans le script 03bis.

**3. Écart de provisioning : exécution en ACCOUNTADMIN**

Les scripts 02 et 03 déclarent `FINTRACK_TRANSFORM_ROLE` et
`FINTRACK_INGESTION_ROLE`, mais aucun des deux ne dispose des droits nécessaires :
le premier n'a ni création sur `RAW` ni `USAGE` sur `WH_INGESTION`, le second ne
possède pas les tables créées par le premier. Le provisioning livré **n'est donc
pas reproductible avec les rôles qu'il définit lui-même**.

Détail des cinq écarts de la matrice de rôles dans `docs/DESIGN.md`.

### Découpage du fichier transactions

`raw_transactions.csv.gz` (316 Mo) est découpé en 2 fichiers de 152 Mo, chacun
porteur de sa ligne d'en-tête (`SKIP_HEADER = 1` les gère).

Motif initial : contrainte de taille à l'upload. Bénéfice secondaire : **un COPY
parallélise par fichier**, les deux parts sont donc chargées simultanément —
10,3 s pour 1 M de lignes. À l'échelle L, viser des fichiers de 100 à 250 Mo
compressés, conformément aux recommandations Snowflake.

Script dédié : `scripts/snowflake/03_stage_and_copy_split.sql`.

---

## 2. Baseline (avant optimisations)

**Warehouse :** `WH_DEV` (XSMALL) — **Target :** `dev` — **Date :** 13/10/2026
**Volume :** scale M (1 M transactions) — **Threads :** 4 — **Commande :**
`dbt build --target dev --exclude tag:todo --full-refresh`

**Résultat : 138 nœuds, 0 erreur, 0 warning — 7 min 29 s (448,8 s).**

Baseline mesurée sur le pipeline **avant toute optimisation de performance** :
matérialisations d'origine, pas de clustering sur les faits, pas de Search
Optimization, fenêtres incrémentales par défaut. Seuls les bugs bloquants et les
défauts du jeu de données ont été corrigés (voir § 1 et JOURNAL_MISSION.md).

### Durées par modèle

| Modèle | Matérialisation | Durée (s) |
|--------|-----------------|-----------|
| **stg_transactions** | incremental (merge) | **24,35** |
| **fct_transactions** | incremental (merge) | **23,26** |
| dim_comptes | table | 17,62 |
| fct_virements | incremental (merge) | 15,50 |
| stg_virements | incremental (merge) | 15,46 |
| bridge_comptes_titulaires | table | 15,22 |
| stg_categories | view | 12,99 |
| stg_tenants | view | 12,99 |
| mart_tenant_kpis_daily | table | 12,75 |
| dim_categories | table | 12,53 |
| stg_compte_titulaires | view | 11,75 |
| dim_tenants | table | 11,51 |
| mart_solde_journalier | table | 10,90 |
| stg_comptes | view | 10,74 |
| mart_reconciliation | table | 10,53 |
| stg_fx_rates | view | 9,91 |
| stg_titulaires | view | 9,37 |
| int_fx_rates_daily | table | 8,89 |
| *snapshot_comptes* | snapshot | *22,26 (40 000 lignes)* |
| **Cumul des 18 modèles** | | **246,3** |

### Répartition du temps

| Catégorie | Nœuds | Cumul (s) | Part du cumul |
|-----------|-------|-----------|---------------|
| Modèles | 18 | 246,3 | 16 % |
| **Tests de données** | **105** | **1 104,1** | **71 %** |
| Tests unitaires | 12 | 170,6 | 11 % |
| Snapshot | 1 | 22,3 | 1 % |
| **Cumul total** | **136** | **1 543,3** | 100 % |
| **Temps réel écoulé** | | **448,8** | *parallélisme 4 threads* |

### Constat n°4 — les tests coûtent 4,5 fois plus cher que les modèles

C'est le résultat le plus contre-intuitif de cette baseline : **105 tests de
données consomment 1 104 s cumulées, contre 246 s pour les 18 modèles**. Chaque
test, même un `not_null` sur une dimension de 8 lignes, prend en moyenne **10,5
secondes**.

Ce n'est pas le calcul qui coûte, c'est le **coût fixe par requête** : reprise du
warehouse, ouverture de session, compilation du plan, aller-retour réseau. Un
`SELECT COUNT(*)` sur 8 lignes paie le même ticket d'entrée qu'un merge sur 1 M
de lignes.

Trois leviers en découlent pour le Sprint 3, par ordre d'impact décroissant :

1. **Réduire le nombre de requêtes de test.** Regrouper plusieurs assertions
   d'un même modèle en un seul test, ou ne tester que ce qui peut réellement
   dévier. 105 tests sur 22 modèles est un ratio élevé.
2. **Augmenter le parallélisme.** On passe de 1 543 s cumulées à 449 s réelles
   avec 4 threads, soit un facteur 3,4. Monter à 8 ou 12 threads améliorerait
   encore le temps de bout en bout, à condition que le warehouse suive.
3. **Hiérarchiser par sévérité.** Tous les tests ne justifient pas de faire
   tomber un run de production.

### Le pipeline complet rapporté à l'objectif

| | Valeur |
|---|---|
| Objectif CTO | pipeline complet **< 1 h** |
| Baseline actuelle, scale M | **7 min 29 s** |
| Volume cible annoncé | 50 à 100 M transactions/mois |
| Volume testé | 1 M transactions |

**Attention à la lecture de ce chiffre.** On est largement sous l'heure, mais
sur **1/50ᵉ à 1/100ᵉ du volume cible**. Et la structure du temps mesuré ici
(71 % de tests, dominés par la latence) ne se transpose pas linéairement : à
50 M de lignes, les coûts fixes deviennent négligeables et le temps de calcul
redevient prépondérant.

**Toute conclusion de performance tirée du scale M doit donc être revalidée au
scale L avant d'être présentée comme un gain.** C'est la limite méthodologique
principale de cette mission dans son environnement de test.

### Effets mesurés de la correction du jeu de données

| Indicateur | Avant correction | Après correction |
|---|---|---|
| Lignes de `mart_reconciliation` | 604 155 | à vérifier (lot par jour et tenant) |
| Niveaux dans `dim_categories` | 1 seul | **3** (8 groupes / 30 catégories / 7 sous-catégories) |
| Cohérence tenant transaction ↔ compte | aléatoire | **100 %** |
| `_loaded_at` distincts | 1 | **732 journées** |
| Lignes du snapshot | — | **40 000** (20 000 comptes × 2 versions) |

Le snapshot a enregistré 40 000 lignes : la régénération des comptes a produit
une seconde version de chaque enregistrement. L'historisation SCD2 du Sprint 4
dispose donc déjà de matière.

## 3. Sprint 3 — Incrémental et performance

### 3.1 — Stratégie incrémentale merge

**Configuration retenue** (`stg_transactions`, `fct_transactions`) :

| Paramètre | Valeur | Motif |
|-----------|--------|-------|
| `incremental_strategy` | `merge` | met à jour les lignes existantes au lieu de les dupliquer |
| `unique_key` | `transaction_id` | clé de rapprochement du MERGE |
| `merge_update_columns` | liste blanche de 17 colonnes | voir ci-dessous |
| fenêtre de lookback | `var('incremental_lookback_days')` = 7 | surchargeable : `--vars '{incremental_lookback_days: 30}'` |
| `on_schema_change` | `append_new_columns` | une nouvelle colonne source n'interrompt pas le pipeline |

**`merge_update_columns` est une liste blanche**, et c'est délibéré : tout ce qui
n'y figure pas est figé à l'insertion. Le montant, la devise ou la date d'une
transaction ne changent jamais après coup — les y inclure ferait réécrire des
micro-partitions sans raison. Ne sont listées que les colonnes qu'un core
banking met réellement à jour : cycle de vie du statut, rapprochement bancaire,
revue AML et fraude, compteur de tentatives, motif de rejet.

**La borne est relative au `max(_loaded_at)` déjà chargé**, et non à
`CURRENT_DATE()`. Si le pipeline ne tourne pas pendant trois jours, la fenêtre
repart du dernier chargement connu : aucun trou, pas de rattrapage manuel.

#### Validation du comportement — protocole

Le jeu de données étant chargé en une fois, aucun delta n'existait. Un second
lot d'ingestion a donc été fabriqué (`scripts/snowflake/06_simulate_delta_load.sql`) :

| Cas | Contenu | Attendu |
|-----|---------|---------|
| 1 — Mise à jour | 20 transactions `en_attente` → `validee`, `_loaded_at` rafraîchi | mises à jour sur place, sans doublon |
| 2 — Insertion | 10 nouvelles transactions | ajoutées au fait |
| 3 — Hors fenêtre | 1 transaction modifiée **sans** rafraîchir `_loaded_at` | **non reprise** — limite assumée |

#### Résultats de la validation

| Contrôle | Vérifie | Résultat |
|----------|---------|----------|
| J.1 | Les 20 transactions sont `validee` dans le fait, en un seul exemplaire | ✅ conforme |
| J.2 | Les 10 nouvelles transactions sont présentes | ✅ conforme |
| J.3 | Aucun doublon sur l'ensemble du fait | ✅ aucune ligne |
| J.4 | Volumétrie traitée par la fenêtre | ✅ **30 lignes** |

Le MERGE de `fct_transactions` a reporté le delta (`SUCCESS 10` au run suivant,
les 20 mises à jour ayant été appliquées au run précédent).

**Ce que J.1 et J.3 établissent ensemble :** le merge **met à jour** les lignes
existantes au lieu de les dupliquer. C'est la vérification qui compte — une
`unique_key` mal configurée produit des doublons silencieux, et le modèle
continue de tourner sans erreur pendant des mois.

#### Résultat principal : la fenêtre ne traite plus que le delta

| Mesure | Avant correction | Après correction |
|--------|------------------|------------------|
| Lignes sélectionnées par la fenêtre | **1 000 000** (100 % de la table) | **30** |
| Lignes réellement mergées | ~950 000, toutes identiques | 30 |

Avant, `_loaded_at` était alimenté par `CURRENT_TIMESTAMP()` au chargement :
toutes les lignes portaient la même valeur et la fenêtre de 7 jours
sélectionnait l'intégralité de la table. Le modèle était incrémental de nom
seulement — il payait le coût d'un full refresh **plus** celui du MERGE.

Depuis que le générateur produit un `_loaded_at` réaliste (date de l'événement
+ délai d'ingestion, soit 732 journées distinctes), la fenêtre joue son rôle.

> **Réserve de lecture.** Les données s'arrêtent au 31/12/2024 alors que les
> tests sont menés en octobre 2026 : le `max(_loaded_at)` est désormais fixé par
> les lignes de simulation, et la fenêtre de 7 jours ne couvre qu'elles. En
> production, une fenêtre de 7 jours capterait une semaine de flux réels — bien
> plus que 30 lignes. **Le mécanisme est validé ; le facteur de réduction est un
> artefact de l'environnement de test.**

---

### 3.2 — Merge contre microbatch

Prototype `fct_transactions_microbatch` : réplique fonctionnelle exacte de
`fct_transactions`, seule la stratégie diffère. Configuration conforme au
briefing — `event_time = 'date_transaction'`, `batch_size = 'day'`,
`lookback = 3`, `begin = '2023-01-01'`.

#### Mesures

| Scénario | Merge | Microbatch | Écart |
|----------|-------|------------|-------|
| **Build complet** | **23,3 s** — 1 instruction | **33 min 22 s** (2 002 s) — **1 383 instructions** | **×86** |
| **Run quotidien** (delta de 30 lignes) | **13,9 s** — 1 instruction | **21,7 s** — 4 instructions | **×1,6** |
| Build borné sur 1 mois | — | 89,8 s pour 31 batches | |
| Coût moyen par batch | — | 1,45 s (build complet) / 5,4 s (incrémental) | |

Le build complet a d'abord été extrapolé à ≈ 35 min depuis les 31 batches de
décembre ; la mesure réelle donne **33 min 22 s**, soit 5 % d'écart.

#### Le piège des batches vides

Le build complet a produit **1 383 batches, et non 731**. Un `--full-refresh`
microbatch couvre la période allant de `begin` **jusqu'à la date du jour**, pas
jusqu'à la fin des données :

| | |
|---|---|
| `begin` configuré | 01/01/2023 |
| Date d'exécution | 14/10/2026 |
| Batches générés | **1 383** |
| Batches contenant des données | ~731 (données jusqu'au 31/12/2024) |
| **Batches vides** | **~650, soit 47 %** |

À 1,45 s l'unité, ces journées sans une seule ligne ont consommé **près de
16 minutes** — la moitié du temps total — pour ne rien produire.

**Enseignement opérationnel :** `begin` n'est pas une simple borne de sécurité,
c'est un paramètre de coût direct. Le fixer trop tôt, ou laisser un modèle
microbatch tourner sur un historique dont l'alimentation s'est arrêtée, revient
à payer une instruction SQL par journée morte. Sur une table réellement
alimentée chaque jour, le problème ne se pose pas — mais sur un historique figé,
un backfill ou un environnement de test, il est invisible et coûteux.

**Mesure de protection appliquée au projet :** le prototype est désactivé par
défaut (`enabled = var('enable_microbatch_prototype', false)`). Un sélecteur
aussi anodin que `dbt build --select int_fx_rates_daily+ --full-refresh` l'avait
déclenché à l'insu de l'opérateur — 33 minutes de warehouse et ≈ 0,55 crédit
pour un modèle qui n'est qu'un banc d'essai.

**Pourquoi le microbatch perd dans les deux cas.** Le coût dominant de ce
pipeline n'est pas le calcul mais le **coût fixe par requête** — compilation,
aller-retour réseau, reprise de warehouse (cf. § 2, où 105 tests consomment 4,5
fois le temps des 18 modèles). Découper le travail en 731 instructions multiplie
ce coût fixe par 731, pour un volume de données strictement identique.

Le coût par batch double même en régime incrémental (5,4 s contre 2,9 s) : en
full refresh chaque batch écrit dans une table vierge, alors qu'en incrémental
il doit d'abord supprimer la tranche existante avant de la réinsérer.

#### L'argument décisif n'est pas la performance

Microbatch découpe sur `event_time`, c'est-à-dire la **date de la transaction**.
Or les mises à jour de ce pipeline portent sur des transactions **anciennes** :

- passage `en_attente` → `validee` : jusqu'à plusieurs jours ;
- rapprochement bancaire : jusqu'à plusieurs semaines ;
- revue AML : sans délai garanti.

Une transaction de mars rapprochée en décembre n'est reprise que si le batch de
mars est rejoué. Avec `lookback = 3`, on ne remonte que trois jours.

**Microbatch est conçu pour des faits append-only** — logs, événements
immuables, séries temporelles. `fct_transactions` est l'exact opposé : ses
lignes sont mises à jour longtemps après l'événement, ce qui est précisément
l'objet de l'US 3.1.

Retenir microbatch ici reviendrait à **aller moins vite en faisant moins bien**.

#### Recommandation : merge

| Critère | Merge | Microbatch |
|---------|:-----:|:----------:|
| Build complet | ✅ 23 s | ❌ ≈ 35 min |
| Run quotidien | ✅ 13,9 s | ❌ 21,7 s |
| Captation des mises à jour tardives | ✅ fenêtre sur `_loaded_at` | ❌ fenêtre sur `date_transaction` |
| Reprise après incident | ✅ fenêtre relative au dernier chargement | ⚠️ nécessite un backfill ciblé |
| Parallélisation des batches | ❌ instruction unique | ✅ `concurrent_batches` |
| Granularité du retraitement | ❌ toute la fenêtre | ✅ une journée précise |

**Quand microbatch redeviendrait pertinent :**

1. **À très grand volume** (50-100 M lignes/mois, la cible annoncée), où une
   instruction unique risquerait le spill disque et où le coût fixe par batch
   deviendrait négligeable devant le calcul. À revalider au scale L.
2. **Pour un backfill ciblé** : `--event-time-start` / `--event-time-end`
   permettent de rejouer une période précise sans toucher au reste, là où le
   merge impose d'élargir la fenêtre globale.
3. **Sur un fait append-only** — un `fct_evenements_connexion`, par exemple.

**Le prototype est conservé** dans le projet, taggé `prototype`, afin que la
comparaison soit rejouable au scale L.

#### Incident rencontré : version de l'adaptateur

Premier lancement : batch 1 en succès, batches 2 à 31 en échec sur
`The incremental strategy 'microbatch' is not valid for this adapter`.

Cause : **dbt-core 1.12.5 mais dbt-snowflake 1.8.4**. Les stratégies de
matérialisation sont implémentées par l'adaptateur, pas par le core — un projet
peut donc parser parfaitement et échouer à l'exécution. Le batch 1 passait car
la table n'existait pas encore : simple `CREATE TABLE AS SELECT`, sans stratégie
incrémentale.

Résolution : `pip install --upgrade dbt-snowflake` → 1.12.2. Effet de bord à
connaître : `snowflake-cli` exige des versions figées de
`snowflake-connector-python`, `click` et `protobuf`. Les deux outils doivent
vivre dans des environnements virtuels séparés.

**Conséquence pour le Sprint 5 :** la CI épingle `dbt-snowflake==1.8.*`. Cette
version ne sait ni lire la syntaxe `arguments:` des tests, ni exécuter le
microbatch. L'alignement sur 1.12 est un prérequis, pas une amélioration.

---

## 4. Sprint 3.3 — Clustering, Search Optimization, Query Profiles

**Méthode.** Cache de résultats désactivé (`ALTER SESSION SET USE_CACHED_RESULT = FALSE`)
avant chaque mesure : sans cela, la seconde exécution d'une requête renvoie le
résultat mémorisé sans rien calculer, et le Query Profile est vide.
Warehouse `WH_DEV` (XSMALL), table `fct_transactions` — 940 844 lignes, 86,5 Mo,
17 micro-partitions (18 après le lot incrémental).

---

### 4.1 Clustering

```json
{
  "cluster_by_keys"  : "LINEAR(tenant_id, date_trunc('month', date_transaction))",
  "total_partition_count" : 17,
  "total_constant_partition_count" : 6,
  "average_overlaps" : 4.0,
  "average_depth"    : 3.7059
}
```

**La cible du briefing (`average_depth < 3`) n'est pas atteinte — et elle ne peut
pas l'être à ce volume.**

La clé définit 8 tenants × 24 mois, soit jusqu'à **192 combinaisons distinctes**,
réparties sur **17 micro-partitions**. Il est arithmétiquement impossible de ranger
192 groupes dans 17 partitions sans chevauchement : d'où `average_overlaps = 4`.
La cardinalité de la clé dépasse le nombre de partitions d'un facteur 11.

Snowflake recommande le clustering pour des tables de l'ordre du téraoctet. Ici :
86 **méga**octets.

**Mais la métrique est trompeuse** — voir Q1 ci-dessous, qui élague 88 % des
partitions avec cette même clé. `average_depth` mesure la qualité théorique du
tri, pas l'efficacité de l'élagage sur le motif de requête réellement exécuté.

**Coût du clustering automatique : nul.** `AUTOMATIC_CLUSTERING_HISTORY` ne
renvoie aucune ligne sur 7 jours : le service est activé (`automatic_clustering = ON`)
mais ne s'est jamais déclenché, Snowflake ne jugeant pas la table digne d'un
reclustering. Conséquence : la profondeur de 3,71 n'évoluera pas d'elle-même,
et la clé ne coûte rien à conserver.

> À 50 M de lignes, la table comptera des milliers de partitions : le service se
> déclenchera réellement, et chaque merge incrémental provoquera du reclustering
> facturé. C'est à ce moment-là que l'arbitrage se posera.

---

### 4.2 Les trois Query Profiles

| | **Q1** — KPI tenant/mois | **Q2** — lookup identifiant | **Q3** — jointure + agrégat |
|---|---|---|---|
| Usage | dashboard tenant | recherche support client | analyse financière |
| **Durée** | **440 ms** | **1,1 s** | **546 ms** |
| Partitions scannées | **2 / 17** | 9 / 17 | 11 / 18 |
| Pruning | **88 %** | 47 % | 39 % |
| Octets scannés | **1,41 Mo** | 20,22 Mo | 11,70 Mo |
| Lignes traitées | 5 715 | 1 | 634 100 (jointure) |
| Processing | ~0 % | 1,4 % | ~0 % |
| Remote disk I/O | 33,3 % | 27,5 % | 32,8 % |
| **Synchronization** | **50,0 %** | **68,1 %** | **62,3 %** |
| Initialization | 16,7 % | 2,9 % | 4,9 % |
| Spill | aucun | aucun | aucun |

#### Q1 — La clustering key fait son travail

Filtre `tenant_id = 3` + borne mensuelle : **15 partitions sur 17 éliminées**.
Le pruning atteint 88 % alors même que `average_depth` vaut 3,71. C'est la preuve
que la métrique de clustering et l'efficacité réelle sont deux choses distinctes.

**Recommandation :** conserver la clé telle quelle. Elle correspond exactement au
motif de filtrage dominant (`tenant_id` + période), qui est celui de tous les
dashboards.

#### Q2 — Le vrai problème n'est pas l'index, c'est `SELECT *`

Q2 scanne **20,22 Mo pour ramener une seule ligne**, là où Q1 en scanne 1,41 pour
en ramener 5 715. L'écart ne vient pas des partitions mais des **colonnes** : Q1
en lit 5, Q2 fait `SELECT *` et en lit 43. En stockage colonnaire, c'est
déterminant.

**Recommandation, à coût nul :** proscrire `SELECT *` sur les lookups applicatifs.
Sélectionner les 10 colonnes réellement affichées par l'outil de support
diviserait les octets scannés par 4 à 5 — sans index, sans coût récurrent, sans
service à maintenir.

À noter : **l'élagage de 47 % est obtenu sans clustering key sur cette colonne.**
Snowflake conserve les bornes min/max de *chaque* colonne dans les métadonnées de
chaque micro-partition et écarte celles dont l'intervalle exclut la valeur
cherchée. Les identifiants étant des chaînes aléatoires, les intervalles se
chevauchent, mais pas totalement.

#### Q3 — Une jointure de 634 000 lignes en 546 ms, sans spill

Le plan montre un nœud **JoinFilter** : Snowflake construit un filtre dynamique
à partir du côté réduit de la jointure (20 000 comptes) et le pousse jusqu'au scan
du fait. Optimisation automatique, aucune intervention nécessaire.

**Aucun déversement en mémoire locale ni distante.** Le warehouse XSMALL absorbe
sans peine une jointure de 634 000 lignes avec `COUNT(DISTINCT)` et tri.

**Recommandation :** ne pas augmenter la taille du warehouse. Le spill est le
signal qui justifierait de passer à SMALL ou MEDIUM ; il est absent.

---

### 4.3 Search Optimization — arbitrage

#### Les estimations sont inexploitables à ce volume

| Cible | Construction | Stockage | Maintenance |
|-------|--------------|----------|-------------|
| `fct_transactions` (external_transaction_id) | 0,000457 crédit | 0,000005 To/mois | **indisponible** |
| `dim_comptes` (iban) | 0,000519 crédit | 0,000001 To/mois | **indisponible** |
| `fct_transactions` (2 colonnes) | **0,000405 crédit** | 0,000005 To/mois | **indisponible** |

Deux anomalies rendent ces chiffres sans valeur :

1. **L'estimation sur 2 colonnes (0,000405) est inférieure à celle sur 1 colonne
   (0,000457)**, ce qui est arithmétiquement impossible. La fonction annonce
   elle-même « estimated via sampling » : à 86 Mo, le bruit d'échantillonnage
   dépasse le signal.
2. **Le seul poste déterminant — la maintenance — n'est pas calculable** :
   « Table is too young. Requires 7 days of history. » Or c'est lui qui compte
   pour une table mergée quotidiennement, chaque écriture imposant une
   réindexation.

**Enseignement : à ce volume il faut mesurer, pas estimer.**

#### La mesure avant / après

| | Sans Search Optimization | Avec Search Optimization |
|---|---|---|
| Durée | 1,1 s | **1,1 s** |
| Partitions scannées | 9 / 17 | **9 / 17** |
| Octets scannés | 20,22 Mo | **20,22 Mo** |

**Aucun effet mesurable.** Les causes possibles — construction d'index non
achevée au moment de la mesure, ou optimiseur jugeant le scan direct moins coûteux
que le détour par l'index — restent à départager (`search_optimization_progress`).

Mais le résultat était prévisible à la lecture du profil de Q2 : les 20 Mo scannés
représentent 27,5 % d'une requête de 1,1 s, soit ≈ 0,3 s. **Même en supprimant
intégralement le scan, le gain plafonne à 0,3 seconde**, les 68 % de
synchronisation étant incompressibles.

#### Recommandation

| Cible | Au scale M | En production (50-100 M) |
|-------|-----------|--------------------------|
| `external_transaction_id` | ❌ **non** — gain ≤ 0,3 s, service facturé en continu | ⚠️ à réévaluer si les lookups support sont fréquents, après 7 jours d'historique pour chiffrer la maintenance |
| `iban` | ❌ **non** | ⚠️ critère différent : recherche de conformité, rare mais urgente. L'arbitrage y porte sur le délai de réponse acceptable lors d'une réquisition, pas sur le coût |

**Alternative retenue, à coût nul :** supprimer les `SELECT *` des requêtes de
lookup (voir Q2). Le gain est du même ordre de grandeur, sans service facturé.

---

### 4.4 Le constat qui traverse les trois profils

| Requête | Processing | Synchronization |
|---------|-----------|-----------------|
| Q1 | ~0 % | 50,0 % |
| Q2 | 1,4 % | 68,1 % |
| Q3 | ~0 % | 62,3 % |

**Le calcul ne dépasse jamais 1,4 % du temps d'exécution.** Entre la moitié et
les deux tiers partent en synchronisation — de la coordination entre le nœud de
calcul et le service cloud, c'est-à-dire de l'attente.

C'est la quatrième fois que ce projet aboutit au même constat par un chemin
différent :

1. 105 tests coûtent 4,5 fois le temps des 18 modèles (§ 2) ;
2. le microbatch perd en découpant le travail en 731 instructions (§ 3.2) ;
3. le COPY représente 2 % de la chaîne d'ingestion (§ 1) ;
4. aucune des trois requêtes BI ne consacre plus de 1,4 % de son temps à calculer.

**Conséquence pour la stratégie d'optimisation :** au scale M, tout gain viendra
de la **réduction du nombre de requêtes** et de leur **parallélisation**, jamais
de l'optimisation du SQL de chacune. Les leviers classiques — clustering,
Search Optimization, dimensionnement du warehouse — n'ont pas de prise sur un
temps majoritairement passé à attendre.

Ce profil s'inversera au scale L : les coûts fixes resteront constants pendant
que le volume de calcul sera multiplié par 10. **Toutes les conclusions de cette
section doivent être revalidées à ce volume avant d'être présentées comme des
gains de production.**

## 5. Sprint 4 — Historisation et multi-devises

### 5.1 Correction du calcul FX (US 4.2)

#### Le bug

`fct_transactions` convertissait en euros par **multiplication** alors que le
référentiel cote EUR → devise :

```sql
-- avant
round(b.montant * coalesce(fx.taux, ...), 2) as montant_eur
-- après
round(b.montant / nullif(coalesce(fx.taux, ...), 0), 2) as montant_eur
```

Détecté sur une ligne réelle lors de l'analyse Query Profile du Sprint 3.3 :
une transaction de **7,51 DKK** ressortait à **57,25 EUR** au lieu de 1,01 —
**57 fois trop**.

Trois raisons expliquent qu'il ait survécu jusque-là :

| Raison | Détail |
|--------|--------|
| Invisible sur l'euro | 55 % des transactions sont en EUR, où taux = 1 : multiplier ou diviser donne le même résultat |
| Aucun test ne le couvrait | `accepted_range` sur `montant_eur` acceptait 0 à 100 000 000 |
| Contradiction interne non détectée | `montant_eur` (recalculé, faux) et `montant_signe_eur` (repris du staging, juste) différaient d'un facteur 57 **sur la même ligne** |

#### Vérification après correction

| Devise | Volume | Montant moyen (devise) | Montant moyen (EUR) | Taux moyen |
|--------|--------|------------------------|---------------------|-----------|
| EUR | 517 128 | 67,94 | 67,94 | 1,0000 |
| USD | 141 013 | 67,86 | 62,31 | 1,0927 |
| GBP | 94 083 | 68,04 | **85,05** | 0,8003 |
| CHF | 47 142 | 68,44 | 65,95 | 1,0388 |
| NOK | 28 508 | 67,84 | 6,37 | 10,6816 |
| SEK | 28 390 | 66,21 | 6,01 | 11,0655 |
| DKK | 28 129 | 67,32 | 8,54 | 7,8925 |
| CZK | 18 831 | 67,68 | 2,81 | 24,1110 |
| PLN | 18 827 | 68,74 | 15,74 | 4,3723 |
| JPY | 18 793 | 66,66 | **0,38** | 173,8616 |

Le sens est désormais correct dans les deux directions : la livre, plus forte que
l'euro, donne **plus** d'euros (85,05 pour 68,04 GBP) ; le yen, plus faible, en
donne **moins** (0,38 pour 66,66 JPY).

#### Le test qui ferme la porte

`tests/assert_fx_montant_eur_coherent.sql` recalcule la conversion depuis le
référentiel et la confronte à la valeur stockée, tolérance 0,01 % — le critère
exact du briefing.

**L'échantillon est stratifié par devise** (20 transactions pour chacune des 10),
et non tiré au hasard. Un tirage aléatoire de 100 lignes en contiendrait 55 en
euros, où l'erreur est invisible : c'est précisément ce qui avait laissé passer
le bug.

#### Corrections connexes

| Correction | Motif |
|------------|-------|
| `montant_signe_eur` recalculé dans le fait | Était repris du staging : deux colonnes du même enregistrement se contredisaient |
| Colonnes `taux_change_retenu` et `is_taux_referentiel` ajoutées | Sans le taux appliqué, impossible de rejouer un calcul a posteriori — exigence comptable |
| Calendrier FX déduit des bornes réelles du référentiel | Il était figé (2023-2025) alors que les données couvrent 12/2022 → 01/2025. Des bornes en dur créent un trou silencieux : la transaction tombe sur le repli sans qu'aucun signal ne soit émis |
| Indicateur `is_taux_reporte` | Distingue une cotation réelle d'un report de week-end |

> **Limite du jeu de données.** Le générateur tire les montants dans la même
> distribution quelle que soit la devise (≈ 67 unités partout). Une transaction
> de 67 yens — 38 centimes — n'a aucun réalisme. Sans effet sur la logique FX,
> mais toute analyse de panier moyen par devise est faussée.

---

### 5.2 SCD Type 2 sur les comptes (US 4.1)

#### Résultat

| Mesure | Valeur |
|--------|--------|
| Versions totales | **40 009** |
| Comptes distincts | 20 000 |
| **Versions courantes** | **20 000** |
| Versions max pour un compte | 5 |

`nb_comptes = nb_versions_courantes` : la contrainte du briefing — exactement une
version courante par `compte_id` — est vérifiée sur l'ensemble de la table.

Historique d'un compte témoin après les trois changements provoqués :

| Version | Statut | KYC | AML | Segment | Courante |
|---------|--------|-----|-----|---------|----------|
| 1 | actif | intermediate | clean | mass_market | non |
| 2 | actif | not_verified | clean | mass_market | non |
| 3 | suspendu | not_verified | manual_review | mass_market | non |
| 4 | actif | advanced | cleared | premium | non |
| 5 | cloture | advanced | cleared | premium | **oui** |

La version 2 provient de la régénération des données, non d'un changement
provoqué. Sur un autre compte témoin, elle ne montre **aucune différence visible**
dans les colonnes affichées : c'est l'`email` — surveillé par `check_cols` — qui
avait changé. Bonne illustration de ce que la stratégie `check` détecte au-delà
de l'inspection visuelle.

#### Constat majeur : l'historisation est prospective

La requête de reconstitution d'état au **15/06/2024** renvoie **zéro ligne**.

Toutes les versions débutent au 05/10/2026, date du premier `dbt snapshot`.
**Un snapshot n'enregistre que ce qui change à partir du moment où il tourne ; il
ne reconstitue jamais le passé.**

Pour une exigence de piste d'audit réglementaire, c'est déterminant :

- une demande du type « quel était le niveau KYC de ce compte en juin 2024 »
  **reste sans réponse** ;
- la profondeur d'historique disponible est bornée par la date de mise en service
  du snapshot, pas par l'ancienneté des comptes ;
- reconstituer l'antériorité suppose que la source conserve elle-même un
  historique — ce qui est rarement le cas d'un core banking exposant l'état
  courant.

**Recommandation :** mettre le snapshot en production **avant** tout besoin
d'audit, et documenter sa date de démarrage comme début de la couverture
réglementaire. C'est une décision à prendre tôt, car elle ne se rattrape pas.

#### Choix de modélisation

| Choix | Motif |
|-------|-------|
| `date_fin_validite = 9999-12-31`, jamais NULL | Un NULL impose `(… is null or …)` à chaque consommateur ; la première omission produit une requête qui ne renvoie rien, sans erreur |
| Borne haute **exclue** | Deux versions consécutives se touchent exactement ; un `BETWEEN` sur bornes incluses ramènerait 2 lignes au jour de bascule |
| Surrogate key = hash(compte_id, date_debut_validite) | Identifie une **version**, pas un compte : c'est elle que référencerait un fait historisé |
| Durée exposée en jours **et en heures** | Trois changements espacés de minutes donnent une durée nulle en jours — or le délai de traitement d'une revue AML est justement la métrique attendue |

#### Tests

| Test | Risque couvert |
|------|----------------|
| `assert_scd2_une_seule_version_courante` | 2 versions courantes dupliquent les lignes de toute jointure sur l'état présent ; 0 version rend le compte invisible. Les deux sont silencieux |
| `assert_scd2_periodes_sans_chevauchement` | Distingue **chevauchement** (la requête « état au 15/06 » ramène 2 lignes) et **trou** (elle n'en ramène aucune) |

14 tests au total sur `dim_comptes_scd2`, tous passants.

#### Limite non corrigée : `target_schema` figé

Le snapshot conserve `target_schema='snapshots'` en dur. Depuis dbt 1.9, `schema`
est préférable : il passe par `generate_schema_name` et rend le snapshot
conscient de son environnement. En l'état, **dev, CI et prod écrivent dans le même
schéma**.

Migration non effectuée : un snapshot ne se reconstruit pas, et changer sa
destination créerait une table vide en perdant l'historique accumulé. À traiter au
Sprint 5, avec un `CLONE` préalable de la table existante.

`invalidate_hard_deletes=True` a en revanche été remplacé par
`hard_deletes='invalidate'` — comportement identique, dépréciation levée, aucune
table déplacée.

---

## 6. Décisions prises

### Ingestion (Sprint 1)

| Décision | Justification |
|----------|---------------|
| **Clustering key supprimée sur les tables RAW** (`raw_transactions`, `raw_virements`), non réintégrée | Clé à expression (`DATE_TRUNC`) rejetée par COPY INTO. Aucun bénéfice de pruning : le RAW est lu intégralement par les modèles staging, qui filtrent sur `_loaded_at`. Clauses commentées dans `02_ddl_raw_tables.sql` pour que le script reste rejouable. |
| **Découpage des transactions en 2 parts** de 500 000 lignes | Contrainte d'upload + un COPY parallélise par fichier. Viser 100-250 Mo compressés par fichier au scale L. |
| **Sizing de `WH_INGESTION` conservé** (LARGE) | Consigne de l'exercice. Constat documenté : 0,83 crédit pour 20 s de COPY effectif — un XSMALL suffirait, le parallélisme d'un COPY dépendant du nombre de fichiers et non de la taille du warehouse. |

### Stratégie incrémentale (Sprint 3.1 / 3.2)

| Décision | Justification |
|----------|---------------|
| **`merge` retenu, microbatch écarté** | ×90 sur un build complet (23 s contre ≈ 35 min), ×1,6 sur un run quotidien (13,9 s contre 21,7 s). Surtout : microbatch découpe sur `date_transaction` alors que les mises à jour (validation, rapprochement, revue AML) arrivent longtemps après l'événement — il irait moins vite **en faisant moins bien**. |
| **Prototype microbatch conservé**, taggé `prototype` | Comparaison rejouable au scale L, où le rapport pourrait s'inverser. |
| **Fenêtre de lookback paramétrable** via `var('incremental_lookback_days')` = 7 | Surchargeable en ligne de commande. Borne relative au `max(_loaded_at)` chargé et non à `CURRENT_DATE()` : aucun trou si le pipeline s'interrompt plusieurs jours. |
| **`merge_update_columns` en liste blanche** (17 colonnes) | Fige à l'insertion tout ce qui ne change jamais (montant, devise, dates) : moins de micro-partitions réécrites par le MERGE. |
| **Grain de `fct_transactions` inchangé** (`validee` + `en_attente`) | Limite des lignes fantômes documentée plutôt que corrigée — voir `docs/DESIGN.md` § Limites connues. |

### Performance (Sprint 3.3)

| Décision | Justification |
|----------|---------------|
| **Clustering key conservée sur `fct_transactions`** `(tenant_id, date_trunc('month', date_transaction))` | `average_depth` = 3,71 au-dessus de la cible, mais **88 % de pruning mesuré** sur le motif de filtrage dominant (Q1 : 2 partitions sur 17). La métrique mesure la qualité du tri, pas l'efficacité réelle. Coût de reclustering automatique constaté : **nul**. |
| **Search Optimization : non activée** | Aucun effet mesurable (9/17 partitions avant comme après). Prévisible : les octets scannés pèsent 27,5 % d'une requête de 1,1 s, soit un gain plafonné à 0,3 s. Estimations de coût inexploitables à ce volume (bruit d'échantillonnage, maintenance non calculable avant 7 jours). À réévaluer en production. |
| **Alternative retenue : supprimer les `SELECT *`** des lookups applicatifs | Q2 scanne 20,22 Mo pour une ligne contre 1,41 Mo pour Q1 et ses 5 715 lignes — l'écart vient des 43 colonnes lues contre 5. Gain du même ordre que Search Optimization, à coût nul. |
| **Materialized view : non retenue** | Aucune requête ne la justifie à ce stade. Coût de maintenance continu sur une table mergée quotidiennement, pour un gain nul là où le calcul représente moins de 1,4 % du temps. |
| **Sizing de `WH_DEV` conservé** (XSMALL) | Aucun spill sur les trois requêtes profilées, y compris une jointure de 634 000 lignes avec `COUNT(DISTINCT)`. Le spill est le signal qui justifierait de monter en taille ; il est absent. |

### Versions et outillage

| Décision | Justification |
|----------|---------------|
| **`dbt-snowflake` aligné en 1.12.2** sur dbt-core 1.12.5 | Les stratégies de matérialisation sont implémentées par l'adaptateur : la 1.8.4 ne connaissait pas microbatch. |
| **`snowflake-cli` isolé dans un venv dédié** | Conflit de dépendances avec dbt sur `snowflake-connector-python`, `click` et `protobuf`. |
| **Syntaxe `arguments:` adoptée** sur les 28 tests génériques | Requise à partir de dbt 1.10. **Conséquence : la CI, qui épingle `dbt-snowflake==1.8.*`, doit être alignée — c'est un prérequis, pas une amélioration.** |

## 7. Coûts Snowflake

| Semaine | Credits WH_INGESTION | Credits WH_TRANSFORM | Credits WH_REPORTING | Total |
|---------|----------------------|----------------------|----------------------|-------|
| S40 (29/09 – 05/10) | 0,834 | — | — | 0,834 (+ 0,61 COMPUTE_WH, hors pipeline) |
