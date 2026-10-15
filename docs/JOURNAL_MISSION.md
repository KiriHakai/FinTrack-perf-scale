# Journal de mission — FinTrack Perf & Scale

Suivi des décisions, de l'avancement et des points ouverts.
Tenu à jour au fil de la mission. Les livrables techniques restent dans
`PERF_LOG.md`, `DESIGN.md` et `CONTRACTS.md`.

---

## Où nous en sommes

*Dernière mise à jour : 15/10/2026*

| Sprint | Périmètre | État |
|--------|-----------|------|
| 1 | Provisioning & ingestion | **Terminé** |
| 2 | Modélisation core, double-écriture, bridge titulaires | **Terminé** |
| 3 | Incrémental, microbatch, clustering, Query Profiles | **Terminé** |
| 4 | Historisation SCD2 & multi-devises | **Terminé** |
| 5 | CI/CD & orchestration | **Non réalisé** |
| 6 | Analytics avancés, contracts, observabilité | **Terminé** |

**Environnement :** Snowflake Enterprise (compte d'essai) — dbt Core 1.12.5 —
dbt-snowflake **1.12.2** — Elementary 0.26.1 — scale M (1 M transactions).

**Pipeline :** 23 modèles, 1 snapshot, 172 tests, exécution complète en 7 min 29.

### Livrables

| Livrable | Fichier | État |
|----------|---------|------|
| Repo dbt complet | `dbt/` | Poussé sur GitHub |
| Journal de performance | `PERF_LOG.md` | Complet |
| Décisions d'architecture | `DESIGN.md` | Complet |
| Contrats et versioning | `CONTRACTS.md` | Complet |
| Rapport final | `RAPPORT_FINAL.md` | Complet |
| Présentation de soutenance | `soutenance_fintrack.pptx` | 12 slides, rendu visuel non vérifié |
| Guide Power BI | `POWERBI.md` | Complet, rapport à construire |
| Questionnaire de validation | `QUIZ_VALIDATION.md` | 25 questions |
| PR de démonstration, CI verte | — | **Non réalisé** |

---

## Décisions

### Sprint 1 — Provisioning & ingestion

| # | Décision | Motif |
|---|----------|-------|
| 1.1 | Scripts 02 et 03 exécutés en **ACCOUNTADMIN** | Les rôles du script 01 ne permettent pas leur exécution telle quelle : `FINTRACK_TRANSFORM_ROLE` n'a ni droit de création sur `RAW`, ni `USAGE` sur `WH_INGESTION`. À documenter comme écart de provisioning. |
| 1.2 | `raw_transactions.csv.gz` découpé en **2 parts de 500 k lignes** | Contrainte de taille à l'upload. Bénéfice secondaire : un COPY parallélise par fichier. Script dédié `03_stage_and_copy_split.sql`. |
| 1.3 | **Clustering keys supprimées** sur `raw_transactions` et `raw_virements`, non réintégrées | Les clés à expression (`DATE_TRUNC`) sont rejetées par COPY INTO. Aucun bénéfice de pruning sur le RAW, lu intégralement par les modèles staging. Réintégrer la clé aurait déclenché un reclustering facturé en continu. |
| 1.4 | Clauses `CLUSTER BY` **commentées** dans `02_ddl_raw_tables.sql` | Le script doit rester rejouable et refléter l'état réel de la base. |
| 1.5 | **Sizing des warehouses conservé** tel que fourni (`WH_INGESTION` en LARGE) | Consigne de l'exercice. Le surcoût constaté (0,83 crédit pour 20 s de COPY) est traité comme un **constat d'analyse** documenté dans `PERF_LOG.md`, non comme un défaut à corriger. |
| 1.6 | Durées de génération et de PUT **non mesurées** au scale M | Non instrumentées lors du chargement. Protocole défini pour le scale L : `time` côté client. |

### Sprint 2 — Modélisation core

| # | Décision | Motif |
|---|----------|-------|
| 2.1 | `fct_virements` : **frais imputés à la seule leg sortante** | C'est l'émetteur qui les supporte ; les porter sur les deux legs les compterait deux fois. |
| 2.2 | Clé technique `virement_leg_key` (hash de `virement_id` + `virement_leg`) | Donne une clé unique testable, en complément de la clé composite utilisée par le merge. |
| 2.3 | Fenêtre incrémentale de `fct_virements` : **3 jours en dur → `var('incremental_lookback_days')`** (7 jours) | La variable existait dans `dbt_project.yml` sans être utilisée. Les 3 jours relevaient du code de départ, non d'une consigne — le briefing n'impose la variable que pour `stg_transactions` et `fct_transactions` (US 3.1). |
| 2.4 | `dim_categories` : **orphelins traités comme racines** et marqués `is_orphelin` | Une catégorie active dont le parent est inactif n'aurait aucun parent à joindre : sans ce traitement elle disparaîtrait silencieusement du référentiel. |
| 2.5 | Profondeur de récursion **bornée à 10 niveaux** | Snowflake ne limite pas les itérations : une récursion cyclique tourne jusqu'au `STATEMENT_TIMEOUT_IN_SECONDS`. |
| 2.6 | Ancre de récursion en **anti-jointure**, non en `NOT IN (select …)` | Snowflake rejette les sous-requêtes dans l'ancre d'une CTE récursive. Forme par ailleurs plus sûre : un `NOT IN` sur colonne nullable renvoie faux pour toutes les lignes dès qu'un NULL est présent. |
| 2.7 | `unit_tests/` déclaré comme **model-path** | dbt ne découvre les tests unitaires que dans les model-paths. Le dossier imposé par le briefing était donc totalement ignoré, sans avertissement. |
| 2.8 | **Générateur de données : modification autorisée** | Nécessaire pour l'US 2.2 (titulaires) et pour corriger les défauts du jeu de données. Chaque correction doit être documentée. |

### Sprint 3 — Incrémental et performance

| # | Décision | Motif |
|---|----------|-------|
| 3.1 | **Fenêtre de lookback paramétrable** via `var('incremental_lookback_days')` sur les 4 modèles incrémentaux | La borne est relative au `max(_loaded_at)` chargé, non à `CURRENT_DATE()` : si le pipeline s'interrompt plusieurs jours, la fenêtre repart du dernier chargement connu, sans trou. |
| 3.2 | `merge_update_columns` étendu à **17 colonnes, en liste blanche** | Tout ce qui n'y figure pas est figé à l'insertion (montant, devise, dates) : moins de micro-partitions réécrites par le MERGE. |
| 3.3 | **Merge conservé, microbatch écarté** | 23,3 s contre 33 min 22 sur un build complet (1 383 instructions contre 1), 13,9 s contre 21,7 s en run quotidien. Argument décisif : microbatch découpe sur `date_transaction` alors que les mises à jour arrivent des semaines après l'événement. |
| 3.4 | Prototype microbatch **conservé mais désactivé par défaut** (`enabled=var(...)`) | Un sélecteur anodin l'avait déclenché involontairement : 33 min de warehouse, ≈ 0,55 crédit. Conservé pour réévaluation au scale L. |
| 3.5 | **Clustering key conservée** sur `fct_transactions` | `average_depth` = 3,71, au-dessus de la cible du briefing, mais **88 % de pruning mesuré** sur le motif de filtrage dominant. La clé définit 192 combinaisons pour 17 micro-partitions : la métrique ne peut pas être bonne à ce volume. Coût de reclustering automatique constaté : nul. |
| 3.6 | **Search Optimization non activée** | Aucun effet mesurable (9/17 partitions avant comme après). Gain théorique plafonné à 0,3 s, les octets scannés ne pesant que 27,5 % d'une requête de 1,1 s. Estimations de coût sous leur propre bruit d'échantillonnage. |
| 3.7 | Alternative retenue : **supprimer les `SELECT *`** des lookups | Le lookup scanne 20,22 Mo pour 1 ligne contre 1,41 Mo pour 5 715 lignes côté agrégat — 43 colonnes lues contre 5. Gain équivalent, à coût nul. |
| 3.8 | **Sizing de `WH_DEV` conservé** (XSMALL) | Aucun déversement mémoire sur les 3 requêtes profilées, y compris une jointure de 634 000 lignes. Le spill est le signal qui justifierait de monter en taille. |
| 3.9 | **Grain de `fct_transactions` inchangé** (`validee` + `en_attente`) | Décision initiale d'élargir le grain, puis retour en arrière : la limite des lignes fantômes est documentée dans `DESIGN.md` § Limites connues plutôt que corrigée. |

### Sprint 4 — Historisation et multi-devises

| # | Décision | Motif |
|---|----------|-------|
| 4.1 | **Conversion FX corrigée** : division et non multiplication | Le référentiel cote EUR → devise. 7,51 DKK ressortaient à 57,25 € au lieu de 1,01. Invisible sur l'euro (55 % des lignes), non couvert par `accepted_range`. |
| 4.2 | `montant_signe_eur` **recalculé dans le fait** | Il était repris du staging : deux colonnes du même enregistrement se contredisaient d'un facteur 57. |
| 4.3 | Colonnes d'audit `taux_change_retenu` et `is_taux_referentiel` ajoutées | Sans le taux appliqué, aucun calcul n'est rejouable a posteriori — exigence du rapprochement comptable. |
| 4.4 | **Calendrier FX déduit des bornes du référentiel** | Il était figé en dur (2023-2025) alors que les données couvrent 12/2022 → 01/2025. Des bornes figées créent un trou silencieux : la transaction tombe sur le taux de repli sans signal. |
| 4.5 | Test FX **stratifié par devise** (20 × 10) et non aléatoire | Un tirage au hasard contiendrait 55 % d'euros, où l'erreur de sens est invisible. C'est ce qui avait laissé passer le bug. |
| 4.6 | SCD2 : `date_fin_validite` = **9999-12-31, jamais NULL**, borne haute exclue | Un NULL impose `(… is null or …)` à chaque consommateur ; la première omission produit une requête vide sans erreur. Bornes exclusives : deux versions consécutives se touchent sans se chevaucher. |
| 4.7 | Snapshot : `invalidate_hard_deletes` → `hard_deletes='invalidate'` | Déprécié depuis dbt 1.9. Comportement identique, aucune table déplacée. |
| 4.8 | `target_schema` du snapshot **laissé en l'état** | `schema` serait préférable (conscience de l'environnement via `generate_schema_name`), mais un snapshot ne se reconstruit pas : changer sa destination perdrait l'historique. Migration à traiter avec un `CLONE` préalable. |

### Sprint 6 — Analytics, contrats, observabilité

| # | Décision | Motif |
|---|----------|-------|
| 6.1 | Cohortes : **dénominateur fixe** = effectif initial de la cohorte | Diviser par les actifs du mois précédent donnerait un taux de survie qui remonte dès qu'un utilisateur revient, masquant l'attrition cumulée. |
| 6.2 | Cohortes : **mois non observés absents**, pas à 0 % | Une cohorte de novembre 2024 ne peut pas avoir de M+6 ; une ligne à 0 % écraserait la moyenne de la colonne. `nb_mois_observables` expose la profondeur comparable. |
| 6.3 | Anomalies : fenêtre glissante **excluant la transaction courante** | L'inclure la ferait participer à sa propre moyenne : plus un montant est aberrant, moins il serait détecté. |
| 6.4 | Anomalies : **30 observations minimum**, sinon `historique_insuffisant` | Un Z-score sur 3 transactions n'a aucune valeur statistique. Une anomalie déclarée normale faute de données est pire qu'une anomalie non classée. |
| 6.5 | **Contrat activé** sur `fct_transactions`, 45 colonnes typées | Vérifié en renommant volontairement une colonne : le build échoue avant toute écriture, les modèles aval passent en SKIP, la table reste intacte. |
| 6.6 | `alias: fct_transactions` sur la **v1** | Sans lui, dbt matérialiserait la table en `FCT_TRANSACTIONS_V1` et tous les outils pointant sur l'emplacement historique la perdraient — l'inverse de l'effet recherché. |
| 6.7 | **v2 en préversion** (`latest_version: 1`), définie comme vue sur v1 | La logique métier n'existe qu'à un endroit, les versions ne peuvent pas diverger, et on ne duplique pas 940 000 lignes pour une colonne calculée. |
| 6.8 | Elementary **installé**, test de volumétrie limité à la v1 | Un test de modèle s'applique à toutes les versions : v2 étant une vue sur v1, l'analyse était payée deux fois (243 s). |
| 6.9 | Power BI branché sur un **mart de supervision dédié**, pas sur les tables d'Elementary | Les structures internes du package changent entre versions mineures. Même logique que les contrats : exposer une interface stable. |
| 6.10 | **Sprint 5 abandonné** au profit du Sprint 6 et des livrables de restitution | Arbitrage de fin de mission : le temps consacré à rendre le projet exécutable et à calibrer l'observabilité. État de la CI documenté dans les points ouverts. |

---

## Points ouverts

### Soldés

| # | Sujet | Résolution |
|---|-------|-----------|
| A | US 2.2 — bridge comptes ↔ titulaires | Générateur enrichi, DDL, staging et bridge livrés, invariant testé |
| B | Défauts du jeu de données | 6 corrigés, 1 documenté (tendance haussière artificielle du volume quotidien) |
| D | Deprecations `arguments:` et `severity` | 28 tests migrés, vérification sémantique automatisée |
| E | Dépôt Git et GitHub | 7 commits poussés sur `KiriHakai/FinTrack-perf-scale` |
| G | Périmètre Elementary | Installé et opérationnel ; Airflow non traité, Sprint 5 abandonné |

### Ouverts

| # | Sujet | Nature |
|---|-------|--------|
| C | **`log_incremental_run` toujours neutralisé** | Nécessiterait `AUDIT.dbt_run_log` dans `FINTRACK_DEV` et le renvoi de `query`. Le besoin de traçabilité est couvert autrement par `mart_supervision_volumetrie`. |
| F | **CI non fonctionnelle** | Adaptateur épinglé en 1.8 (incapable de lire `arguments:` ni d'exécuter microbatch), macro `drop_schema` inexistant, téléchargement du manifest de prod en placeholder, nommage des schémas CI incohérent entre le macro, le profil et le workflow. |
| H | **DAG Airflow** | Squelette non complété. Aucune instance disponible pour l'exécuter. |
| I | **Migration du snapshot** vers `schema` | Nécessite un `CLONE` préalable : un snapshot ne se reconstruit pas. |
| J | **Détection de volumétrie Elementary** | Le pic injecté de 7 470 lignes contre 2 500 n'a pas été signalé malgré trois calibrages. Cause non élucidée. Un mart de supervision maison couvre le besoin. |
| K | **Rendu visuel de la présentation** | Non vérifié : LibreOffice indisponible dans l'environnement de travail. À contrôler à l'ouverture. |
| L | **Rapport Power BI** | Modèle de données et guide livrés ; le fichier `.pbix` reste à construire. |

---

## Défauts du repo livré

Le projet ne s'exécutait pas en l'état. Dix corrections ont été nécessaires.

| # | Fichier | Symptôme | Portée |
|---|---------|----------|--------|
| 1 | `dim_comptes_scd2.sql` | Expression Jinja dans un commentaire SQL sur 2 lignes → `--` lu comme moins unaire | **Projet entier** : aucune commande dbt ne fonctionnait |
| 2 | `macros/set_query_tag.sql` | Macros portant des noms réservés par dbt-snowflake, appelés dans chaque matérialisation | **Toutes les matérialisations** |
| 3 | `macros/log_incremental_run.sql` | `{{ return(query) }}` « désactivé » par un `--` : INSERT dans un schéma AUDIT inexistant | `fct_transactions` |
| 4 | `fct_virements.sql` | `and statut = ...` sans `WHERE` en full refresh | Modèle jamais constructible |
| 5 | `02_ddl_raw_tables.sql` | Clé de clustering à expression rejetée par COPY INTO | Chargement bloqué |
| 6 | `int_fx_rates_daily.sql` | Colonne `date_day` de `date_spine` non aliasée | Modèle en échec |
| 7 | `fct_transactions.sql` | Conversion de devise inversée (× au lieu de ÷) | **Données fausses, aucune erreur** |
| 8 | `dbt_project.yml` + `unit_tests/` | Dossier hors model-paths et override `is_incremental` manquant | **Aucun test unitaire actif** |
| 9 | `packages.yml` | Package déprécié et conflit `duplicate project dbt_date` | `dbt deps` en échec |
| 10 | `_core.yml`, `_sources.yml` | Propriétés déplacées sous `config:` / `arguments:` depuis dbt 1.10 | Avertissements, erreurs en dbt 2.0 |

Deux enseignements transverses :

**Du Jinja « désactivé » avec `--`.** Deux occurrences (`dim_comptes_scd2.sql`,
`log_incremental_run.sql`). Le `--` est un commentaire SQL, pas Jinja : l'expression
est évaluée malgré tout. Dans un cas le parsing du projet entier échouait, dans l'autre
un pre-hook écrivait dans un schéma inexistant.

**Des tests qui ne s'exécutaient pas.** Les tests unitaires livrés n'ont jamais tourné,
pour deux raisons cumulées : `unit_tests/` n'était pas un model-path, et aucun test ne
portait l'override `is_incremental` obligatoire sur un modèle incrémental. Une couverture
de tests décorative donne une fausse assurance — à verser au chapitre des risques
opérationnels du rapport final.

---

## Chiffres clés de la mission

| Mesure | Valeur |
|--------|--------|
| Fenêtre incrémentale, avant → après | 1 000 000 → **30 lignes** |
| Part maximale du temps consacrée au calcul | **1,4 %** |
| Coût des 105 tests rapporté aux 18 modèles | **× 4,5** |
| Merge contre microbatch, build complet | 23,3 s contre **33 min 22** |
| Pruning mesuré malgré une métrique de clustering « mauvaise » | **88 %** |
| Pipeline complet au scale M (objectif : 1 h) | **7 min 29** |
| Chaîne d'ingestion : part de Snowflake | **2 %** (18 s sur 14 min 25) |

**Limite méthodologique principale :** toutes ces mesures portent sur 1 à 2 % du
volume cible. Le profil de temps, dominé par la latence, ne se transpose pas
linéairement — les conclusions doivent être revalidées au scale L.
