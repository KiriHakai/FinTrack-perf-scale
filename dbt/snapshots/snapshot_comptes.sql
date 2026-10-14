{#-
    SCD Type 2 sur les comptes — piste d'audit réglementaire (US 4.1).

    Stratégie `check` et non `timestamp` : la documentation dbt recommande
    `timestamp`, mais elle suppose un `updated_at` fiable côté source. Ici
    `updated_at` est alimenté par le générateur sans garantie de mise à jour à
    chaque changement de KYC ou d'AML — un changement de statut sans
    rafraîchissement de l'horodatage passerait inaperçu. La stratégie `check`
    compare les valeurs elles-mêmes : plus coûteuse, mais elle ne rate rien.

    `hard_deletes='invalidate'` remplace `invalidate_hard_deletes=True`,
    déprécié depuis dbt 1.9. Comportement identique : un compte disparu de la
    source voit sa version courante clôturée.

    LIMITE CONNUE — `target_schema` est figé.
    Depuis dbt 1.9, `schema` est préférable : il passe par generate_schema_name
    et rend le snapshot conscient de son environnement (DEV_<user>_snapshots,
    CI_snapshots_<PR>...). En l'état, dev, CI et prod écrivent dans le MÊME
    schéma `snapshots` et se marchent dessus.
    Migration non effectuée ici : un snapshot ne se reconstruit pas, et changer
    sa destination créerait une table vide en perdant l'historique accumulé.
    À traiter au Sprint 5 avec un CLONE préalable de la table existante.
-#}

{% snapshot snapshot_comptes %}

{{
    config(
        target_schema='snapshots',
        unique_key='compte_id',
        strategy='check',
        check_cols=['statut', 'kyc_level', 'aml_flag', 'email',
                    'type_compte', 'customer_segment', 'is_pep'],
        hard_deletes='invalidate'
    )
}}

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
    updated_at

from {{ source('fintrack_raw', 'raw_comptes') }}

{% endsnapshot %}
