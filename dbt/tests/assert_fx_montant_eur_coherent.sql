-- ============================================================
-- US 4.2 — Le montant_eur doit être recalculable au taux du jour
-- ============================================================
-- Critère du briefing : « recalculer montant_eur d'un échantillon de
-- 100 transactions et vérifier < 0,01 % d'écart ».
--
-- Le test recalcule indépendamment la conversion depuis le référentiel FX et
-- la confronte à la valeur stockée dans le fait. Il échoue si une seule ligne
-- de l'échantillon s'écarte de plus de 0,01 %.
--
-- L'échantillon est volontairement multi-devises : une erreur de sens de
-- conversion est invisible sur l'euro (taux = 1) et spectaculaire sur le yen
-- (taux ≈ 160). C'est précisément ce qui avait permis au bug de survivre.
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

with echantillon as (

    select
        f.transaction_id,
        f.devise,
        f.montant,
        f.montant_eur,
        f.jour_transaction
    from {{ ref('fct_transactions') }} f
    -- 20 transactions par devise : couvre les 10 devises du référentiel
    qualify row_number() over (partition by f.devise order by f.transaction_id) <= 20

),

recalcul as (

    select
        e.transaction_id,
        e.devise,
        e.montant,
        e.montant_eur                                    as montant_eur_stocke,
        fx.taux,
        round(e.montant / nullif(fx.taux, 0), 2)         as montant_eur_recalcule
    from echantillon e
    inner join {{ ref('int_fx_rates_daily') }} fx
        on e.jour_transaction = fx.date_cotation
       and e.devise           = fx.devise_cible

)

select
    transaction_id,
    devise,
    montant,
    taux,
    montant_eur_stocke,
    montant_eur_recalcule,
    abs(montant_eur_stocke - montant_eur_recalcule)                       as ecart_absolu,
    abs(montant_eur_stocke - montant_eur_recalcule)
        * 100.0 / nullif(montant_eur_recalcule, 0)                        as ecart_pct
from recalcul
-- Tolérance de 0,01 %, plus un plancher d'un centime pour absorber les
-- arrondis sur les très petits montants (où 0,01 % est inférieur au centime).
where abs(montant_eur_stocke - montant_eur_recalcule) > 0.01
  and abs(montant_eur_stocke - montant_eur_recalcule)
        * 100.0 / nullif(montant_eur_recalcule, 0) > 0.01
