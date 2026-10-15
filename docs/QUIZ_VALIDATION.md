# Questionnaire de validation des acquis

25 questions pour vérifier la maîtrise du projet, des décisions techniques et
des résultats. Réponses détaillées, avec le raisonnement attendu.

**Conseil d'usage :** répondre à voix haute avant de lire la réponse. En
soutenance, la question ne sera pas « qu'avez-vous fait » mais « pourquoi ».

---

## Partie 1 — Architecture et modélisation (Q1 à Q6)

### Q1. Pourquoi Kimball plutôt que Data Vault ?

Le besoin est analytique et les consommateurs sont des outils BI, qui attendent
des faits et des dimensions directement interrogeables. Data Vault excelle pour
l'historisation fine et l'intégration de sources hétérogènes, mais impose une
couche de présentation supplémentaire — donc des modèles en plus sur un pipeline
qu'on doit justement accélérer.

L'historisation réglementaire est couverte autrement : par les snapshots dbt et
`dim_comptes_scd2`, sans adopter le paradigme complet.

### Q2. Quel est le grain de `fct_virements`, et pourquoi ce choix ?

Une ligne = une **leg** de virement. Chaque virement exécuté produit exactement
deux lignes : une sortante portée par le compte source avec un montant négatif,
une entrante portée par le compte destinataire.

Ce grain permet d'agréger les mouvements par compte sans se préoccuper du sens :
un `SUM(montant_signe)` groupé par compte donne directement le flux net. La clé
unique est composite — `(virement_id, virement_leg)` — car `virement_id` seul est
partagé par les deux lignes.

Les frais sont imputés à la seule leg sortante : l'émetteur les supporte, et les
porter sur les deux legs les compterait deux fois.

### Q3. Qu'est-ce qu'une « ligne fantôme » dans `fct_transactions` ?

Le fait filtre `statut in ('validee', 'en_attente')`. Combiné à une stratégie
merge, ce filtre produit des lignes obsolètes :

1. une transaction `en_attente` est insérée ;
2. la source la passe à `rejetee` ;
3. elle sort du périmètre du SELECT, donc du jeu source du MERGE ;
4. le MERGE ne met à jour que ce qu'il reçoit et **ne supprime jamais** : la
   ligne reste avec son ancien statut.

**Aucun test dbt ne peut le détecter** : la ligne est cohérente avec elle-même,
seule une confrontation à la source révélerait l'écart. Conséquence mesurable :
`nb_transactions_rejetees` renvoie structurellement 0.

Deux correctifs possibles : élargir le grain à tous les statuts avec des
drapeaux dérivés, ou ajouter un post-hook supprimant les lignes sorties du
périmètre. La limite a été documentée, pas corrigée.

### Q4. À quoi sert la bridge comptes ↔ titulaires, et quel invariant porte-t-elle ?

Elle gère la relation many-to-many entre comptes et personnes physiques : un
compte joint a plusieurs titulaires, un titulaire peut détenir plusieurs comptes.
Elle porte un `allocation_factor` permettant de ventiler les montants d'un compte
entre ses détenteurs.

**Invariant :** la somme des `allocation_factor` d'un compte, à une date donnée,
vaut 1. Vérifié par un test singulier, et contrôlé une seconde fois dès le
chargement dans le RAW.

Le contrôle porte sur les rattachements **en cours** : un compte ayant connu
plusieurs compositions successives aurait, toutes périodes confondues, une somme
supérieure à 1 sans que ce soit une anomalie.

### Q5. Pourquoi la CTE récursive de `dim_categories` utilise-t-elle une anti-jointure plutôt qu'un `NOT IN` ?

Deux raisons cumulées :

- **Snowflake rejette les sous-requêtes dans l'ancre d'une CTE récursive**
  (`Unsupported subquery type cannot be evaluated`) ;
- un `NOT IN` sur une colonne nullable renvoie faux pour **toutes** les lignes
  dès qu'un seul NULL est présent — un piège SQL classique.

L'ancre traite aussi les orphelins : une catégorie active dont le parent est
inactif n'a aucun parent à joindre. Sans traitement explicite, elle
disparaîtrait silencieusement — ni dans l'ancre, ni dans la descendance.

### Q6. Pourquoi la profondeur de récursion est-elle bornée à 10 ?

Snowflake **ne limite pas** le nombre d'itérations d'une CTE récursive : une
référence cyclique (A → B → A) tournerait jusqu'au `STATEMENT_TIMEOUT_IN_SECONDS`
ou jusqu'à annulation manuelle. La borne est un garde-fou, très au-delà de ce
qu'un plan de comptes réel utilise.

---

## Partie 2 — Stratégie incrémentale (Q7 à Q12)

### Q7. Le modèle était configuré correctement. Pourquoi retraitait-il un million de lignes ?

La configuration dbt était juste : `incremental_strategy = merge`,
`unique_key = transaction_id`, fenêtre de 7 jours. **Le problème était dans les
données.**

La colonne `_loaded_at` servant de borne était alimentée par
`CURRENT_TIMESTAMP()` au moment du COPY : toutes les lignes d'un chargement
portaient la même valeur. La condition
`_loaded_at >= max(_loaded_at) - 7 jours` sélectionnait donc l'intégralité de la
table.

Le pipeline payait le coût d'un full refresh **plus** celui du MERGE par-dessus.
Preuve : `ROWS_INSERTED = 0` alors que 950 000 lignes étaient mises à jour avec
des valeurs identiques.

### Q8. Pourquoi la fenêtre est-elle relative à `max(_loaded_at)` et non à `CURRENT_DATE()` ?

Pour supporter une interruption du pipeline. Si celui-ci ne tourne pas pendant
trois jours, une fenêtre calculée depuis la date du jour laisserait un trou de
trois jours non traités. Une fenêtre relative au dernier chargement connu repart
de là où le pipeline s'est arrêté, sans rattrapage manuel.

### Q9. Qu'est-ce que `merge_update_columns`, et pourquoi en restreindre la liste ?

C'est une **liste blanche** des colonnes modifiables par le MERGE. Tout ce qui
n'y figure pas est figé à l'insertion.

C'est délibéré : le montant, la devise ou la date d'une transaction ne changent
jamais après coup. Les y inclure ferait réécrire des micro-partitions sans
raison. Ne sont listées que les colonnes qu'un core banking met réellement à
jour : cycle de vie du statut, rapprochement, revue AML et fraude, compteur de
tentatives, motif de rejet.

### Q10. Comment avez-vous validé que le merge traite correctement un changement de statut ?

Le jeu de données étant chargé en une fois, aucun delta n'existait. J'ai
fabriqué un second lot d'ingestion couvrant trois cas :

| Cas | Attendu |
|-----|---------|
| 20 transactions `en_attente` → `validee`, `_loaded_at` rafraîchi | mises à jour sur place, sans doublon |
| 10 nouvelles transactions | ajoutées au fait |
| 1 transaction modifiée **sans** rafraîchir `_loaded_at` | **non reprise** — limite assumée |

Contrôles : statut effectivement mis à jour, aucune occurrence multiple d'un
`transaction_id`, nouvelles lignes présentes, et volumétrie traitée par la
fenêtre.

### Q11. Pourquoi microbatch a-t-il été écarté ? Donnez l'argument chiffré et l'argument structurel.

**Chiffré :** 33 min 22 contre 23,3 s sur une reconstruction complète — 1 383
instructions contre une seule, pour un volume identique. En régime quotidien :
21,7 s contre 13,9 s.

**Structurel, et décisif :** microbatch découpe sur `event_time`, c'est-à-dire la
date de la transaction. Or les mises à jour arrivent longtemps après l'événement
— validation sous quelques jours, rapprochement sous quelques semaines, revue AML
sans délai garanti. Une transaction de mars rapprochée en décembre n'est reprise
que si le batch de mars est rejoué, et `lookback = 3` ne remonte que trois jours.

Microbatch est conçu pour des faits **append-only**. `fct_transactions` est son
exact opposé.

### Q12. Pourquoi 1 383 batches alors que les données couvrent 731 jours ?

Un `--full-refresh` microbatch couvre la période allant de `begin` **jusqu'à la
date du jour**, pas jusqu'à la fin des données. Avec `begin` au 01/01/2023 et une
exécution en octobre 2026, cela fait 1 383 journées — dont environ 650
totalement vides, les données s'arrêtant fin 2024.

À 1,45 s par batch, ces journées sans aucune ligne ont consommé près de 16
minutes. **`begin` est un paramètre de coût direct**, pas une simple borne de
sécurité.

---

## Partie 3 — Performance Snowflake (Q13 à Q18)

### Q13. Quelle est la répartition du temps d'une exécution complète ?

| Catégorie | Nœuds | Cumul | Part |
|-----------|-------|-------|------|
| Modèles | 18 | 246 s | 16 % |
| **Tests de données** | **105** | **1 104 s** | **71 %** |
| Tests unitaires | 12 | 171 s | 11 % |
| Snapshot | 1 | 22 s | 1 % |

Temps réel écoulé : 449 s avec 4 threads, contre 1 543 s cumulées.

**Les tests coûtent 4,5 fois le temps des modèles.** Chaque test, même un
`not_null` sur 8 lignes, paie environ 10 secondes de coût fixe.

### Q14. Que montrent les Query Profiles sur la part de calcul réel ?

| Requête | Processing | Synchronization |
|---------|-----------|-----------------|
| Agrégat par tenant et mois | ~0 % | 50 % |
| Lookup par identifiant externe | **1,4 %** | **68 %** |
| Jointure et agrégat sur 634 k lignes | ~0 % | 62 % |

Le calcul ne dépasse jamais 1,4 %. Entre la moitié et les deux tiers partent en
synchronisation — coordination entre le nœud de calcul et le service cloud,
c'est-à-dire de l'attente.

**Conséquence :** à ce volume, optimiser le SQL ne rapporte rien. Les leviers
sont la réduction du nombre de requêtes et le parallélisme.

### Q15. La profondeur de clustering vaut 3,71, au-dessus de la cible de 3. Est-ce un échec ?

Non, et la métrique est trompeuse ici.

La clé `(tenant_id, date_trunc('month', date_transaction))` définit 8 tenants ×
24 mois, soit jusqu'à **192 combinaisons distinctes**, réparties sur
**17 micro-partitions**. Ranger 192 groupes dans 17 partitions sans chevauchement
est arithmétiquement impossible — d'où `average_overlaps = 4`.

**Et pourtant le pruning fonctionne :** la requête d'agrégat par tenant et mois
scanne 2 partitions sur 17, soit 88 % d'élagage. `average_depth` mesure la
qualité théorique du tri, pas l'efficacité de l'élagage sur le motif de requête
réellement exécuté.

Snowflake recommande le clustering pour des tables de l'ordre du téraoctet ; ici
la table pèse 86 Mo.

### Q16. Search Optimization a-t-elle apporté un gain ? Pourquoi ?

Aucun gain mesurable : 9 partitions scannées sur 17 avant comme après.

C'était prévisible à la lecture du profil. Les 20 Mo scannés représentent 27,5 %
d'une requête de 1,1 s, soit environ 0,3 s. **Même en supprimant intégralement le
scan, le gain plafonne à 0,3 seconde** — les 68 % de synchronisation étant
incompressibles.

Les estimations de coût sont par ailleurs inexploitables à ce volume :
l'estimation sur deux colonnes ressortait **inférieure** à celle sur une seule,
ce qui est arithmétiquement impossible — le bruit d'échantillonnage dépasse le
signal. Et le poste déterminant, la maintenance, n'est pas calculable avant
7 jours d'historique.

### Q17. Quel était le vrai problème du lookup, et quelle solution avez-vous retenue ?

**Le `SELECT *`.** La requête scannait 20,22 Mo pour ramener **une seule ligne**,
là où l'agrégat par tenant en scannait 1,41 Mo pour en ramener 5 715.

L'écart ne vient pas des partitions mais des **colonnes** : l'agrégat en lit 5,
le lookup en lit 43. En stockage colonnaire, c'est déterminant.

Solution retenue : proscrire `SELECT *` sur les lookups applicatifs. Gain du même
ordre que Search Optimization, **à coût nul et sans service facturé**.

### Q18. Pourquoi avoir supprimé le clustering des tables RAW ?

Trois raisons :

1. Une clé contenant une expression (`DATE_TRUNC`) est **rejetée par COPY INTO** :
   la requête échoue à la compilation, avant lecture de la moindre ligne.
2. Aucune requête n'interroge le RAW par tenant et par mois — les modèles staging
   le lisent intégralement et filtrent sur `_loaded_at`.
3. Le reclustering automatique aurait consommé des crédits en continu sans
   bénéfice de pruning mesurable.

Le clustering est conservé là où il sert : sur `fct_transactions`.

---

## Partie 4 — Qualité, gouvernance, observabilité (Q19 à Q25)

### Q19. Décrivez le bug de conversion de devise et expliquez pourquoi il a survécu.

Le référentiel `int_fx_rates_daily` cote **EUR → devise** : le taux est le nombre
d'unités de la devise pour 1 EUR (1 EUR = 7,45 DKK). La conversion vers l'euro
doit donc **diviser**. Le modèle multipliait : une transaction de 7,51 DKK
ressortait à 57,25 EUR au lieu de 1,01 — **57 fois trop**.

Trois raisons à sa survie :

- **invisible sur l'euro**, où le taux vaut 1, soit 55 % des transactions ;
- **non couvert par les tests** : `accepted_range` acceptait de 0 à 100 millions ;
- **contredit par une autre colonne de la même ligne** — `montant_signe_eur`,
  repris du staging, était juste — sans qu'aucun test ne compare les deux.

### Q20. Pourquoi l'échantillon du test FX est-il stratifié par devise ?

Parce qu'un tirage aléatoire de 100 transactions en contiendrait environ 55 en
euros, où l'erreur est **invisible** par construction. Le test prend 20
transactions pour chacune des 10 devises, ce qui garantit de couvrir les cas où
le taux diffère de 1.

C'est exactement ce qui avait permis au bug de passer inaperçu.

### Q21. Qu'est-ce qu'un contrat dbt protège — et que ne protège-t-il pas ?

**Il protège la structure :** noms de colonnes, types, nombre. Avec
`contract.enforced: true`, dbt compare le schéma produit à sa déclaration YAML
**avant** d'écrire en base. Démonstration faite en renommant volontairement
`montant_eur` : le build échoue à la compilation, la table reste intacte, et les
modèles aval passent en SKIP.

**Il ne protège pas la sémantique.** La correction FX a divisé des montants par
174 sans changer ni nom ni type : aucun contrat ne l'aurait détectée. Pourtant
l'impact sur un dashboard financier est bien plus violent qu'un renommage — qui,
lui, aurait au moins produit une erreur visible.

**Conclusion :** contrats et tests sont complémentaires. Le contrat protège la
forme, les tests protègent le fond.

### Q22. Pourquoi avoir mis `alias: fct_transactions` sur la version 1 ?

Par défaut, dbt matérialise chaque version sous l'alias `<modèle>_v<n>`. Activer
le versioning sur un modèle existant **renommerait donc sa table** en
`FCT_TRANSACTIONS_V1`, et tous les outils pointant sur
`MARTS_CORE.FCT_TRANSACTIONS` cesseraient de la trouver.

C'est l'inverse de l'effet recherché : on introduit le versioning pour *éviter*
de casser les consommateurs, et son activation les casserait tous d'un coup.
L'alias conserve l'emplacement physique historique.

### Q23. Pourquoi `date_fin_validite` vaut-elle 9999-12-31 et non NULL dans le SCD2 ?

Avec un NULL, chaque consommateur doit écrire
`(date_fin_validite is null or date_fin_validite > ...)`. **La première omission
produit une requête qui ne renvoie rien — sans erreur.** Une borne
conventionnelle rend le filtre naturel et uniforme.

La borne haute est par ailleurs **exclue** : deux versions consécutives se
touchent exactement (`fin(N) = début(N+1)`), de sorte qu'un `BETWEEN` sur bornes
incluses ne ramène jamais deux lignes au jour de bascule.

### Q24. Quelle limite majeure de l'historisation SCD2 avez-vous identifiée ?

**Elle est prospective.** Un snapshot n'enregistre que les changements survenus
**après sa mise en service** : il ne reconstitue jamais le passé.

Démonstration : la requête de reconstitution d'un état au 15/06/2024 renvoie zéro
ligne, toutes les versions débutant à la date du premier `dbt snapshot`.

Conséquences pour une exigence de piste d'audit réglementaire :

- une demande du type « quel était le niveau KYC de ce compte en juin 2024 »
  reste sans réponse ;
- la profondeur d'historique est bornée par la date de démarrage du snapshot,
  pas par l'ancienneté des comptes.

**Recommandation :** mettre le snapshot en production avant tout besoin d'audit.
Cela ne se rattrape pas.

### Q25. Quels modes de défaillance avez-vous rencontrés avec l'outil d'observabilité ?

Trois configurations successives, trois façons distinctes de se tromper :

| Configuration | Résultat | Nature |
|---------------|----------|--------|
| Détection 730 j, entraînement 1095 | **79 anomalies** | Faux rouge : avec `seasonality: day_of_week`, le compteur s'exprime en buckets du même jour de semaine — 1095 mardis, soit 21 ans d'historique remontant à 2005, dont ~900 buckets vides comptés à zéro |
| Détection 100 j, entraînement 26 | **0 anomalie** | Faux vert : la fenêtre de détection couvrait une période sans données, le test n'a rien analysé |
| Détection 730 j, entraînement 26 | 0 anomalie | Cadrage correct, mais le pic injecté n'a pas été signalé — cause non élucidée |

**Le faux vert est le plus dangereux :** un test qui alerte 79 fois finit par
être examiné, un test qui passe silencieusement sans rien analyser ne sera jamais
remis en question. Et **le temps d'exécution ne révèle rien** — 13 secondes pour
ne rien faire, 243 pour se tromper.

**Règle retenue :** vérifier non pas le statut d'un contrôle, mais ce qu'il a
effectivement examiné — nombre de buckets analysés, plage couverte, taille de
l'échantillon d'entraînement.

---

## Les six chiffres à connaître par cœur

| Chiffre | Signification |
|---------|---------------|
| **1 000 000 → 30** | Lignes traitées par la fenêtre incrémentale, avant et après correction |
| **1,4 %** | Part maximale du temps consacrée au calcul réel |
| **4,5×** | Rapport entre le coût des 105 tests et celui des 18 modèles |
| **23 s contre 33 min** | Merge contre microbatch, reconstruction complète |
| **88 %** | Pruning obtenu malgré une métrique de clustering « mauvaise » |
| **7 min 29** | Pipeline complet au scale M, pour un objectif d'une heure |
