# Rapport Power BI — restitution et supervision

Guide de construction du rapport, de la connexion Snowflake aux mesures DAX.

**Répartition des rôles :** la **détection** reste dans dbt — les tests y font
échouer un build, ce qu'un rapport ne peut pas faire. Power BI assure la
**restitution** : partageable, actualisable, lisible par une équipe finance ou un
responsable de tenant.

---

## 1. Connexion à Snowflake

**Accueil → Obtenir les données → Snowflake**

| Champ | Valeur |
|-------|--------|
| Serveur | `<identifiant_compte>.snowflakecomputing.com` |
| Entrepôt | `WH_REPORTING` |
| Base | `FINTRACK_DEV` |
| Rôle | `FINTRACK_REPORTING_ROLE` |

**Utiliser `WH_REPORTING`, pas `WH_DEV`.** C'est tout l'intérêt de la séparation
des warehouses mise en place au Sprint 1 : les requêtes BI sont facturées à part,
donc traçables, et n'entrent pas en concurrence avec les traitements dbt.

### Import ou DirectQuery

| Mode | Quand le retenir |
|------|------------------|
| **Import** (recommandé ici) | Les données sont figées et tiennent en mémoire. Rapport instantané, aucun crédit consommé à la consultation. |
| DirectQuery | Si la fraîcheur temps réel est exigée. Chaque interaction déclenche une requête facturée — à 15 utilisateurs sur un dashboard, la note monte vite. |

En mode Import, planifier une actualisation après le run dbt quotidien.

---

## 2. Tables à charger

### Faits

| Table | Schéma | Grain |
|-------|--------|-------|
| `MART_SUPERVISION_VOLUMETRIE` | `DEV_HAKAI_MARTS_SUPERVISION` | jour × tenant |
| `MART_TENANT_KPIS_DAILY` | `DEV_HAKAI_MARTS_ANALYTICS` | jour × tenant |
| `MART_RECONCILIATION` | `DEV_HAKAI_MARTS_FINANCE` | lot de rapprochement |
| `MART_TRANSACTIONS_ANOMALIES` | `DEV_HAKAI_MARTS_ANALYTICS` | transaction |
| `MART_COHORTES_RETENTION` | `DEV_HAKAI_MARTS_ANALYTICS` | cohorte × mois |

### Dimensions

| Table | Schéma |
|-------|--------|
| `DIM_TENANTS` | `DEV_HAKAI_MARTS_CORE` |
| `DIM_COMPTES` | `DEV_HAKAI_MARTS_CORE` |
| `DIM_CATEGORIES` | `DEV_HAKAI_MARTS_CORE` |

**Ne pas charger `FCT_TRANSACTIONS`** — près d'un million de lignes et 45
colonnes, pour des agrégats déjà calculés dans les marts. Le modèle dbt a été
conçu pour que la BI consomme des tables préparées ; les recalculer en DAX
annulerait ce travail.

### Table de dates

Power BI a besoin d'un calendrier continu pour ses fonctions temporelles :

```
Calendrier =
ADDCOLUMNS(
    CALENDAR(DATE(2023,1,1), DATE(2024,12,31)),
    "Année",      YEAR([Date]),
    "Mois",       FORMAT([Date], "MMM YYYY"),
    "NumMois",    YEAR([Date]) * 100 + MONTH([Date]),
    "Trimestre",  "T" & QUARTER([Date]),
    "JourSemaine", FORMAT([Date], "ddd"),
    "EstWeekend", WEEKDAY([Date], 2) > 5
)
```

Marquer la table comme table de dates (**Outils de table → Marquer comme table
de dates**), sans quoi les fonctions d'intelligence temporelle renvoient des
résultats faux sans prévenir.

---

## 3. Modèle de données

Un schéma en étoile : les dimensions filtrent les faits, jamais l'inverse.

```
                 DIM_TENANTS
                      |  (1 → *)
                      v
Calendrier --> MART_SUPERVISION_VOLUMETRIE
     |         MART_TENANT_KPIS_DAILY
     |              ^
     |              | (1 → *)
     +--------------+
                 DIM_COMPTES --> MART_TRANSACTIONS_ANOMALIES
```

| Relation | Cardinalité | Sens |
|----------|-------------|------|
| `Calendrier[Date]` → `MART_SUPERVISION_VOLUMETRIE[JOUR]` | 1 → * | simple |
| `Calendrier[Date]` → `MART_TENANT_KPIS_DAILY[JOUR]` | 1 → * | simple |
| `DIM_TENANTS[TENANT_ID]` → `MART_SUPERVISION_VOLUMETRIE[TENANT_ID]` | 1 → * | simple |
| `DIM_TENANTS[TENANT_ID]` → `MART_TENANT_KPIS_DAILY[TENANT_ID]` | 1 → * | simple |
| `DIM_COMPTES[COMPTE_ID]` → `MART_TRANSACTIONS_ANOMALIES[COMPTE_ID]` | 1 → * | simple |

**Garder les filtres en sens unique.** Le bidirectionnel paraît pratique et
produit des totaux faux dès que deux faits partagent une dimension — l'erreur de
modélisation Power BI la plus répandue.

---

## 4. Mesures DAX

```dax
-- Volumétrie
Nb transactions = SUM(MART_SUPERVISION_VOLUMETRIE[NB_TRANSACTIONS])

Volume EUR = SUM(MART_SUPERVISION_VOLUMETRIE[MONTANT_TOTAL_EUR])

Nb comptes actifs = SUM(MART_SUPERVISION_VOLUMETRIE[NB_COMPTES_ACTIFS])

-- Qualité
Taux de validation =
DIVIDE(
    SUM(MART_SUPERVISION_VOLUMETRIE[NB_VALIDEES]),
    [Nb transactions]
)

Taux de rapprochement =
DIVIDE(
    SUM(MART_SUPERVISION_VOLUMETRIE[NB_RAPPROCHEES]),
    [Nb transactions]
)

-- Supervision
Jours en anomalie =
CALCULATE(
    COUNTROWS(MART_SUPERVISION_VOLUMETRIE),
    MART_SUPERVISION_VOLUMETRIE[IS_ANOMALIE_VOLUME] = TRUE
)

Jours sans référence =
CALCULATE(
    COUNTROWS(MART_SUPERVISION_VOLUMETRIE),
    MART_SUPERVISION_VOLUMETRIE[STATUT_VOLUMETRIE] = "reference_insuffisante"
)

-- Évolution
Volume mois précédent =
CALCULATE([Volume EUR], DATEADD(Calendrier[Date], -1, MONTH))

Évolution mensuelle =
DIVIDE([Volume EUR] - [Volume mois précédent], [Volume mois précédent])

-- Mise en forme conditionnelle des écarts
Couleur statut =
SWITCH(
    SELECTEDVALUE(MART_SUPERVISION_VOLUMETRIE[STATUT_VOLUMETRIE]),
    "pic",                    "#E07A3F",
    "creux",                  "#E07A3F",
    "reference_insuffisante", "#8A94A6",
    "#2E8B6B"
)
```

**`DIVIDE` et non l'opérateur `/`** : il gère la division par zéro sans produire
d'erreur dans le visuel.

**`Jours sans référence` mérite d'être affiché.** Un rapport qui ne distingue pas
« aucune anomalie » de « impossible à juger » reproduit exactement le faux vert
rencontré avec Elementary. Mieux vaut un indicateur gris assumé qu'un vert
trompeur.

---

## 5. Pages du rapport

### Page 1 — Vue d'ensemble par tenant

*Destinataire : direction, responsables de compte.*

| Zone | Visuel | Champs |
|------|--------|--------|
| Bandeau | 4 cartes | Nb transactions, Volume EUR, Taux de validation, Nb comptes actifs |
| Centre gauche | Courbe | Volume EUR par jour, une ligne par tenant |
| Centre droit | Barres horizontales | Volume par tenant, trié décroissant |
| Bas | Table | Tenant, contrat, volume, taux de validation, taux de rapprochement |
| Filtres | Segments | Période (Calendrier), Tenant, Palier contractuel |

### Page 2 — Supervision du pipeline

*Destinataire : équipe data.*

| Zone | Visuel | Champs |
|------|--------|--------|
| Bandeau | 3 cartes | Jours en anomalie, Jours sans référence, Taux de rapprochement |
| Centre | Courbe + zone | Volume quotidien et bande de référence (moyenne ± 3 écarts-types) |
| Droite | Table | Jours en anomalie : date, tenant, volume, référence, écart % |
| Bas | Matrice | Statut de volumétrie par tenant et par mois, en couleur |

C'est la page qui montre le pic injecté du 20/11/2024 — environ 7 500
transactions contre 2 500 habituellement.

### Page 3 — Qualité des données

*Destinataire : conformité, finance.*

| Zone | Visuel | Champs |
|------|--------|--------|
| Bandeau | 3 cartes | Transactions signalées, Taux de rapprochement, Anomalies de montant |
| Gauche | Nuage de points | Montant vs score d'écart, coloré par sévérité |
| Droite | Table | Anomalies non détectées par le système source |
| Bas | Entonnoir | Transactions → validées → rapprochées |

La table des **anomalies non détectées par la source** est la plus intéressante :
elle croise notre détection statistique avec le score de fraude du système amont.
Une transaction anormale que la source n'a pas vue est exactement ce qui permet
d'affiner ses règles.

### Page 4 — Rétention

*Destinataire : direction commerciale.*

| Zone | Visuel | Champs |
|------|--------|--------|
| Centre | Matrice en chaleur | Cohortes en lignes, mois d'ancienneté en colonnes, taux de rétention en valeur |
| Droite | Courbes | Courbes de rétention par cohorte |

**Attention à la lecture :** chaque cohorte n'est observable que sur une
profondeur limitée — une cohorte de novembre 2024 n'a pas de M+6. Le modèle
expose `NB_MOIS_OBSERVABLES` : filtrer dessus évite de comparer des colonnes qui
ne portent pas sur le même nombre de cohortes.

---

## 6. Mise en forme

Palette alignée sur la présentation de soutenance :

| Usage | Couleur |
|-------|---------|
| Principal | `1E2761` |
| Secondaire | `4A7FD1` |
| Alerte / anomalie | `E07A3F` |
| Conforme | `2E8B6B` |
| Neutre / indéterminé | `8A94A6` |

**Thème → Personnaliser le thème actuel** pour l'appliquer à tous les visuels.

Deux règles de lisibilité : afficher les montants en milliers ou millions
d'euros plutôt qu'à l'unité, et réserver le rouge aux anomalies — s'il sert
aussi de couleur de série, l'œil ne distingue plus l'alerte du reste.

---

## 7. Prérequis côté Snowflake

Avant la première connexion :

```sql
GRANT USAGE ON WAREHOUSE WH_REPORTING TO ROLE FINTRACK_REPORTING_ROLE;
GRANT USAGE ON DATABASE FINTRACK_DEV TO ROLE FINTRACK_REPORTING_ROLE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE FINTRACK_DEV TO ROLE FINTRACK_REPORTING_ROLE;
GRANT SELECT ON ALL TABLES IN DATABASE FINTRACK_DEV TO ROLE FINTRACK_REPORTING_ROLE;
GRANT SELECT ON FUTURE TABLES IN DATABASE FINTRACK_DEV TO ROLE FINTRACK_REPORTING_ROLE;
GRANT ROLE FINTRACK_REPORTING_ROLE TO USER <votre_utilisateur>;
```

**Attention, écart connu du provisioning :** les droits sur les tables futures
déclarés au niveau d'une base sont neutralisés par ceux déclarés au niveau d'un
schéma. Vérifier après coup :

```sql
SHOW GRANTS TO ROLE FINTRACK_REPORTING_ROLE;
```

Si une table manque à l'appel dans Power BI, c'est presque toujours de là que
vient le problème — et non du connecteur.

---

## 8. Construire le modèle de supervision

```powershell
dbt build --select mart_supervision_volumetrie --target dev
```

Le modèle agrège `fct_transactions` par jour et par tenant, et calcule la
référence glissante sur 28 jours. Quelques secondes d'exécution.
