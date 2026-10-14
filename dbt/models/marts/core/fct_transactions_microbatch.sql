-- ============================================================
-- FCT TRANSACTIONS — prototype MICROBATCH (US 3.2)
-- ============================================================
-- Réplique exacte de fct_transactions, à la seule différence de la stratégie
-- incrémentale. Objectif : comparer `merge` et `microbatch` sur le même
-- périmètre fonctionnel, donc toute divergence de logique métier fausserait
-- la comparaison.
--
-- DIFFÉRENCE DE MÉCANIQUE
--   merge      : UNE instruction traite toute la fenêtre de lookback, et
--                rapproche ligne à ligne sur unique_key.
--   microbatch : dbt découpe la période en tranches (ici le jour) et exécute
--                UNE INSTRUCTION PAR TRANCHE. Chaque batch remplace
--                intégralement sa tranche — pas de unique_key, pas de
--                rapprochement ligne à ligne.
--
-- CONSÉQUENCE SUR LES COÛTS — à avoir en tête avant de lancer
--   La période du jeu de données va du 01/01/2023 au 31/12/2024, soit
--   731 jours. Un build complet en batch_size='day' génère donc
--   731 instructions SQL. À ~6 s de coût fixe par requête sur ce projet
--   (cf. PERF_LOG § Baseline), cela représente plus d'une heure de warehouse
--   pour 1 M de lignes — là où le merge fait le même travail en une requête
--   de 23 s.
--
--   Pour tester sans brûler le budget, borner la fenêtre :
--     dbt run --select fct_transactions_microbatch --full-refresh \
--             --event-time-start "2024-12-01" --event-time-end "2025-01-01"
--   soit 31 batches au lieu de 731.
--
-- LIMITE DE LA STRATÉGIE POUR CE CAS D'USAGE
--   microbatch découpe sur `event_time`, c'est-à-dire ici la DATE DE LA
--   TRANSACTION. Or nos mises à jour (passage en_attente → validee,
--   rapprochement bancaire, revue AML) portent sur des transactions
--   ANCIENNES : une transaction de mars corrigée en décembre n'est reprise
--   que si le batch de mars est rejoué. Avec lookback=3, on ne remonte que
--   3 jours en arrière.
--   La stratégie est taillée pour des faits append-only (logs, événements),
--   pas pour un fait dont les lignes sont mises à jour longtemps après
--   l'événement. Voir la recommandation finale dans PERF_LOG § US 3.2.
-- ============================================================

-- DÉSACTIVÉ PAR DÉFAUT — banc d'essai, pas un modèle de production.
-- Pour le construire :
--   dbt run --select fct_transactions_microbatch --full-refresh
--       --vars '{enable_microbatch_prototype: true}'
--       --event-time-start "2024-12-01" --event-time-end "2025-01-01"
--
-- Motif de la désactivation : un sélecteur anodin (`--select int_fx_rates_daily+
-- --full-refresh`) l'a entraîné une fois sans intention, déclenchant
-- 1 383 batches, 33 minutes de warehouse et ≈ 0,55 crédit.
-- Toujours borner la fenêtre : sans --event-time-start/end, le full refresh
-- couvre begin → aujourd'hui, batches vides compris.

{{
    config(
        enabled=var('enable_microbatch_prototype', false),
        materialized='incremental',
        incremental_strategy='microbatch',
        event_time='date_transaction',
        batch_size='day',
        lookback=3,
        begin='2023-01-01',
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental', 'microbatch', 'prototype']
    )
}}

-- NB : on lit stg_transactions directement, et non int_transactions_normalisees.
-- Ce dernier est éphémère (inliné comme CTE) : dbt ne peut pas y appliquer le
-- filtre temporel des batches, qui ne s'applique qu'aux parents matérialisés
-- déclarant eux-mêmes un event_time.
with base as (

    select * from {{ ref('stg_transactions') }}

),

comptes as (

    select
        compte_id,
        type_compte,
        customer_segment,
        pays as pays_compte
    from {{ ref('stg_comptes') }}

),

categories as (

    select
        categorie_id,
        nom_categorie,
        type_categorie,
        groupe
    from {{ ref('stg_categories') }}

),

fx as (

    select
        date_cotation,
        devise_cible as devise,
        taux
    from {{ ref('int_fx_rates_daily') }}

)

select
    -- Clés
    b.transaction_id,
    b.external_transaction_id,
    b.tenant_id,
    b.compte_id,
    b.categorie_id,

    -- Temporalité
    b.date_transaction,
    date_trunc('day',   b.date_transaction)::date as jour_transaction,
    date_trunc('week',  b.date_transaction)::date as semaine_transaction,
    date_trunc('month', b.date_transaction)::date as mois_transaction,
    b.date_valeur,
    b.date_settlement,

    -- Montants
    b.montant,
    b.devise,
    -- Division et non multiplication : le referentiel cote EUR -> devise.
    -- Voir fct_transactions.sql pour le detail de la correction (US 4.2).
    round(b.montant / nullif(coalesce(fx.taux, b.taux_change_applique, 1), 0), 2) as montant_eur,
    b.montant_signe,
    b.montant_signe_eur,
    b.frais,
    b.montant_net,

    -- Type et statut
    b.type_operation,
    b.sens,
    b.statut,
    b.moyen_paiement,
    b.canal,

    -- Enrichissements
    c.type_compte,
    c.customer_segment,
    c.pays_compte,
    cat.nom_categorie,
    cat.type_categorie,
    cat.groupe,

    -- Marchand
    b.marchand_nom,
    b.marchand_categorie,
    b.marchand_pays,
    b.marchand_mcc,

    -- Compliance
    b.aml_score,
    b.aml_flag,
    b.fraud_score,
    b.is_flagged_for_review,

    -- Rapprochement
    b.is_reconciled,
    b.reconciliation_batch_id,

    -- Metadata
    b.source_system,
    b.created_at,
    b.updated_at,
    b._loaded_at

from base b
left join comptes c
    on b.compte_id = c.compte_id
left join categories cat
    on b.categorie_id = cat.categorie_id
left join fx
    on date_trunc('day', b.date_transaction)::date = fx.date_cotation
   and b.devise = fx.devise
where b.statut in ('validee', 'en_attente')
  and b.is_reversal = false
