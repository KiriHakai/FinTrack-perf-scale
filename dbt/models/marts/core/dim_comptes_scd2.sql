-- ============================================================
-- DIM COMPTES SCD TYPE 2 — historisation réglementaire (US 4.1)
-- ============================================================
-- Grain : une ligne = une VERSION d'un compte, valide sur un intervalle.
-- Alimentée par snapshot_comptes (stratégie check sur statut, kyc_level,
-- aml_flag, email, type_compte, customer_segment, is_pep).
--
-- Usage type — retrouver l'état d'un compte à une date donnée, ce que
-- dim_comptes (état courant seul) ne permet pas :
--
--     select * from dim_comptes_scd2
--     where compte_id = 42
--       and '2024-06-15' >= date_debut_validite
--       and '2024-06-15' <  date_fin_validite
--
-- La borne de fin est EXCLUE : deux versions consécutives se touchent sans se
-- chevaucher, et un BETWEEN naïf ne ramène jamais deux lignes.
--
-- date_fin_validite vaut 9999-12-31 pour la version courante, et non NULL :
-- un NULL obligerait chaque consommateur à écrire
-- `(date_fin_validite is null or ... )`, et la première omission produit une
-- requête qui ne renvoie rien sans lever d'erreur.
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'dim', 'scd2'],
        cluster_by=['compte_id']
    )
}}

with snapshot_source as (

    select * from {{ ref('snapshot_comptes') }}

),

versions as (

    select
        compte_id,
        tenant_id,
        numero_compte,
        iban,
        email,
        nom_client,
        prenom_client,
        type_compte,
        devise,
        statut,
        kyc_level,
        kyc_date_verification,
        aml_flag,
        customer_segment,
        is_pep,
        risk_score,
        updated_at,

        dbt_valid_from as date_debut_validite,

        -- Version courante : borne haute conventionnelle plutôt que NULL
        coalesce(dbt_valid_to, '9999-12-31'::timestamp_ntz) as date_fin_validite,

        (dbt_valid_to is null) as is_current,

        row_number() over (
            partition by compte_id
            order by dbt_valid_from
        ) as version_number,

        count(*) over (partition by compte_id) as nb_versions_compte

    from snapshot_source

)

select
    -- Surrogate key : identifie une VERSION, pas un compte.
    -- C'est elle que référencent les faits historisés, là où un compte_id seul
    -- ne saurait pas de quelle version il parle.
    {{ dbt_utils.generate_surrogate_key(['compte_id', 'date_debut_validite']) }}
        as compte_version_key,

    compte_id,
    tenant_id,

    -- Attributs surveillés par la stratégie check du snapshot
    statut,
    kyc_level,
    aml_flag,
    customer_segment,
    is_pep,
    type_compte,
    email,

    -- Attributs de contexte
    numero_compte,
    iban,
    nom_client,
    prenom_client,
    devise,
    kyc_date_verification,
    risk_score,

    -- Validité temporelle
    date_debut_validite,
    date_fin_validite,
    is_current,
    version_number,
    nb_versions_compte,
    (version_number = 1) as is_version_initiale,

    -- Durée de validité, utile aux analyses de conformité :
    -- « combien de temps un compte est-il resté en aml_flag = suspicious ? »
    -- Exposée en jours ET en heures : une revue AML traitée dans la journée
    -- produit une version de durée nulle en jours, ce qui masquerait le délai
    -- de traitement — précisément la métrique attendue par la conformité.
    datediff(
        'day',
        date_debut_validite,
        case when is_current then current_timestamp() else date_fin_validite end
    ) as duree_validite_jours,
    datediff(
        'hour',
        date_debut_validite,
        case when is_current then current_timestamp() else date_fin_validite end
    ) as duree_validite_heures,

    updated_at

from versions
