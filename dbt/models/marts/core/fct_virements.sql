-- ============================================================
-- FCT VIREMENTS — double-écriture (une leg sortante + une leg entrante)
-- ============================================================
-- Grain : une ligne = une leg de virement.
-- Chaque virement exécuté produit donc EXACTEMENT 2 lignes :
--   - leg 'sortant' : portée par compte_source_id, montant_signe négatif
--   - leg 'entrant' : portée par compte_dest_id,   montant_signe positif
--
-- Ce grain permet d'agréger les mouvements par compte sans se soucier du sens
-- du virement : un simple SUM(montant_signe) par compte donne le flux net.
--
-- Clé unique composite : (virement_id, virement_leg). C'est elle qui est
-- utilisée par la stratégie merge — le virement_id seul ne suffit pas,
-- puisqu'il est partagé par les deux legs.
--
-- Les frais sont imputés à la leg sortante uniquement : c'est l'émetteur qui
-- les supporte. Les porter sur les deux legs les compterait deux fois.
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key=['virement_id', 'virement_leg'],
        incremental_strategy='merge',
        cluster_by=['tenant_id', "date_trunc('month', date_virement)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental']
    )
}}

with virements as (

    select * from {{ ref('stg_virements') }}
    where statut = 'execute'

    {% if is_incremental() %}
        -- Fenêtre glissante paramétrable (cf. dbt_project.yml).
        -- NB : tant que toutes les lignes partagent le même _loaded_at
        -- (un seul COPY), cette fenêtre sélectionne l'intégralité de la table.
        -- Voir docs/PERF_LOG.md, constat n°1.
        and _loaded_at >= (
            select dateadd('day', -{{ var('incremental_lookback_days') }}, max(_loaded_at))
            from {{ this }}
        )
    {% endif %}

),

leg_sortante as (

    select
        v.virement_id,
        'sortant'               as virement_leg,
        v.tenant_id,
        v.compte_source_id      as compte_id,
        v.compte_dest_id        as contrepartie_compte_id,
        v.montant,
        -v.montant              as montant_signe,
        v.devise,
        v.frais,
        v.date_virement,
        v.date_execution,
        v.type_virement,
        v.motif,
        v.reference,
        v.statut,
        v.created_at,
        v.updated_at,
        v._loaded_at
    from virements v

),

leg_entrante as (

    select
        v.virement_id,
        'entrant'               as virement_leg,
        v.tenant_id,
        v.compte_dest_id        as compte_id,
        v.compte_source_id      as contrepartie_compte_id,
        v.montant,
        v.montant               as montant_signe,
        v.devise,
        -- Les frais sont supportés par l'émetteur : 0 côté bénéficiaire.
        0                       as frais,
        v.date_virement,
        v.date_execution,
        v.type_virement,
        v.motif,
        v.reference,
        v.statut,
        v.created_at,
        v.updated_at,
        v._loaded_at
    from virements v

),

double_ecriture as (

    select * from leg_sortante
    union all
    select * from leg_entrante

)

select
    -- Clé technique de la leg
    {{ dbt_utils.generate_surrogate_key(['virement_id', 'virement_leg']) }} as virement_leg_key,

    virement_id,
    virement_leg,
    tenant_id,
    compte_id,
    contrepartie_compte_id,

    -- Montants
    montant,
    montant_signe,
    devise,
    frais,
    montant_signe - frais as montant_net_signe,

    -- Temporalité
    date_virement,
    date_execution,
    date_trunc('day', date_virement)::date as jour_virement,

    -- Attributs
    type_virement,
    motif,
    reference,
    statut,

    -- Métadonnées
    created_at,
    updated_at,
    _loaded_at

from double_ecriture
