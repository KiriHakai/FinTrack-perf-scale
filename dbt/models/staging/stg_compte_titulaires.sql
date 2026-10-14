{{
    config(
        materialized='view',
        tags=['staging', 'core', 'titulaires']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_compte_titulaires') }}
)

select
    compte_titulaire_id,
    compte_id,
    titulaire_id,

    lower(role_titulaire) as role_titulaire,
    allocation_factor,
    is_primary,

    -- Historisation du rattachement : date_fin NULL = rattachement en cours
    date_debut,
    date_fin,
    (date_fin is null) as is_rattachement_courant,

    created_at,
    updated_at,
    _loaded_at

from source
