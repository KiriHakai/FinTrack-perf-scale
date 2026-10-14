-- ============================================================
-- Invariant de la double-écriture : exactement 2 legs par virement
-- ============================================================
-- Un virement exécuté doit produire une leg sortante ET une leg entrante.
-- Toute autre cardinalité (1 seule leg, ou 3 et plus après un merge mal
-- configuré) signale une rupture de la logique comptable.
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    virement_id,
    count(*) as nb_legs
from {{ ref('fct_virements') }}
group by virement_id
having count(*) <> 2
