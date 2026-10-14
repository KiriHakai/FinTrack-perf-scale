-- ============================================================
-- BRIDGE COMPTES ↔ TITULAIRES (relation many-to-many) — US 2.2
-- ============================================================
-- Grain : une ligne = un rattachement (compte, titulaire, période).
--
-- Un compte joint a plusieurs titulaires ; un titulaire peut détenir
-- plusieurs comptes. Cette bridge porte la clé de répartition qui permet de
-- ventiler les montants d'un compte entre ses détenteurs :
--
--     SELECT b.titulaire_id,
--            SUM(f.montant_eur * b.allocation_factor) AS depense_personnelle
--     FROM fct_transactions f
--     JOIN bridge_comptes_titulaires b
--       ON f.compte_id = b.compte_id
--      AND f.date_transaction >= b.date_debut
--      AND (b.date_fin IS NULL OR f.date_transaction < b.date_fin)
--     GROUP BY 1
--
-- La jointure DOIT être bornée par la période de validité, sans quoi une
-- transaction serait comptée pour un titulaire qui n'avait pas encore (ou
-- plus) de droits sur le compte. C'est l'intérêt de l'historisation.
--
-- INVARIANT : la somme des allocation_factor d'un compte, à une date donnée,
-- vaut 1. Vérifié par tests/assert_bridge_allocation_somme_un.sql.
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['compte_id'],
        tags=['marts', 'core', 'bridge']
    )
}}

with rattachements as (

    select * from {{ ref('stg_compte_titulaires') }}

),

titulaires as (

    select
        titulaire_id,
        titulaire_hash,
        nom,
        prenom,
        email,
        pays_residence,
        is_pep
    from {{ ref('stg_titulaires') }}

),

comptes as (

    select
        compte_id,
        tenant_id,
        type_compte,
        devise as devise_compte,
        statut as statut_compte
    from {{ ref('stg_comptes') }}

),

-- Nombre de détenteurs par compte : distingue un compte individuel
-- d'un compte joint sans avoir à relire la table
cardinalite as (

    select
        compte_id,
        count(*) as nb_titulaires_compte
    from rattachements
    where date_fin is null
    group by compte_id

)

select
    -- Clé technique du rattachement
    {{ dbt_utils.generate_surrogate_key(['r.compte_id', 'r.titulaire_id', 'r.date_debut']) }}
        as bridge_key,

    -- Clés métier
    r.compte_id,
    r.titulaire_id,
    c.tenant_id,

    -- Nature du rattachement
    r.role_titulaire,
    r.is_primary,
    r.allocation_factor,
    coalesce(card.nb_titulaires_compte, 1) as nb_titulaires_compte,
    (coalesce(card.nb_titulaires_compte, 1) > 1) as is_compte_joint,

    -- Historisation
    r.date_debut,
    r.date_fin,
    r.is_rattachement_courant,

    -- Attributs titulaire (dénormalisés pour éviter une jointure de plus
    -- côté consommateurs BI)
    t.titulaire_hash,
    t.nom,
    t.prenom,
    t.email,
    t.pays_residence,
    t.is_pep,

    -- Attributs compte
    c.type_compte,
    c.devise_compte,
    c.statut_compte,

    r._loaded_at

from rattachements r
inner join titulaires t
    on r.titulaire_id = t.titulaire_id
left join comptes c
    on r.compte_id = c.compte_id
left join cardinalite card
    on r.compte_id = card.compte_id
