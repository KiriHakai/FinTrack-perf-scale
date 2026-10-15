-- ============================================================
-- MART — Détection d'anomalies par Z-score (US 6.1)
-- ============================================================
-- Grain : une ligne = une transaction validée, avec son score d'écart à
-- l'historique récent du compte.
--
-- Une transaction est anormale si son montant s'écarte de plus de 3 écarts-
-- types de la moyenne mobile 90 jours du compte.
--
-- FENÊTRE GLISSANTE — ce qu'on compare et à quoi.
-- La fenêtre exclut la transaction courante (`rows between 90 preceding and
-- 1 preceding`). L'inclure la ferait participer à sa propre moyenne : un
-- montant extrême tirerait la moyenne vers lui et abaisserait son propre
-- Z-score. Plus le montant est aberrant, moins il serait détecté.
--
-- FENÊTRE EN LIGNES, PAS EN JOURS.
-- `rows between 90 preceding` compte 90 transactions, pas 90 jours. Le
-- briefing parle de « moyenne mobile 90 jours » ; une fenêtre en jours
-- (`range between interval '90 days' preceding`) serait plus fidèle, mais
-- rendrait l'historique dépendant de la fréquence d'usage : un compte dormant
-- n'aurait presque aucun point de comparaison. On retient les 90 dernières
-- transactions, et on expose nb_transactions_historique pour que le seuil de
-- confiance soit lisible.
--
-- ÉCHANTILLON MINIMAL.
-- Un Z-score calculé sur 3 transactions n'a aucune valeur statistique, et un
-- écart-type nul (montants identiques) ferait diverger le calcul. On exige
-- 30 observations minimum, en deçà desquelles la transaction est classée
-- « historique_insuffisant » plutôt que faussement normale.
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['compte_id'],
        tags=['marts', 'analytics', 'anomalies']
    )
}}

{% set seuil_z_eleve = 5 %}
{% set seuil_z_moyen = 4 %}
{% set seuil_z_faible = 3 %}
{% set min_observations = 30 %}

with transactions as (

    select
        transaction_id,
        compte_id,
        tenant_id,
        date_transaction,
        montant_eur,
        devise,
        type_operation,
        marchand_nom,
        marchand_pays,
        canal,
        moyen_paiement,
        fraud_score,
        aml_flag
    from {{ ref('fct_transactions') }}
    where statut = 'validee'

),

statistiques as (

    select
        t.*,

        avg(montant_eur) over (
            partition by compte_id
            order by date_transaction
            rows between 90 preceding and 1 preceding
        ) as moyenne_90j,

        stddev(montant_eur) over (
            partition by compte_id
            order by date_transaction
            rows between 90 preceding and 1 preceding
        ) as ecart_type_90j,

        count(montant_eur) over (
            partition by compte_id
            order by date_transaction
            rows between 90 preceding and 1 preceding
        ) as nb_transactions_historique

    from transactions t

),

scores as (

    select
        *,
        case
            when nb_transactions_historique < {{ min_observations }} then null
            -- Écart-type nul : tous les montants précédents sont identiques.
            -- Diviser par zéro n'a pas de sens ; tout écart est alors
            -- qualitativement anormal mais non quantifiable.
            when ecart_type_90j is null or ecart_type_90j = 0 then null
            else round(
                abs(montant_eur - moyenne_90j) / ecart_type_90j,
                3
            )
        end as z_score
    from statistiques

)

select
    transaction_id,
    compte_id,
    tenant_id,
    date_transaction,
    montant_eur,
    devise,
    type_operation,

    round(moyenne_90j, 2)     as moyenne_90j,
    round(ecart_type_90j, 2)  as ecart_type_90j,
    nb_transactions_historique,
    z_score,

    coalesce(z_score > {{ seuil_z_faible }}, false) as is_anomalie,

    case
        when z_score is null then 'historique_insuffisant'
        when z_score > {{ seuil_z_eleve }}  then 'high'
        when z_score > {{ seuil_z_moyen }}  then 'medium'
        when z_score > {{ seuil_z_faible }} then 'low'
        else 'normal'
    end as severite,

    -- Contexte d'investigation : une anomalie seule n'est pas actionnable,
    -- l'analyste a besoin de savoir où et comment la transaction a eu lieu.
    marchand_nom,
    marchand_pays,
    canal,
    moyen_paiement,

    -- Confrontation au score de fraude du système source : une transaction
    -- statistiquement anormale ET déjà signalée est prioritaire ; une
    -- anomalie que le système source n'a pas vue est le cas le plus
    -- intéressant pour affiner les règles existantes.
    fraud_score,
    aml_flag,
    (coalesce(z_score > {{ seuil_z_faible }}, false) and fraud_score < 50)
        as is_anomalie_non_detectee_source

from scores
