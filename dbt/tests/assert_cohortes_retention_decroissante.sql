-- ============================================================
-- Cohérence des cohortes : les actifs ne dépassent jamais l'effectif
-- ============================================================
-- Le nombre d'utilisateurs actifs d'une cohorte un mois donné ne peut pas
-- excéder son effectif initial — ce serait le signe d'un compte compté deux
-- fois, typiquement une jointure dupliquant des lignes, ou d'un compte
-- rattaché à la mauvaise cohorte.
--
-- Un taux supérieur à 100 % passerait inaperçu dans un graphique de
-- rétention : l'œil y verrait une « remontée » plausible.
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    cohort_mois,
    mois_offset,
    nb_utilisateurs_cohorte,
    nb_utilisateurs_actifs,
    taux_retention_pct
from {{ ref('mart_cohortes_retention') }}
where nb_utilisateurs_actifs > nb_utilisateurs_cohorte
