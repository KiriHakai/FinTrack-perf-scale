-- ============================================================
-- SCRIPT 03bis — Stage interne et COPY INTO (transactions splittées)
-- ============================================================
-- Variante de 03_stage_and_copy.sql : identique, sauf que
-- raw_transactions.csv.gz a été découpé en deux fichiers
-- (limite de taille à l'upload) :
--     raw_transactions_part1.csv.gz   (transaction_id 1        → 500 000)
--     raw_transactions_part2.csv.gz   (transaction_id 500 001  → 1 000 000)
-- Chaque part contient sa propre ligne d'en-tête (SKIP_HEADER = 1 les gère).
--
-- Bénéfice perf : COPY INTO parallélise par fichier — deux fichiers
-- sont chargés simultanément, là où un fichier unique est traité en série.
--
-- Instructions :
--   1. Générer les données : python scripts/python/generate_data.py --scale M
--   2. Découper raw_transactions.csv.gz en deux parts (voir en-tête ci-dessus)
--   3. Exécuter la partie STAGE + FILE FORMAT ci-dessous
--   4. Uploader les fichiers via SnowSQL :
--        PUT file://data/raw/*.csv.gz @FINTRACK_STAGE AUTO_COMPRESS=FALSE;
--      (ne pas uploader raw_transactions.csv.gz : seules les deux parts)
--   5. Exécuter les COPY INTO
--
-- Le jeu de données comprend 8 fichiers, dont raw_titulaires et
-- raw_compte_titulaires ajoutés pour l'US 2.2.
-- ============================================================

-- Le rôle d'ingestion ne peut pas écrire dans les tables du schéma RAW :
-- elles sont créées par le script 02, lui-même exécuté en ACCOUNTADMIN faute
-- de droits suffisants sur FINTRACK_TRANSFORM_ROLE. Écart de provisioning
-- documenté dans docs/DESIGN.md § Écarts constatés.
USE ROLE ACCOUNTADMIN;
-- USE ROLE FINTRACK_INGESTION_ROLE;   -- cible à rétablir une fois les grants corrigés
USE WAREHOUSE WH_INGESTION;
USE DATABASE FINTRACK_PROD;
USE SCHEMA RAW;

ALTER SESSION SET QUERY_TAG = 'stage_and_copy|fintrack_perf_scale';

-- ============================================
-- FILE FORMAT réutilisable
-- ============================================
CREATE OR REPLACE FILE FORMAT ff_csv_gz
    TYPE = CSV
    COMPRESSION = GZIP
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'null')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF-8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    TRIM_SPACE = TRUE;

-- ============================================
-- STAGE INTERNE
-- ============================================
-- ATTENTION : CREATE OR REPLACE STAGE SUPPRIME LE CONTENU DU STAGE.
-- Ne jouer cette section QUE lors de la première mise en place, ou après
-- avoir accepté de ré-uploader tous les fichiers (≈ 6 min pour 306 Mo au
-- scale M). En rechargement, démarrer directement à la section COPY INTO.
CREATE OR REPLACE STAGE fintrack_stage
    FILE_FORMAT = ff_csv_gz
    COMMENT = 'Stage interne pour les CSV générés par le script Python';

-- Contrôle : vérifier que les deux parts sont bien présentes après le PUT
LIST @fintrack_stage;

-- ============================================
-- COPY INTO — commandes à exécuter APRÈS le PUT
-- ============================================

-- Tenants (petit fichier)
COPY INTO raw_tenants
FROM @fintrack_stage/raw_tenants.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- Catégories
COPY INTO raw_categories
FROM @fintrack_stage/raw_categories.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- FX rates
COPY INTO raw_fx_rates
FROM @fintrack_stage/raw_fx_rates.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- Comptes
COPY INTO raw_comptes
FROM @fintrack_stage/raw_comptes.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Transactions — gros volume découpé en 2 fichiers.
-- Un seul COPY avec PATTERN charge les deux parts en parallèle.
COPY INTO raw_transactions
FROM @fintrack_stage/
PATTERN = '.*raw_transactions_part[0-9]+[.]csv[.]gz'
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Variante explicite (si vous préférez tracer chaque part séparément
-- pour mesurer les durées dans docs/PERF_LOG.md) :
--
-- COPY INTO raw_transactions
-- FROM @fintrack_stage/raw_transactions_part1.csv.gz
-- FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
-- ON_ERROR = 'CONTINUE'
-- RETURN_FAILED_ONLY = TRUE;
--
-- COPY INTO raw_transactions
-- FROM @fintrack_stage/raw_transactions_part2.csv.gz
-- FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
-- ON_ERROR = 'CONTINUE'
-- RETURN_FAILED_ONLY = TRUE;

-- Titulaires (US 2.2)
COPY INTO raw_titulaires
FROM @fintrack_stage/raw_titulaires.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Rattachements compte <-> titulaire (US 2.2)
COPY INTO raw_compte_titulaires
FROM @fintrack_stage/raw_compte_titulaires.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Virements
COPY INTO raw_virements
FROM @fintrack_stage/raw_virements.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- ============================================
-- VALIDATION POST-LOAD
-- ============================================
SELECT 'raw_tenants'      AS table_name, COUNT(*) AS row_count FROM raw_tenants
UNION ALL SELECT 'raw_categories',    COUNT(*) FROM raw_categories
UNION ALL SELECT 'raw_fx_rates',      COUNT(*) FROM raw_fx_rates
UNION ALL SELECT 'raw_comptes',       COUNT(*) FROM raw_comptes
UNION ALL SELECT 'raw_transactions',  COUNT(*) FROM raw_transactions
UNION ALL SELECT 'raw_virements',     COUNT(*) FROM raw_virements
UNION ALL SELECT 'raw_titulaires',    COUNT(*) FROM raw_titulaires
UNION ALL SELECT 'raw_compte_titulaires', COUNT(*) FROM raw_compte_titulaires
ORDER BY table_name;

-- Contrôle US 2.2 : la somme des clés de répartition doit valoir 1 par compte.
-- Aucune ligne attendue en sortie.
SELECT
    compte_id,
    SUM(allocation_factor) AS somme_allocation
FROM raw_compte_titulaires
WHERE date_fin IS NULL
GROUP BY compte_id
HAVING ABS(SUM(allocation_factor) - 1) > 0.001;

-- Contrôle spécifique au découpage : on doit retrouver 1 000 000 lignes
-- et une plage d'identifiants continue sur les deux parts.
SELECT
    COUNT(*)                     AS nb_transactions,
    COUNT(DISTINCT transaction_id) AS nb_ids_distincts,
    MIN(transaction_id)          AS id_min,
    MAX(transaction_id)          AS id_max
FROM raw_transactions;

-- ============================================
-- MONITORING : historique des COPY
-- ============================================
-- Une ligne par fichier chargé : les deux parts doivent apparaître
-- avec status = 'LOADED' et 500 000 lignes chacune.
SELECT file_name, status, row_count, row_parsed, error_count, last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'RAW.RAW_TRANSACTIONS',
    START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY last_load_time DESC;
