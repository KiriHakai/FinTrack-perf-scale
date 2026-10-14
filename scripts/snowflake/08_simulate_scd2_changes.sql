-- ============================================================
-- SCRIPT 08 — Provoquer 3 changements pour valider le SCD2 (US 4.1)
-- ============================================================
-- Trois cycles de modification + dbt snapshot, pour vérifier que
-- l'historisation capture bien chaque état successif.
--
-- Déroulé :
--   1. exécuter le bloc A            → état initial
--   2. dbt snapshot --target dev     → fige la version 1
--   3. exécuter le bloc B            → changement 1 (statut)
--   4. dbt snapshot --target dev     → crée la version 2
--   5. exécuter le bloc C            → changement 2 (KYC + AML)
--   6. dbt snapshot --target dev     → crée la version 3
--   7. exécuter le bloc D            → changement 3 (clôture)
--   8. dbt snapshot --target dev     → crée la version 4
--   9. dbt build --select dim_comptes_scd2 --target dev
--  10. exécuter le bloc E            → contrôles
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_DEV;
USE DATABASE FINTRACK_PROD;
USE SCHEMA RAW;

-- ============================================================
-- A. Comptes témoins
-- ============================================================
-- On fige 3 comptes actifs, suivis sur toute la démonstration.
CREATE OR REPLACE TABLE raw_comptes_temoins AS
SELECT compte_id
FROM raw_comptes
WHERE statut = 'actif' AND kyc_level <> 'advanced'
ORDER BY compte_id
LIMIT 3;

SELECT c.compte_id, c.statut, c.kyc_level, c.aml_flag, c.customer_segment
FROM raw_comptes c JOIN raw_comptes_temoins t USING (compte_id)
ORDER BY c.compte_id;

-- ============================================================
-- B. Changement 1 — suspension pour revue
-- ============================================================
UPDATE raw_comptes c
SET statut = 'suspendu',
    aml_flag = 'manual_review',
    updated_at = CURRENT_TIMESTAMP(),
    _loaded_at = CURRENT_TIMESTAMP()
FROM raw_comptes_temoins t
WHERE c.compte_id = t.compte_id;

-- ============================================================
-- C. Changement 2 — revue favorable, KYC renforcé
-- ============================================================
UPDATE raw_comptes c
SET statut = 'actif',
    kyc_level = 'advanced',
    aml_flag = 'cleared',
    customer_segment = 'premium',
    updated_at = CURRENT_TIMESTAMP(),
    _loaded_at = CURRENT_TIMESTAMP()
FROM raw_comptes_temoins t
WHERE c.compte_id = t.compte_id;

-- ============================================================
-- D. Changement 3 — clôture à la demande du client
-- ============================================================
UPDATE raw_comptes c
SET statut = 'cloture',
    updated_at = CURRENT_TIMESTAMP(),
    _loaded_at = CURRENT_TIMESTAMP()
FROM raw_comptes_temoins t
WHERE c.compte_id = t.compte_id;

-- ============================================================
-- E. Contrôles — après le dernier dbt snapshot + dbt build
-- ============================================================
-- Adapter DEV_HAKAI au schéma courant.

-- E.1 Historique complet des 3 comptes témoins.
--     Attendu : 4 versions par compte (initiale + 3 changements),
--     une seule avec is_current = TRUE, et la chronologie des statuts
--     actif -> suspendu -> actif -> cloture.
SELECT
    compte_id, version_number, statut, kyc_level, aml_flag, customer_segment,
    date_debut_validite, date_fin_validite, is_current, duree_validite_jours
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.DIM_COMPTES_SCD2
WHERE compte_id IN (SELECT compte_id FROM FINTRACK_PROD.RAW.raw_comptes_temoins)
ORDER BY compte_id, version_number;

-- E.2 Reconstitution de l'état à une date passée — l'intérêt du SCD2.
--     Attendu : l'état du compte tel qu'il était, pas son état actuel.
SELECT compte_id, statut, kyc_level, aml_flag
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.DIM_COMPTES_SCD2
WHERE compte_id IN (SELECT compte_id FROM FINTRACK_PROD.RAW.raw_comptes_temoins)
  AND '2024-06-15'::timestamp_ntz >= date_debut_validite
  AND '2024-06-15'::timestamp_ntz <  date_fin_validite
ORDER BY compte_id;

-- E.3 Volumétrie globale de l'historisation.
SELECT
    COUNT(*)                        AS nb_versions,
    COUNT(DISTINCT compte_id)       AS nb_comptes,
    COUNT_IF(is_current)            AS nb_versions_courantes,
    MAX(nb_versions_compte)         AS max_versions_par_compte
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.DIM_COMPTES_SCD2;

-- nb_comptes doit être égal à nb_versions_courantes : un compte, un état présent.

-- Nettoyage de la table témoin, une fois la démonstration terminée.
-- DROP TABLE IF EXISTS FINTRACK_PROD.RAW.raw_comptes_temoins;
