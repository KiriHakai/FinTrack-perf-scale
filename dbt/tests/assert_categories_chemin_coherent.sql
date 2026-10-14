-- ============================================================
-- Invariant de la hiérarchie : profondeur du chemin == niveau calculé
-- ============================================================
-- Le chemin_complet est construit par concaténation à chaque itération de la
-- récursion : il doit donc comporter exactement `niveau` segments séparés
-- par ' > '. Un écart signalerait une récursion ayant perdu ou dupliqué un
-- niveau — le genre de bug qu'un test de non-nullité ne verrait jamais.
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    categorie_id,
    niveau,
    chemin_complet,
    array_size(split(chemin_complet, ' > ')) as nb_segments_chemin
from {{ ref('dim_categories') }}
where array_size(split(chemin_complet, ' > ')) <> niveau
