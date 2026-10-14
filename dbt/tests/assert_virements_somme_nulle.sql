-- ============================================================
-- Invariant de la double-écriture : somme des montants signés nulle
-- ============================================================
-- Ce qui sort d'un compte entre intégralement sur l'autre : la somme des
-- montant_signe d'un même virement doit valoir 0 (hors frais, imputés à la
-- seule leg sortante).
--
-- Tolérance de 0,01 pour absorber les arrondis décimaux.
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    virement_id,
    sum(montant_signe) as somme_montants_signes
from {{ ref('fct_virements') }}
group by virement_id
having abs(sum(montant_signe)) > 0.01
