-- ============================================================
-- Invariant de la bridge : somme des clés de répartition = 1 par compte
-- ============================================================
-- Si la somme des allocation_factor d'un compte dépasse 1, les dépenses
-- ventilées par titulaire seraient surévaluées ; si elle est inférieure,
-- une part des montants ne serait attribuée à personne.
--
-- Le contrôle porte sur les rattachements EN COURS : un compte ayant connu
-- plusieurs compositions successives aurait, toutes périodes confondues,
-- une somme supérieure à 1 sans que ce soit une anomalie.
--
-- Tolérance de 0,001 pour les arrondis de NUMBER(5,4).
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    compte_id,
    count(*)                  as nb_titulaires,
    sum(allocation_factor)    as somme_allocation
from {{ ref('bridge_comptes_titulaires') }}
where is_rattachement_courant
group by compte_id
having abs(sum(allocation_factor) - 1) > 0.001
