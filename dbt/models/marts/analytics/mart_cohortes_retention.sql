-- ============================================================
-- MART — Analyse de cohortes de rétention (US 6.1)
-- ============================================================
-- Grain : une ligne = (cohorte, mois_offset).
-- Une cohorte regroupe les comptes ouverts le même mois ; on suit la part
-- d'entre eux encore active N mois plus tard.
--
-- Actif = au moins une transaction validée dans le mois considéré.
--
-- POINT DE MÉTHODE — le dénominateur ne doit jamais bouger.
-- Le taux de rétention se calcule sur l'effectif INITIAL de la cohorte, pas
-- sur les actifs du mois précédent. Diviser par les actifs du mois précédent
-- donnerait un taux de survie mois à mois, qui remonte dès qu'un utilisateur
-- revient — et masque l'attrition cumulée.
--
-- POINT DE MÉTHODE — les mois non observés ne valent pas 0 %.
-- Une cohorte ouverte en novembre 2024 ne peut pas avoir de M+6 si les
-- données s'arrêtent en décembre. Produire une ligne à 0 % écraserait les
-- moyennes par colonne : on borne donc chaque cohorte à sa profondeur
-- réellement observable, et on expose nb_mois_observables pour que le
-- consommateur sache ce qu'il peut comparer.
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['cohort_mois'],
        tags=['marts', 'analytics', 'retention']
    )
}}

with transactions as (

    select
        compte_id,
        tenant_id,
        date_trunc('month', date_transaction)::date as mois_activite
    from {{ ref('fct_transactions') }}
    where statut = 'validee'

),

-- Bornes réelles de l'activité observée : tout est déduit des données,
-- aucune date codée en dur.
bornes as (

    select
        min(mois_activite) as premier_mois,
        max(mois_activite) as dernier_mois
    from transactions

),

comptes as (

    select
        c.compte_id,
        c.tenant_id,
        date_trunc('month', c.date_ouverture)::date as cohort_mois
    from {{ ref('dim_comptes') }} c
    -- Les comptes ouverts hors période d'observation ne forment pas une
    -- cohorte exploitable : leur premier mois n'est pas mesurable.
    inner join bornes b
        on date_trunc('month', c.date_ouverture)::date
           between b.premier_mois and b.dernier_mois

),

-- Effectif initial, dénominateur fixe de toute la cohorte
taille_cohorte as (

    select
        cohort_mois,
        count(*) as nb_utilisateurs_cohorte
    from comptes
    group by cohort_mois

),

-- Activité mensuelle distincte par compte
activite as (

    select distinct
        c.compte_id,
        c.cohort_mois,
        t.mois_activite,
        datediff('month', c.cohort_mois, t.mois_activite) as mois_offset
    from comptes c
    inner join transactions t
        on c.compte_id = t.compte_id
    -- Une activité antérieure à l'ouverture du compte n'a pas de sens :
    -- on écarte les offsets négatifs plutôt que de les laisser polluer M+0.
    where t.mois_activite >= c.cohort_mois

),

-- Grille complète cohorte x offset, bornée à ce qui est observable
grille as (

    select
        tc.cohort_mois,
        tc.nb_utilisateurs_cohorte,
        offsets.mois_offset,
        datediff('month', tc.cohort_mois, b.dernier_mois) as nb_mois_observables
    from taille_cohorte tc
    cross join bornes b
    cross join (
        select seq4() as mois_offset
        from table(generator(rowcount => 13))   -- M+0 à M+12
    ) offsets
    where offsets.mois_offset <= datediff('month', tc.cohort_mois, b.dernier_mois)

),

retention as (

    select
        g.cohort_mois,
        g.mois_offset,
        g.nb_utilisateurs_cohorte,
        g.nb_mois_observables,
        count(distinct a.compte_id) as nb_utilisateurs_actifs
    from grille g
    left join activite a
        on g.cohort_mois  = a.cohort_mois
       and g.mois_offset  = a.mois_offset
    group by 1, 2, 3, 4

)

select
    cohort_mois,
    mois_offset,
    dateadd('month', mois_offset, cohort_mois)::date as mois_calendaire,

    nb_utilisateurs_cohorte,
    nb_utilisateurs_actifs,

    round(100.0 * nb_utilisateurs_actifs / nullif(nb_utilisateurs_cohorte, 0), 2)
        as taux_retention_pct,

    -- Profondeur réellement observable pour cette cohorte : permet au
    -- consommateur de ne comparer que des colonnes comparables.
    nb_mois_observables,
    (mois_offset = 0) as is_mois_acquisition

from retention
