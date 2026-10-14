-- ============================================================
-- SCRIPT 06 — Simulation d'un lot d'ingestion incrémental
-- ============================================================
-- Objet : valider l'US 3.1 — « testez le comportement des mises à jour de
-- statut : une transaction en_attente qui passe validee doit être
-- correctement mergée ».
--
-- Sans ce script, impossible de démontrer quoi que ce soit : le jeu de données
-- est chargé en une fois, donc un seul lot. On fabrique ici un second lot qui
-- combine les trois cas qu'un pipeline incrémental doit savoir traiter :
--
--   CAS 1 — MISE À JOUR  : des transactions existantes passent en_attente →
--                          validee. Elles doivent être mises à jour sur place,
--                          sans créer de doublon.
--   CAS 2 — INSERTION    : de nouvelles transactions arrivent. Elles doivent
--                          être ajoutées.
--   CAS 3 — HORS FENÊTRE : une transaction ancienne est modifiée sans que son
--                          _loaded_at soit rafraîchi. Elle NE doit PAS être
--                          reprise — c'est la limite assumée de la stratégie,
--                          et il faut savoir la montrer.
--
-- Mode d'emploi :
--   1. Exécuter les sections 0 à 3 ci-dessous
--   2. Relancer dbt :  dbt run --select stg_transactions+ --target dev
--   3. Exécuter la section 4 (contrôles) et comparer aux attendus
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_INGESTION;
USE DATABASE FINTRACK_PROD;
USE SCHEMA RAW;

ALTER SESSION SET QUERY_TAG = 'simulate_delta|fintrack_perf_scale';

-- ============================================================
-- 0. PHOTO AVANT — à conserver pour comparaison
-- ============================================================
SELECT
    COUNT(*)                                                   AS nb_total,
    COUNT_IF(statut = 'en_attente')                            AS nb_en_attente,
    COUNT_IF(statut = 'validee')                               AS nb_validees,
    MAX(_loaded_at)                                            AS dernier_chargement
FROM raw_transactions;

-- Les 20 transactions en_attente les plus récemment chargées : ce sont elles
-- qu'on va faire basculer. On mémorise leurs identifiants.
CREATE OR REPLACE TEMPORARY TABLE tmp_tx_a_valider AS
SELECT transaction_id
FROM raw_transactions
WHERE statut = 'en_attente'
ORDER BY _loaded_at DESC
LIMIT 20;

SELECT transaction_id FROM tmp_tx_a_valider ORDER BY transaction_id;

-- ============================================================
-- 1. CAS 1 — Mises à jour de statut (en_attente → validee)
-- ============================================================
-- Le _loaded_at est rafraîchi : c'est ce qui fait entrer ces lignes dans la
-- fenêtre incrémentale. En production, ce serait un nouveau fichier source
-- contenant la version à jour de ces transactions.
UPDATE raw_transactions t
SET
    statut            = 'validee',
    statut_precedent  = 'en_attente',
    date_traitement   = CURRENT_TIMESTAMP(),
    is_reconciled     = TRUE,
    date_reconciliation = CURRENT_TIMESTAMP(),
    updated_at        = CURRENT_TIMESTAMP(),
    _loaded_at        = CURRENT_TIMESTAMP()
FROM tmp_tx_a_valider s
WHERE t.transaction_id = s.transaction_id;

-- ============================================================
-- 2. CAS 2 — Nouvelles transactions
-- ============================================================
-- On clone 10 transactions existantes en leur donnant de nouveaux
-- identifiants, au-delà du maximum actuel.
INSERT INTO raw_transactions
SELECT
    (SELECT MAX(transaction_id) FROM raw_transactions)
        + ROW_NUMBER() OVER (ORDER BY transaction_id)          AS transaction_id,
    'EXT-DELTA-' || LPAD(ROW_NUMBER() OVER (ORDER BY transaction_id), 10, '0'),
    tenant_id, compte_id, compte_source_iban, compte_dest_iban,
    DATEADD('day', 1, date_transaction), date_valeur, date_comptabilisation,
    date_reception, date_traitement, date_settlement,
    montant, devise, montant_eur, taux_change_applique,
    frais, frais_devise, montant_net, type_operation, sens,
    categorie_id, categorie_auto_detectee, confiance_categorie,
    sous_categorie, tags,
    marchand_nom, marchand_id, marchand_categorie, marchand_pays,
    marchand_mcc, marchand_siret,
    moyen_paiement, carte_id, carte_last4, carte_type, carte_reseau,
    authentification_3ds,
    canal, device_type, device_id, user_agent, ip_address, session_id,
    geolocation_lat, geolocation_lon,
    'en_attente'            AS statut,          -- arrivent non validées
    NULL                    AS statut_precedent,
    nb_tentatives, date_derniere_tentative, raison_rejet, code_erreur,
    message_erreur,
    aml_score, aml_flag, aml_reviewed_by, aml_review_date,
    fraud_score, fraud_rules_triggered, is_flagged_for_review,
    FALSE                   AS is_reconciled,   -- pas encore rapprochées
    NULL                    AS date_reconciliation,
    reconciliation_batch_id, external_reference, internal_reference,
    description, description_brute, description_enrichie, libelle_court,
    source_system, source_file_batch_id,
    CURRENT_TIMESTAMP()     AS created_at,
    CURRENT_TIMESTAMP()     AS updated_at,
    CURRENT_TIMESTAMP()     AS loaded_at,
    processing_version, is_test, is_reversal, original_transaction_id,
    CURRENT_TIMESTAMP()     AS _loaded_at
FROM raw_transactions
WHERE statut = 'validee'
  AND is_test = FALSE
QUALIFY ROW_NUMBER() OVER (ORDER BY transaction_id) <= 10;

-- ============================================================
-- 3. CAS 3 — Modification HORS fenêtre (piège volontaire)
-- ============================================================
-- Une transaction ancienne est corrigée côté source, mais son _loaded_at
-- n'est pas rafraîchi — cas typique d'un correctif appliqué en base sans
-- repasser par la chaîne d'ingestion.
-- Le modèle incrémental NE la verra PAS : c'est la limite de la stratégie,
-- à documenter plutôt qu'à masquer.
UPDATE raw_transactions
SET statut = 'validee',
    statut_precedent = 'en_attente',
    updated_at = CURRENT_TIMESTAMP()
    -- _loaded_at volontairement NON modifié
WHERE transaction_id = (
    SELECT transaction_id
    FROM raw_transactions
    WHERE statut = 'en_attente'
    ORDER BY _loaded_at ASC
    LIMIT 1
);

-- ============================================================
-- 4. CONTRÔLES — à exécuter APRÈS le dbt run
-- ============================================================
-- Commande dbt à lancer entre les sections 3 et 4 :
--     dbt run --select stg_transactions+ --target dev
--
-- Remplacer DEV_HAKAI par votre schéma si nécessaire.

-- 4.a Les 20 transactions doivent être VALIDEE dans le fait, sans doublon.
--     Attendu : 20 lignes, statut = 'validee', nb_occurrences = 1 partout.
SELECT
    f.transaction_id,
    f.statut,
    f.is_reconciled,
    COUNT(*) OVER (PARTITION BY f.transaction_id) AS nb_occurrences
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS f
JOIN tmp_tx_a_valider s ON f.transaction_id = s.transaction_id
ORDER BY f.transaction_id;

-- 4.b Les 10 nouvelles transactions doivent être présentes.
--     Attendu : 10 lignes.
SELECT COUNT(*) AS nb_nouvelles
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
WHERE external_transaction_id LIKE 'EXT-DELTA-%';

-- 4.c Aucun doublon introduit par le merge sur l'ensemble du fait.
--     Attendu : aucune ligne.
SELECT transaction_id, COUNT(*) AS n
FROM FINTRACK_DEV.DEV_HAKAI_MARTS_CORE.FCT_TRANSACTIONS
GROUP BY transaction_id
HAVING COUNT(*) > 1;

-- 4.d Volumétrie traitée par le run incrémental.
--     Attendu : quelques centaines de lignes, PAS 1 000 000.
--     C'est la preuve que l'incrémental fonctionne enfin.
SELECT
    COUNT(*) AS nb_lignes_dans_la_fenetre
FROM raw_transactions
WHERE _loaded_at >= DATEADD('day', -7, (SELECT MAX(_loaded_at) FROM raw_transactions));
