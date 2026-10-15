# Rapport final — FinTrack Perf & Scale

**Mission :** optimisation et industrialisation d'une plateforme analytique B2B2C
**Environnement :** Snowflake Enterprise (compte d'essai) — dbt Core 1.12.5 — dbt-snowflake 1.12.2
**Volume de travail :** scale M, 1 000 000 de transactions, 20 000 comptes, 8 tenants

---

## 1. Ce qui a été livré

| Sprint | Périmètre | État |
|--------|-----------|------|
| 1 | Provisioning Snowflake, génération et chargement | Terminé |
| 2 | Modélisation core, double-écriture, bridge titulaires | Terminé |
| 3 | Stratégie incrémentale, microbatch, clustering, Query Profiles | Terminé |
| 4 | Historisation SCD2, multi-devises | Terminé |
| 5 | CI/CD et orchestration | **Non réalisé** |
| 6 | Analytics avancés, contracts, observabilité | Terminé |

Le pipeline compte 23 modèles, 1 snapshot, 160 tests de données et 12 tests
unitaires. Il s'exécute intégralement en 7 min 29 au scale M.

**Préalable non prévu au briefing :** le projet livré ne s'exécutait pas. Dix
correctifs ont été nécessaires avant toute optimisation — dont deux expressions
Jinja neutralisées par un commentaire SQL (`--` n'est pas un commentaire Jinja :
l'expression s'exécute quand même), des macros portant des noms réservés par
l'adaptateur, et une erreur de sens dans la conversion de devises. Le détail
figure dans `PERF_LOG.md` § 2.

---

## 2. Quels gains de performance concrets ?

### Le gain principal : l'incrémental devient réellement incrémental

| Mesure | Avant | Après |
|--------|-------|-------|
| Lignes sélectionnées par la fenêtre incrémentale | **1 000 000** | **30** |
| Nature du traitement | full refresh + MERGE par-dessus | delta réel |

Le modèle était déclaré incrémental mais retraitait l'intégralité de la table à
chaque exécution. La cause n'était pas dans le SQL : `_loaded_at` était alimenté
par `CURRENT_TIMESTAMP()` au chargement, donc **identique pour toutes les
lignes**. La fenêtre glissante de 7 jours sélectionnait donc tout.

Le MERGE affichait `ROWS_INSERTED = 0` tout en mettant à jour 950 000 lignes
avec des valeurs inchangées — réécrivant des micro-partitions pour rien.

### Les autres gains mesurés

| Levier | Gain |
|--------|------|
| Prototype microbatch écarté | évite 33 min par build complet |
| Test de volumétrie limité à la v1 du modèle versionné | 243 s par exécution |
| Fenêtres d'anomalie recalibrées | 243 s → 14 s |
| `merge_update_columns` en liste blanche | limite les micro-partitions réécrites |
| Clustering retiré du RAW | supprime un reclustering sans bénéfice de pruning |

### Le constat qui domine tout le reste

Quatre mesures indépendantes convergent :

| Mesure | Part du temps consacrée au calcul |
|--------|-----------------------------------|
| Chaîne d'ingestion (génération, PUT, COPY) | COPY = **2 %** du total |
| Build complet (18 modèles, 105 tests) | modèles = **16 %**, tests = **71 %** |
| Requête BI d'agrégation (Q1) | Processing ≈ **0 %** |
| Lookup ponctuel (Q2) | Processing = **1,4 %**, Synchronization = 68,1 % |

**Au scale M, le calcul ne dépasse jamais 1,4 % du temps d'exécution.** Entre la
moitié et les deux tiers partent en synchronisation — de la coordination, pas du
travail. Les 105 tests coûtent 4,5 fois le temps des 18 modèles, parce que
chaque test, même un `not_null` sur 8 lignes, paie 10 secondes de coût fixe.

**Conséquence méthodologique :** à ce volume, optimiser le SQL ne rapporte rien.
Les gains viennent de la réduction du **nombre de requêtes** et du parallélisme
— on passe déjà de 1 543 s cumulées à 449 s réelles avec 4 threads.

### Honnêteté sur l'objectif du CTO

L'objectif « pipeline complet sous 1 h » est atteint — 7 min 29 — mais **sur 1 à
2 % du volume cible**. Et la structure du temps mesuré, dominée par la latence,
ne se transpose pas linéairement. Annoncer l'objectif atteint sur cette base
serait la faute méthodologique la plus facile à repérer.

---

## 3. Pourquoi merge plutôt que microbatch ?

### Les chiffres

| Scénario | Merge | Microbatch |
|----------|-------|------------|
| Build complet | **23,3 s** — 1 instruction | **33 min 22** — 1 383 instructions |
| Run quotidien | **13,9 s** | 21,7 s — 4 instructions |

Le découpage multiplie le coût fixe par requête, déjà identifié comme dominant,
pour un volume de données strictement identique.

**Piège découvert à l'exécution :** un build complet microbatch couvre la période
allant de `begin` **jusqu'à la date du jour**, pas jusqu'à la fin des données.
Sur un historique figé, 650 des 1 383 batches étaient vides — 16 minutes pour ne
rien produire. `begin` est un paramètre de coût direct.

### L'argument qui tranche n'est pas la performance

Microbatch découpe sur `event_time`, c'est-à-dire la **date de la transaction**.
Or les mises à jour de ce pipeline portent sur des transactions anciennes :
validation sous quelques jours, rapprochement bancaire sous quelques semaines,
revue AML sans délai garanti. Une transaction de mars rapprochée en décembre
n'est reprise que si le batch de mars est rejoué — et `lookback = 3` ne remonte
que trois jours.

**Microbatch est conçu pour des faits append-only.** `fct_transactions` est son
exact opposé : la mise à jour de ses lignes est l'objet même de l'US 3.1. Le
retenir reviendrait à **aller moins vite en faisant moins bien**.

### Quand il redeviendrait pertinent

À très grand volume, où une instruction unique risquerait le spill et où le coût
fixe par batch deviendrait négligeable ; pour un backfill ciblé, que
`--event-time-start/end` permet sans toucher au reste ; et sur un fait
réellement append-only. Le prototype est conservé dans le projet, désactivé par
défaut, pour que la comparaison soit rejouable au scale L.

---

## 4. Les trois principaux risques opérationnels

### Risque 1 — Le pipeline affirme être à jour alors qu'il ne l'est pas

Trois chemins distincts mènent au même résultat, **tous silencieux** :

- une donnée corrigée dans le RAW **sans rafraîchir `_loaded_at`** n'est jamais
  reprise par la fenêtre incrémentale ;
- relancer un seul modèle aval ne propage rien : la chaîne staging → fait doit
  être rejouée entière, faute de quoi la correction reste bloquée en amont ;
- une transaction qui passe à `rejetee` sort du périmètre du fait, n'est donc
  jamais reprise par le MERGE, et **conserve indéfiniment son ancien statut**.

Aucun de ces cas ne produit d'erreur. Le troisième a une conséquence mesurable :
`nb_transactions_rejetees` renvoie structurellement 0, et le taux de validation
affiché est surestimé.

**Parade :** un test de réconciliation périodique entre le fait et la source sur
la tranche récente, qui mesure la dérive sans attendre qu'un consommateur la
découvre.

### Risque 2 — Les contrôles qui rassurent sans rien vérifier

| Cas rencontré | Manifestation |
|---------------|---------------|
| Tests unitaires livrés | **Jamais exécutés** : dossier hors model-paths, et override `is_incremental` manquant |
| `accepted_range(0, 100 000 000)` sur `montant_eur` | Laissait passer un montant **57 fois trop élevé** |
| Test de volumétrie, 1ʳᵉ configuration | **79 fausses alertes** : entraînement remontant à 2005, sur des buckets vides |
| Test de volumétrie, 2ᵉ configuration | **Faux vert** : fenêtre de détection hors données, aucune ligne analysée |

Le faux vert est le plus dangereux : un test qui hurle finit par être examiné, un
test qui passe sans rien analyser ne sera jamais remis en question. **Et le temps
d'exécution ne révèle rien** — 13 secondes pour ne rien faire, 243 pour se
tromper.

**Parade :** vérifier non pas le statut d'un test mais **ce qu'il a effectivement
regardé** — nombre de buckets analysés, plage couverte, taille de l'échantillon.

### Risque 3 — Les coûts qui dérivent sans signal

| Incident | Coût |
|----------|------|
| `WH_INGESTION` en LARGE pour 20 s de COPY effectif | 0,83 crédit, soit 6 min de warehouse facturées |
| Un sélecteur dbt anodin entraînant le prototype microbatch | 33 min de warehouse, ≈ 0,55 crédit |
| Elementary ajouté à un run de tests | **+7 min** sur une exécution qui en prenait 1 |

Aucun de ces cas n'est une erreur de code : ce sont des effets de bord de
configurations plausibles. Le resource monitor, calibré à 100 crédits pour un
budget d'environ 60, n'aurait alerté qu'après épuisement.

**Parade :** un seuil de monitoring calé sur le budget réel, et des modèles de
démonstration désactivés par défaut.

---

## 5. Comment absorber 10× le volume ?

À 1 milliard de transactions par mois, **le profil mesuré ici s'inverse** : les
coûts fixes restent constants pendant que le volume de calcul est multiplié par
cent. Les conclusions du scale M doivent donc être revalidées, pas transposées.

### Ce qui tient

**La stratégie merge**, à condition d'ajouter des `incremental_predicates` pour
borner le scan de la table cible — à 1 Md de lignes, le MERGE ne peut plus
balayer l'ensemble.

**Le clustering**, qui devient enfin utile. Sa mesure actuelle (`average_depth`
3,71, au-dessus de la cible) est trompeuse : la clé définit 192 combinaisons pour
17 micro-partitions, soit une impossibilité arithmétique. À 1 Md de lignes et des
milliers de partitions, la clé `(tenant_id, mois)` prendra tout son sens — le
pruning mesuré atteint déjà 88 % sur le motif de filtrage dominant.

**Les contrats**, dont le coût est nul et la valeur croissante avec le nombre de
consommateurs.

### Ce qui doit changer

| Domaine | Décision |
|---------|----------|
| Ingestion | External stage (S3/Blob) au lieu du PUT client — aujourd'hui 41 % du temps d'ingestion, qui disparaîtrait |
| Fichiers | 100 à 250 Mo compressés par fichier, le COPY parallélisant par fichier |
| Tests | Réduire le **nombre** de requêtes : regrouper les assertions, hiérarchiser par sévérité, échantillonner les tests coûteux |
| Warehouses | Dimensionner sur le **spill** observé, absent aujourd'hui ; multi-cluster pour la concurrence BI |
| Microbatch | À réévaluer : il devient pertinent là où une instruction unique risque le spill |
| Search Optimization | À réévaluer sur `external_transaction_id`, après 7 jours d'historique permettant de chiffrer la maintenance |
| Partitionnement logique | Envisager une séparation par tenant pour les gros contrats, qui isole les SLA |

### La méthode plutôt que la recette

La leçon principale de cette mission est méthodologique : **chaque optimisation
supposée a été soit confirmée, soit infirmée par la mesure**, et plusieurs l'ont
été à contre-courant de l'intuition. Search Optimization n'apporte rien ici ; le
vrai problème du lookup était un `SELECT *` lisant 43 colonnes au lieu de 5. Le
clustering « échoue » sa métrique tout en élaguant 88 % des partitions.

Passer à 1 Md de lignes ne demande pas d'appliquer ces conclusions, mais de
**rejouer ce protocole de mesure** : baseline, hypothèse, mesure, arbitrage
documenté.

---

## 6. Limites assumées

| Limite | Nature |
|--------|--------|
| Sprint 5 non réalisé | CI/CD et orchestration : la CI livrée n'est pas fonctionnelle (version d'adaptateur, macro inexistant, manifest en placeholder) |
| Lignes fantômes dans `fct_transactions` | Documentée et chiffrée, non corrigée — deux correctifs possibles décrits dans `DESIGN.md` |
| Historisation SCD2 prospective | Un snapshot n'enregistre que les changements postérieurs à sa mise en service : aucune reconstitution d'un état de juin 2024 |
| Jeu de données synthétique | Sept défauts identifiés, six corrigés ; le septième — une tendance haussière artificielle du volume quotidien — est documenté |
| Mesures au scale M | 1 à 2 % du volume cible : toute conclusion de performance reste à revalider au scale L |

---

## 7. En une phrase

Le pipeline a été rendu exécutable, puis mesuré avant d'être optimisé — et la
mesure a montré que **le levier principal n'était pas le SQL mais le nombre de
requêtes**, un résultat qui tient à ce volume et qu'il faudra réexaminer à
l'échelle cible.
