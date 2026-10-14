{{
    config(
        materialized='incremental',
        unique_key='virement_id',
        incremental_strategy='merge',
        cluster_by=['tenant_id', "date_trunc('month', date_virement)"],
        tags=['staging', 'virements', 'incremental']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_virements') }}
    {% if is_incremental() %}
        -- Même fenêtre paramétrable que les transactions, par cohérence :
        -- une fenêtre plus courte ici créerait un décalage entre les deux faits
        -- lors d'un rattrapage après incident.
        where _loaded_at >= (
            select dateadd('day', -{{ var('incremental_lookback_days') }}, max(_loaded_at))
            from {{ this }}
        )
    {% endif %}
)

select
    virement_id,
    tenant_id,
    compte_source_id,
    compte_dest_id,
    montant,
    upper(devise) as devise,
    date_virement::timestamp_ntz as date_virement,
    date_execution::timestamp_ntz as date_execution,
    motif,
    reference,
    lower(statut) as statut,
    lower(type_virement) as type_virement,
    coalesce(frais, 0) as frais,
    created_at,
    updated_at,
    _loaded_at

from source
