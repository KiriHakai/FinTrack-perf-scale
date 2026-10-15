-- ============================================================
-- MART SUPERVISION — volumétrie quotidienne et détection d'écarts
-- ============================================================
-- Destiné au rapport Power BI. Grain : une ligne = (jour, tenant).
--
-- POURQUOI NE PAS BRANCHER POWER BI SUR ELEMENTARY DIRECTEMENT.
-- Les tables du package (data_monitoring_metrics, elementary_test_results)
-- sont des structures internes : leurs colonnes changent entre versions
-- mineures, et un rapport qui s'y branche casse à la prochaine montée de
-- version. Ce modèle joue le rôle d'interface stable — même raisonnement que
-- les contrats dbt sur fct_transactions.
--
-- La détection reprend la logique de mart_transactions_anomalies : moyenne et
-- écart-type mobiles, fenêtre excluant le jour courant pour qu'un pic ne
-- participe pas à sa propre référence.
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['jour'],
        tags=['marts', 'supervision']
    )
}}

{% set fenetre_jours = 28 %}
{% set seuil_ecart = 3 %}

with quotidien as (

    select
        jour_transaction                                    as jour,
        tenant_id,
        count(*)                                            as nb_transactions,
        count(distinct compte_id)                           as nb_comptes_actifs,
        sum(montant_eur)                                    as montant_total_eur,
        count_if(statut = 'validee')                        as nb_validees,
        count_if(is_reconciled)                             as nb_rapprochees,
        count_if(is_flagged_for_review)                     as nb_signalees_compliance
    from {{ ref('fct_transactions', v=1) }}
    group by jour_transaction, tenant_id

),

reference as (

    select
        q.*,

        -- Référence glissante par tenant, excluant le jour courant
        avg(nb_transactions) over (
            partition by tenant_id
            order by jour
            rows between {{ fenetre_jours }} preceding and 1 preceding
        ) as volume_moyen_reference,

        stddev(nb_transactions) over (
            partition by tenant_id
            order by jour
            rows between {{ fenetre_jours }} preceding and 1 preceding
        ) as volume_ecart_type_reference,

        count(nb_transactions) over (
            partition by tenant_id
            order by jour
            rows between {{ fenetre_jours }} preceding and 1 preceding
        ) as nb_jours_reference

    from quotidien q

)

select
    jour,
    tenant_id,

    nb_transactions,
    nb_comptes_actifs,
    round(montant_total_eur, 2)                             as montant_total_eur,
    nb_validees,
    nb_rapprochees,
    nb_signalees_compliance,

    round(100.0 * nb_validees  / nullif(nb_transactions, 0), 2) as taux_validation_pct,
    round(100.0 * nb_rapprochees / nullif(nb_transactions, 0), 2) as taux_rapprochement_pct,

    -- Référence et écart
    round(volume_moyen_reference, 1)                        as volume_moyen_reference,
    round(volume_ecart_type_reference, 1)                   as volume_ecart_type_reference,
    nb_jours_reference,

    round(nb_transactions - volume_moyen_reference, 1)      as ecart_absolu,
    round(
        100.0 * (nb_transactions - volume_moyen_reference)
        / nullif(volume_moyen_reference, 0), 1
    )                                                       as ecart_pct,

    -- Score d'écart : null tant que la référence est trop courte pour
    -- signifier quelque chose. Déclarer "normal" un jour qu'on ne sait pas
    -- juger serait pire que ne rien déclarer.
    case
        when nb_jours_reference < 14 then null
        when volume_ecart_type_reference is null
          or volume_ecart_type_reference = 0 then null
        else round(
            abs(nb_transactions - volume_moyen_reference)
            / volume_ecart_type_reference, 2)
    end                                                     as score_ecart,

    case
        when nb_jours_reference < 14 then 'reference_insuffisante'
        when volume_ecart_type_reference is null
          or volume_ecart_type_reference = 0 then 'reference_insuffisante'
        when abs(nb_transactions - volume_moyen_reference)
             / volume_ecart_type_reference > {{ seuil_ecart }}
            then case when nb_transactions > volume_moyen_reference
                      then 'pic' else 'creux' end
        else 'normal'
    end                                                     as statut_volumetrie,

    coalesce(
        nb_jours_reference >= 14
        and volume_ecart_type_reference > 0
        and abs(nb_transactions - volume_moyen_reference)
            / volume_ecart_type_reference > {{ seuil_ecart }},
        false
    )                                                       as is_anomalie_volume

from reference
