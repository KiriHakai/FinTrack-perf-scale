-- ============================================================
-- US 4.1 — Continuité temporelle des versions d'un compte
-- ============================================================
-- Deux défauts possibles sur une table SCD2, invisibles sans ce contrôle :
--
--   CHEVAUCHEMENT : la version N se termine après le début de la version N+1.
--                   Une requête « état au 15/06 » ramènerait deux lignes.
--   TROU          : la version N se termine avant le début de la N+1.
--                   La même requête ne ramènerait rien, le compte paraissant
--                   inexistant à cette date.
--
-- Les versions consécutives doivent se toucher exactement :
--   date_fin_validite(N) = date_debut_validite(N+1)
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

with enchainement as (

    select
        compte_id,
        version_number,
        date_debut_validite,
        date_fin_validite,
        lead(date_debut_validite) over (
            partition by compte_id
            order by version_number
        ) as debut_version_suivante
    from {{ ref('dim_comptes_scd2') }}

)

select
    compte_id,
    version_number,
    date_debut_validite,
    date_fin_validite,
    debut_version_suivante,
    case
        when date_fin_validite > debut_version_suivante then 'chevauchement'
        when date_fin_validite < debut_version_suivante then 'trou'
    end as anomalie
from enchainement
where debut_version_suivante is not null
  and date_fin_validite <> debut_version_suivante
