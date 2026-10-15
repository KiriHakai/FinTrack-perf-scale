-- ============================================================
-- SCRIPT 09 — Provoquer une anomalie de volumetrie (US 6.3)
-- ============================================================
-- Elementary compare le volume quotidien d'une table a son propre historique.
-- Sur un jeu de donnees genere a volume regulier, aucune anomalie n'existe
-- naturellement : on en fabrique une.
--
-- Scenario simule : un rejeu d'ingestion cote source. Un lot deja charge est
-- renvoye par erreur, et la journee concernee se retrouve avec 5 fois son
-- volume normal. C'est l'incident d'exploitation le plus courant sur une
-- chaine d'ingestion, et celui qu'un test de volumetrie doit attraper.
--
-- Deroule :
--   1. bloc A  — photo avant
--   2. bloc B  — injection du pic
--   3. dbt run --select fct_transactions --target dev
--   4. dbt test --select fct_transactions.v1 --target dev
--   5. bloc C  — controles
--   6. bloc D  — nettoyage (optionnel)
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_DEV;
USE DATABASE FINTRACK_PROD;
USE SCHEMA RAW;

-- ============================================================
-- A. Volumetrie quotidienne autour de la date ciblee
-- ============================================================
SELECT DATE_TRUNC('day', date_transaction)::date AS jour, COUNT(*) AS nb
FROM raw_transactions
WHERE date_transaction >= '2024-11-15' AND date_transaction < '2024-11-25'
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- B. Injection du pic — 5 000 transactions le 20/11/2024
-- ============================================================
-- Les lignes sont clonees depuis des transactions existantes, avec de
-- nouveaux identifiants et un _loaded_at courant pour entrer dans la fenetre
-- incrementale de fct_transactions.
INSERT INTO raw_transactions
  (transaction_id, external_transaction_id, tenant_id, compte_id,
   date_transaction, montant, devise, montant_eur, taux_change_applique,
   type_operation, sens, categorie_id, statut, is_reconciled,
   is_test, is_reversal, created_at, updated_at, _loaded_at)
SELECT
  (SELECT MAX(transaction_id) FROM raw_transactions) + ROW_NUMBER() OVER (ORDER BY transaction_id),
  'EXT-SPIKE-' || LPAD(ROW_NUMBER() OVER (ORDER BY transaction_id), 8, '0'),
  tenant_id, compte_id,
  -- Toutes sur la meme journee, a des heures reparties
  DATEADD('minute',
          UNIFORM(0, 1439, RANDOM()),
          '2024-11-20 00:00:00'::timestamp_ntz),
  montant, devise, montant_eur, taux_change_applique,
  type_operation, sens, categorie_id,
  'validee', TRUE, FALSE, FALSE,
  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
FROM raw_transactions
WHERE statut = 'validee' AND is_test = FALSE
QUALIFY ROW_NUMBER() OVER (ORDER BY transaction_id) <= 5000;

-- Controle : la journee du 20/11 doit etre tres au-dessus de ses voisines.
SELECT DATE_TRUNC('day', date_transaction)::date AS jour, COUNT(*) AS nb
FROM raw_transactions
WHERE date_transaction >= '2024-11-15' AND date_transaction < '2024-11-25'
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- C. Controles — apres dbt run puis dbt test
-- ============================================================
-- C.1 Le pic est-il bien arrive dans le fait ?
SELECT DATE_TRUNC('day', date_transaction)::date AS jour, COUNT(*) AS nb
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
WHERE date_transaction >= '2024-11-18' AND date_transaction < '2024-11-23'
GROUP BY 1 ORDER BY 1;

-- C.2 Elementary a-t-il signale la journee ?
--     Attendu : une ligne au 2024-11-20, avec un metric_value tres superieur
--     au training_avg.
SELECT bucket_start, metric_value, training_avg, training_stddev,
       training_set_size, training_start, anomaly_score, is_anomalous
FROM FINTRACK_DEV.DEV_HAKAI_elementary.data_monitoring_metrics
WHERE full_table_name ILIKE '%FCT_TRANSACTIONS%'
  AND metric_name = 'row_count'
  AND bucket_start >= '2024-11-15'
ORDER BY bucket_start;

-- ============================================================
-- D. Nettoyage — a executer une fois la demonstration consignee
-- ============================================================
-- DELETE FROM raw_transactions WHERE external_transaction_id LIKE 'EXT-SPIKE-%';
-- puis : dbt run --select fct_transactions --target dev --full-refresh
