# Journal de mission — FinTrack Perf & Scale

Suivi des décisions, de l'avancement et des points ouverts.
Tenu à jour au fil de la mission. Les livrables techniques restent dans
`PERF_LOG.md`, `DESIGN.md` et `CONTRACTS.md`.

---

## Où nous en sommes

| Sprint | Périmètre | État |
|--------|-----------|------|
| 1 | Provisioning & ingestion | **Terminé** |
| 2 | Modélisation core & double-écriture | US 2.1 terminée, US 2.2 à faire |
| 3 | Incrémental et performance | À venir — cœur de la mission |
| 4 | Historisation & multi-devises | À venir |
| 5 | CI/CD & orchestration | À venir |
| 6 | Analytics avancés & contracts | À venir |

**Environnement :** Snowflake Enterprise (compte de test, ~200 $ de crédits) —
dbt Core 1.12.5 — dbt-snowflake 1.8.4 — scale M (1 M transactions).

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

---

## Points ouverts

| # | Sujet | Échéance |
|---|-------|----------|
| A | **US 2.2** — bridge comptes ↔ titulaires : enrichir le générateur, les DDL, le staging et la bridge | Sprint 2 |
| B | **Défauts du jeu de données** à corriger dans le générateur, en documentant chacun | Sprint 2-3 |
| C | **Activer `log_incremental_run`** : créer `AUDIT.dbt_run_log` dans `FINTRACK_DEV`, renvoyer `query` au lieu du no-op | Sprint 3 |
| D | **Deprecations dbt restantes** : `arguments:` sur les tests génériques, `severity` sous `config:` | Sprint 5, avec l'alignement de version de la CI |
| E | **Dépôt Git et GitHub** : non initialisés, nécessaires pour la PR de démonstration | Sprint 5 |
| F | **CI** : macro `drop_schema` inexistant, téléchargement du manifest de prod en placeholder, nommage des schémas CI incohérent entre le macro, le profil et le workflow | Sprint 5 |
| G | **Périmètre Elementary et Airflow** : code livré ou réellement exécuté | Sprint 5-6 |

---

## Défauts du repo livré

Le projet ne s'exécutait pas en l'état. Dix corrections ont été nécessaires, détaillées
dans `PERF_LOG.md` § Correctifs. Deux enseignements transverses :

**Du Jinja « désactivé » avec `--`.** Deux occurrences (`dim_comptes_scd2.sql`,
`log_incremental_run.sql`). Le `--` est un commentaire SQL, pas Jinja : l'expression
est évaluée malgré tout. Dans un cas le parsing du projet entier échouait, dans l'autre
un pre-hook écrivait dans un schéma inexistant.

**Des tests qui ne s'exécutaient pas.** Les tests unitaires livrés n'ont jamais tourné,
pour deux raisons cumulées : `unit_tests/` n'était pas un model-path, et aucun test ne
portait l'override `is_incremental` obligatoire sur un modèle incrémental. Une couverture
de tests décorative donne une fausse assurance — à verser au chapitre des risques
opérationnels du rapport final.
