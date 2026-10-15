-- ============================================================
-- FCT TRANSACTIONS v2 — version en préversion (US 6.2)
-- ============================================================
-- Ajoute `montant_hors_taxes` au schéma public de fct_transactions.
--
-- POURQUOI UNE VUE SUR v1 PLUTÔT QU'UNE COPIE DU SQL.
-- La documentation dbt recommande, quand une version ne fait qu'ajouter ou
-- retirer des colonnes, de la définir comme une projection de l'autre. Deux
-- bénéfices : la logique métier n'existe qu'à un seul endroit — une
-- correction sur v1 se propage —, et le coût de stockage reste celui d'une
-- seule table matérialisée. Dupliquer 940 000 lignes pour une colonne
-- calculée serait un gaspillage, et surtout une promesse de divergence entre
-- les deux versions.
--
-- CETTE VERSION N'EST PAS "latest".
-- `latest_version: 1` dans _core.yml : ref('fct_transactions') continue de
-- résoudre vers v1. v2 est une préversion, que les consommateurs peuvent
-- tester en épinglant ref('fct_transactions', v=2) avant la bascule.
--
-- NOTE MÉTIER — le calcul de la TVA est une convention de démonstration.
-- Un taux unique de 20 % est appliqué aux achats chez un marchand. Un
-- référentiel réel ferait varier le taux par pays et par catégorie de bien
-- (taux réduits sur l'alimentaire, les livres, les transports). La colonne
-- est nulle hors achat marchand : un virement ou un salaire n'ont pas de TVA.
-- ============================================================

{{
    config(
        materialized='view',
        tags=['marts', 'core', 'fct', 'versioned']
    )
}}

{% set taux_tva_standard = 1.20 %}

select
    *,

    -- Cast explicite : le contrat compare le type produit au type declare.
    -- Sans lui, la division puis l'arrondi produisent une precision decidee
    -- par Snowflake, qui ne correspondrait pas forcement a number(30,2).
    cast(
        case
            when type_operation = 'debit' and marchand_nom is not null
                then round(montant_eur / {{ taux_tva_standard }}, 2)
        end as number(30, 2)
    ) as montant_hors_taxes

from {{ ref('fct_transactions', v=1) }}
