-- ============================================================
-- SCRIPT 07 — Analyse de performance (US 3.3)
-- ============================================================
-- Trois volets : clustering, Search Optimization, Query Profiles.
-- Exécuter section par section. Résultats à reporter dans docs/PERF_LOG.md § 4.
-- Adapter DEV_HAKAI au schéma courant si nécessaire.
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_DEV;
USE DATABASE FINTRACK_DEV;

ALTER SESSION SET QUERY_TAG = 'perf_analysis|fintrack_perf_scale';

-- ============================================================
-- A. CLUSTERING
-- ============================================================

-- A.1 Profondeur et répartition sur le fait principal.
--     Lire : average_depth (cible < 3), partition_depth_histogram.
SELECT SYSTEM$CLUSTERING_INFORMATION('DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS');

-- A.2 Profondeur simple, pour comparaison rapide entre tables.
SELECT SYSTEM$CLUSTERING_DEPTH('DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS');

-- A.3 Témoin : une table du même volume SANS clustering key.
SELECT SYSTEM$CLUSTERING_INFORMATION('FINTRACK_PROD.RAW.RAW_TRANSACTIONS');

-- A.4 Clé effectivement appliquée par dbt (colonne CLUSTER_BY).
SHOW TABLES LIKE 'FCT_TRANSACTIONS' IN SCHEMA DEV_HAKAI_MARTS_CORE;

-- ============================================================
-- B. SEARCH OPTIMIZATION — estimation AVANT activation
-- ============================================================
-- Ne rien activer tant que le coût n'est pas arbitré : le service est facturé
-- en continu (stockage de l'index + maintenance à chaque écriture).

-- B.1 Coût estimé sur external_transaction_id (lookup support client).
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS(
    'DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS',
    'EQUALITY(EXTERNAL_TRANSACTION_ID)');

-- B.2 Coût estimé sur iban (recherche conformité).
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS(
    'DEV_HAKAI_MARTS_CORE.DIM_COMPTES',
    'EQUALITY(IBAN)');

-- B.3 Les deux colonnes réunies sur le fait.
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS(
    'DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS',
    'EQUALITY(EXTERNAL_TRANSACTION_ID, RECONCILIATION_BATCH_ID)');

-- ============================================================
-- C. REQUÊTES À PROFILER
-- ============================================================
-- Désactiver le cache de résultats, sinon la seconde exécution d'une requête
-- renvoie instantanément sans rien calculer — et le Query Profile est vide.
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- --------------------------------------------------------
-- Q1 — Dashboard tenant : agrégat filtré sur tenant + mois
-- Teste le pruning apporté par la clustering key.
-- --------------------------------------------------------
SELECT
    tenant_id,
    mois_transaction,
    COUNT(*)                AS nb_transactions,
    SUM(montant_eur)        AS volume_eur,
    AVG(fraud_score)        AS fraude_moyenne
FROM DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
WHERE tenant_id = 3
  AND date_transaction >= '2024-06-01'
  AND date_transaction <  '2024-07-01'
GROUP BY tenant_id, mois_transaction;

-- --------------------------------------------------------
-- Q2 — Lookup ponctuel par identifiant externe
-- Cas d'usage support client. Sans index, Snowflake balaie
-- toutes les micro-partitions : aucune ne peut être élaguée,
-- la colonne n'étant pas dans la clustering key.
-- Remplacer la valeur par un identifiant réel (voir Q2.prep).
-- --------------------------------------------------------
-- Q2.prep : récupérer un identifiant existant
SELECT external_transaction_id
FROM DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
LIMIT 1;

SELECT *
FROM DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
WHERE external_transaction_id = 'A_REMPLACER';

-- --------------------------------------------------------
-- Q3 — Jointure large : solde par compte sur une période
-- Teste le coût des jointures et le spill mémoire.
-- --------------------------------------------------------
SELECT
    c.tenant_id,
    c.customer_segment,
    COUNT(DISTINCT f.compte_id)     AS nb_comptes,
    SUM(f.montant_signe_eur)        AS flux_net_eur
FROM DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS f
JOIN DEV_HAKAI_MARTS_CORE.DIM_COMPTES c
  ON f.compte_id = c.compte_id
WHERE f.date_transaction >= '2024-01-01'
GROUP BY c.tenant_id, c.customer_segment
ORDER BY flux_net_eur DESC;

-- ============================================================
-- D. MÉTRIQUES DES TROIS REQUÊTES
-- ============================================================
-- Le pruning ne figure que dans ACCOUNT_USAGE (latence 45 min à 3 h).
-- Pour une lecture immédiate : Snowsight > Monitoring > Query History >
-- cliquer la requête > onglet Query Profile.
SELECT
    query_id,
    LEFT(query_text, 60)                    AS requete,
    partitions_scanned,
    partitions_total,
    ROUND(100.0 * (1 - partitions_scanned / NULLIF(partitions_total, 0)), 1)
                                            AS pruning_pct,
    bytes_scanned / POWER(1024, 2)          AS mo_scannes,
    bytes_spilled_to_local_storage  / POWER(1024, 2) AS mo_spill_local,
    bytes_spilled_to_remote_storage / POWER(1024, 2) AS mo_spill_remote,
    execution_time / 1000                   AS exec_s,
    compilation_time / 1000                 AS compil_s
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag = 'perf_analysis|fintrack_perf_scale'
  AND start_time > DATEADD('hour', -6, CURRENT_TIMESTAMP())
ORDER BY start_time;

-- Remettre le cache en place une fois les mesures prises.
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
