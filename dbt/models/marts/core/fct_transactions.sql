-- ============================================================
-- FCT TRANSACTIONS — table de faits principale
-- ============================================================
-- Volume cible : 50-100M lignes.
-- Stratégie : incremental merge sur transaction_id,
-- clustering (tenant_id, mois), colonnes essentielles seulement.
--
-- GRAIN : une ligne = une transaction validée ou en_attente, non-reversal.
--
-- LIMITE CONNUE ET ASSUMÉE — lignes fantômes sur changement de statut
-- ------------------------------------------------------------------
-- Ce filtre de statut, combiné à la stratégie `merge`, laisse des lignes
-- obsolètes dans le fait :
--
--   1. une transaction `en_attente` est insérée dans fct_transactions ;
--   2. la source la passe à `rejetee` ;
--   3. elle sort du périmètre du SELECT, donc du jeu source du MERGE ;
--   4. le MERGE ne la voit pas : il ne met à jour que ce qu'il reçoit et ne
--      supprime jamais. La ligne reste dans le fait avec `en_attente`.
--
-- Le fait affirme alors qu'une transaction est en attente alors que la source
-- dit qu'elle est rejetée. Aucun test ne peut le détecter : la ligne est
-- cohérente avec elle-même, seule la confrontation à la source révélerait
-- l'écart.
--
-- Conséquences mesurables :
--   - `mart_tenant_kpis_daily.nb_transactions_rejetees` renvoie
--     structurellement 0 : le fait ne contient aucun statut `rejetee` ;
--   - le taux de validation est surestimé, puisque son dénominateur exclut
--     les échecs ;
--   - la piste d'audit est incomplète côté transactions rejetées.
--
-- Décision : limite documentée, non corrigée à ce stade (le grain défini au
-- cadrage est conservé). Deux correctifs possibles si le besoin se confirme :
--   A. élargir le grain à tous les statuts et filtrer dans les marts via des
--      drapeaux dérivés ;
--   B. conserver le grain et ajouter un post-hook supprimant du fait les
--      lignes dont le statut est sorti du périmètre dans la fenêtre courante.
-- Voir docs/DESIGN.md § Limites connues.
--
-- TODO (Sprint 3) — Optimisations à explorer :
--   1. Passer sur microbatch strategy (dbt 1.9+) pour traitement
--      par fenêtres temporelles
--   2. Ajouter Search Optimization sur external_transaction_id
--   3. Envisager un modèle versioning (v1 / v2) via dbt contracts
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='transaction_id',
        incremental_strategy='merge',
        merge_update_columns=['statut', 'is_reconciled',
                              'reconciliation_batch_id', 'aml_flag',
                              'aml_score', 'fraud_score',
                              'is_flagged_for_review', 'montant_eur',
                              'updated_at'],
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental', 'critical'],
        pre_hook=[
            "{{ log_incremental_run('fct_transactions', 'pre') }}"
        ],
        post_hook=[
            "{{ log_incremental_run('fct_transactions', 'post') }}"
        ]
    )
}}

with base as (
    select * from {{ ref('int_transactions_normalisees') }}

    {% if is_incremental() %}
        -- Fenêtre identique à celle de stg_transactions (var
        -- incremental_lookback_days). Les deux modèles doivent regarder la
        -- même tranche, sinon fct_transactions ignorerait des mises à jour
        -- pourtant présentes dans le staging.
        where _loaded_at >= (
            select dateadd('day', -{{ var('incremental_lookback_days') }}, max(_loaded_at))
            from {{ this }}
        )
    {% endif %}
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
    b.jour_transaction,
    b.semaine_transaction,
    b.mois_transaction,
    b.date_valeur,
    b.date_settlement,

    -- Montants
    b.montant,
    b.devise,

    -- Conversion en euros au taux du jour de la transaction.
    --
    -- SENS DE LA CONVERSION — à ne pas inverser.
    -- int_fx_rates_daily cote EUR -> devise : taux = nombre d'unités de la
    -- devise pour 1 EUR (1 EUR = 7,45 DKK). Pour revenir en euros on DIVISE.
    -- La version initiale multipliait : une transaction de 7,51 DKK ressortait
    -- à 57,25 EUR au lieu de 1,01 EUR, soit 57 fois trop. Le test
    -- accepted_range (0 à 100 000 000) laissait passer l'erreur sans bruit.
    --
    -- Repli en cascade si le référentiel ne couvre pas la date :
    --   1. taux du jour (référentiel, source de vérité)
    --   2. taux appliqué par la source, à défaut
    --   3. 1 pour l'euro, ou si rien n'est disponible
    round(
        b.montant / nullif(coalesce(fx.taux, b.taux_change_applique, 1), 0),
        2
    ) as montant_eur,

    -- Taux effectivement retenu, exposé pour l'audit et le rapprochement
    -- comptable : sans lui, impossible de rejouer le calcul a posteriori.
    coalesce(fx.taux, b.taux_change_applique, 1) as taux_change_retenu,
    (fx.taux is not null)                        as is_taux_referentiel,

    b.montant_signe,

    -- Montant signé recalculé à partir du montant converti ci-dessus, et non
    -- repris du staging : les deux colonnes doivent raconter la même chose.
    -- Avant correction, montant_eur (recalculé, faux) et montant_signe_eur
    -- (issu de la source, juste) divergeaient d'un facteur 57 sur la même ligne.
    case
        when b.type_operation = 'credit'
            then  round(b.montant / nullif(coalesce(fx.taux, b.taux_change_applique, 1), 0), 2)
        when b.type_operation = 'debit'
            then -round(b.montant / nullif(coalesce(fx.taux, b.taux_change_applique, 1), 0), 2)
    end as montant_signe_eur,

    b.frais,
    b.montant_net,

    -- Type et statut
    b.type_operation,
    b.sens,
    b.statut,
    b.moyen_paiement,
    b.canal,

    -- Enrichissements
    b.type_compte,
    b.customer_segment,
    b.pays_compte,
    b.nom_categorie,
    b.type_categorie,
    b.groupe,

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
left join fx
    on b.jour_transaction = fx.date_cotation
   and b.devise = fx.devise
where b.statut in ('validee', 'en_attente')
  and b.is_reversal = false
