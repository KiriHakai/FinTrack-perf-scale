-- ============================================================
-- Cohérence entre z_score, is_anomalie et severite
-- ============================================================
-- Trois colonnes décrivent le même jugement ; elles doivent s'accorder.
-- Une incohérence entre elles produirait des tableaux de bord contradictoires
-- selon la colonne utilisée pour filtrer — le genre d'écart qu'on découvre en
-- réunion, quand deux analystes annoncent deux chiffres différents.
--
-- Règles vérifiées :
--   - is_anomalie vrai  => severite dans (low, medium, high)
--   - is_anomalie faux  => severite dans (normal, historique_insuffisant)
--   - z_score null      => severite = historique_insuffisant
--   - z_score renseigné => severite <> historique_insuffisant
--
-- Le test échoue si la requête renvoie au moins une ligne.
-- ============================================================

select
    transaction_id,
    z_score,
    is_anomalie,
    severite,
    case
        when is_anomalie and severite not in ('low', 'medium', 'high')
            then 'anomalie sans severite correspondante'
        when not is_anomalie and severite in ('low', 'medium', 'high')
            then 'severite elevee sans drapeau anomalie'
        when z_score is null and severite <> 'historique_insuffisant'
            then 'z_score absent mais severite calculee'
        when z_score is not null and severite = 'historique_insuffisant'
            then 'z_score present mais historique declare insuffisant'
    end as incoherence
from {{ ref('mart_transactions_anomalies') }}
where (is_anomalie and severite not in ('low', 'medium', 'high'))
   or (not is_anomalie and severite in ('low', 'medium', 'high'))
   or (z_score is null and severite <> 'historique_insuffisant')
   or (z_score is not null and severite = 'historique_insuffisant')
