-- ============================================================
-- DIM CATÉGORIES — hiérarchie résolue par CTE récursive
-- ============================================================
-- La table catégories est auto-référencée via categorie_parent_id.
-- Ce modèle aplatit l'arbre pour exposer, à chaque nœud :
--   - niveau          : profondeur réelle, calculée (1 = racine)
--   - chemin_complet  : "Loisirs > Restaurant > Fast-food"
--   - id_racine       : identifiant de l'ancêtre de plus haut niveau
--
-- Deux points d'attention sur l'ancre de récursion :
--
-- 1. Les orphelins. stg_categories ne retient que les catégories actives.
--    Une catégorie dont le parent est inactif (ou absent du référentiel)
--    n'aurait donc aucun parent à joindre : sans traitement, elle serait
--    purement perdue — ni dans l'ancre, ni dans la descendance. On la traite
--    donc comme une racine, et on la marque via is_orphelin.
--
-- 2. Les cycles. Un référentiel mal saisi peut contenir A → B → A.
--    Snowflake interromprait la récursion sur erreur après un grand nombre
--    d'itérations ; on borne explicitement la profondeur à 10 niveaux, très
--    au-delà de ce qu'un plan de comptes réel utilise.
--
-- ÉTAT DES DONNÉES : le générateur synthétique produit 30 catégories toutes
-- au niveau 1, sans aucun categorie_parent_id renseigné. La récursion est donc
-- fonctionnellement correcte mais ne descend sur aucun niveau avec le jeu de
-- données actuel. Voir docs/DESIGN.md.
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'dim']
    )
}}

-- Le mot-clé RECURSIVE est optionnel chez Snowflake (`WITH [ RECURSIVE ]`),
-- mais on l'explicite : c'est un signal de lecture pour la suite du fichier.
with recursive source as (

    select * from {{ ref('stg_categories') }}

),

arbre as (

    -- ---------- Ancre : racines et orphelins ----------
    select
        c.categorie_id,
        c.nom_categorie,
        c.type_categorie,
        c.groupe,
        c.categorie_parent_id,
        c.niveau_hierarchique,
        c.date_creation,

        1                       as niveau,
        c.nom_categorie         as chemin_complet,
        c.categorie_id          as id_racine,
        (c.categorie_parent_id is not null) as is_orphelin

    -- Anti-jointure plutôt que `NOT IN (select ...)` : Snowflake rejette les
    -- sous-requêtes dans l'ancre d'une CTE récursive
    -- ("Unsupported subquery type cannot be evaluated"). La forme jointe est
    -- par ailleurs plus sûre — un NOT IN sur colonne nullable renvoie faux
    -- pour toutes les lignes dès qu'un seul NULL est présent.
    from source c
    left join source parent_existant
        on c.categorie_parent_id = parent_existant.categorie_id
    where c.categorie_parent_id is null
       or parent_existant.categorie_id is null

    union all

    -- ---------- Récursion : descendance ----------
    select
        enfant.categorie_id,
        enfant.nom_categorie,
        enfant.type_categorie,
        enfant.groupe,
        enfant.categorie_parent_id,
        enfant.niveau_hierarchique,
        enfant.date_creation,

        parent.niveau + 1                                          as niveau,
        parent.chemin_complet || ' > ' || enfant.nom_categorie     as chemin_complet,
        parent.id_racine                                           as id_racine,
        false                                                      as is_orphelin

    from source enfant
    inner join arbre parent
        on enfant.categorie_parent_id = parent.categorie_id
    where parent.niveau < 10   -- garde-fou anti-cycle

)

select
    categorie_id,
    nom_categorie,
    type_categorie,
    groupe,
    categorie_parent_id,

    -- Hiérarchie résolue
    niveau,
    chemin_complet,
    id_racine,
    is_orphelin,

    -- Niveau déclaré en source, conservé pour contrôle : un écart avec
    -- `niveau` signale une incohérence du référentiel amont.
    niveau_hierarchique                        as niveau_declare_source,
    (niveau <> niveau_hierarchique)            as ecart_niveau_source,

    -- Commodités d'analyse
    (categorie_parent_id is null)              as is_racine,
    split_part(chemin_complet, ' > ', 1)       as libelle_racine,

    date_creation

from arbre
