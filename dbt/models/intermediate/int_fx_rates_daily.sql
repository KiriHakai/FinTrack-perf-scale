-- ============================================================
-- INT — Taux FX quotidiens densifiés (forward-fill des week-ends)
-- ============================================================
-- Les marchés FX ne cotent ni le week-end ni les jours fériés : on reporte le
-- dernier taux connu (last observation carried forward), sans quoi toute
-- transaction du samedi serait convertie au taux de repli.
--
-- CONVENTION DE COTATION — déterminante pour l'aval :
--   taux = nombre d'unités de la devise pour 1 EUR  (1 EUR = 7,45 DKK)
--   donc  montant_eur = montant / taux   ← on DIVISE
-- L'inversion de ce sens est le bug corrigé en US 4.2 : une transaction de
-- 7,51 DKK ressortait à 57,25 EUR au lieu de 1,01.
--
-- Le calendrier est désormais déduit des bornes réelles du référentiel plutôt
-- que codé en dur : des dates figées créaient un risque de trou silencieux dès
-- que les données débordaient la fenêtre prévue — et une transaction sans taux
-- tombe sur le repli, sans que rien ne le signale.
-- ============================================================

{{
    config(
        materialized='table',
        tags=['intermediate', 'fx']
    )
}}

with source as (

    select * from {{ ref('stg_fx_rates') }}

),

bornes as (

    select
        min(date_cotation) as date_min,
        max(date_cotation) as date_max
    from source

),

-- Calendrier continu entre les deux bornes du référentiel.
-- rowcount surdimensionné (10 ans) : le WHERE coupe au bon endroit.
date_spine as (

    select dateadd('day', g.seq, b.date_min)::date as date_day
    from bornes b
    cross join (
        select seq4() as seq from table(generator(rowcount => 3700))
    ) g
    where dateadd('day', g.seq, b.date_min) <= b.date_max

),

devises as (

    select distinct devise_cible from source

),

grille_complete as (

    select
        ds.date_day as date_cotation,
        d.devise_cible
    from date_spine ds
    cross join devises d

),

joint as (

    select
        gc.date_cotation,
        gc.devise_cible,
        s.taux,
        -- Forward-fill : dernier taux non nul connu pour cette devise
        last_value(s.taux ignore nulls) over (
            partition by gc.devise_cible
            order by gc.date_cotation
            rows between unbounded preceding and current row
        ) as taux_ffill,
        (s.taux is null) as is_taux_reporte
    from grille_complete gc
    left join source s
        on gc.date_cotation = s.date_cotation
       and gc.devise_cible  = s.devise_cible

)

select
    date_cotation,
    'EUR'       as devise_source,
    devise_cible,
    taux_ffill  as taux,
    is_taux_reporte
from joint
where taux_ffill is not null

union all

-- L'euro contre lui-même vaut toujours 1. Sans cette branche, toute
-- transaction en EUR tomberait sur le repli faute de ligne dans le référentiel.
select
    date_day    as date_cotation,
    'EUR'       as devise_source,
    'EUR'       as devise_cible,
    1.0         as taux,
    false       as is_taux_reporte
from date_spine
