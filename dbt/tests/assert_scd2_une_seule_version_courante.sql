-- ============================================================
-- US 4.1 — Contrainte : un compte_id a EXACTEMENT une version courante
-- ============================================================
-- Deux versions courantes signifieraient qu'un même compte a deux états
-- présents simultanés : toute jointure sur l'état courant dupliquerait ses
-- lignes, et les agrégats seraient faussés sans aucun message d'erreur.
--
-- Zéro version courante est tout aussi grave : le compte existe mais devient
-- invisible à toute requête filtrant sur is_current.
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    compte_id,
    count_if(is_current) as nb_versions_courantes,
    count(*)             as nb_versions_totales
from {{ ref('dim_comptes_scd2') }}
group by compte_id
having count_if(is_current) <> 1
