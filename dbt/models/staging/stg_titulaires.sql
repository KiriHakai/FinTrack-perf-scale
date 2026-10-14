{{
    config(
        materialized='view',
        tags=['staging', 'core', 'titulaires']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_titulaires') }}
)

select
    titulaire_id,

    -- PII (à masquer via masking policies dans le projet Sécurité)
    {{ dbt_utils.generate_surrogate_key(['nom', 'prenom', 'date_naissance']) }} as titulaire_hash,
    nom,
    prenom,
    email,
    telephone,
    date_naissance,

    upper(pays_residence) as pays_residence,
    is_pep,

    created_at,
    updated_at,
    _loaded_at

from source
