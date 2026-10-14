#!/usr/bin/env python3
"""
FinTrack Perf & Scale — Générateur de données synthétiques
============================================================

Génère un jeu de données réaliste pour la plateforme FinTrack B2B2C :
    - Tenants (banques partenaires)
    - Comptes clients
    - Titulaires et rattachements compte ↔ titulaire (comptes joints)
    - Transactions (table large, ~80 colonnes)
    - Virements internes
    - Taux de change historisés

Volumes paramétrables via --scale : XS (dev) → XXL (production simulation).

Sortie : fichiers CSV compressés (.csv.gz) dans data/raw/, prêts à être
chargés via COPY INTO depuis un stage Snowflake interne.

Usage :
    python generate_data.py --scale M --output data/raw/
    python generate_data.py --scale XL --output data/raw/ --seed 42

Presets de volume :
    XS  :    10 000 transactions      (dev rapide, ~1 min)
    S   :   100 000 transactions      (dev, ~3 min)
    M   : 1 000 000 transactions      (test perf, ~10 min)
    L   : 10 000 000 transactions     (bench, ~1h — nécessite ~8 Go RAM)
    XL  : 50 000 000 transactions     (simulation prod, ~5h)
    XXL : 100 000 000 transactions    (stress test, ~10h)

------------------------------------------------------------------------------
CORRECTIONS APPORTÉES AU GÉNÉRATEUR D'ORIGINE
------------------------------------------------------------------------------
Six défauts du générateur livré faussaient les analyses. Ils sont corrigés ici
et documentés dans docs/JOURNAL_MISSION.md.

1. COHÉRENCE MULTI-TENANT
   Avant : le tenant_id d'une transaction était tiré indépendamment de celui de
   son compte. Sur une plateforme multi-tenant, les KPI par banque partenaire
   étaient donc faux, et aucun test ne pouvait le détecter (les relationships
   passent : le tenant existe, il n'est simplement pas le bon).
   Après : le tenant d'une transaction et d'un virement est TOUJOURS celui du
   compte concerné.

2. PLAGES DE DATES COHÉRENTES
   Avant : transactions sur 2023-2024, virements sur « les 2 dernières années »
   (donc glissant jusqu'à aujourd'hui), comptes ouverts « il y a 5 ans » avec
   activité jusqu'à aujourd'hui, FX sur 2023-2024 seulement. Résultat : des
   virements sans taux de change, et des transactions antérieures à l'ouverture
   de leur compte.
   Après : une période unique (PERIODE_DEBUT → PERIODE_FIN) pour tous les faits,
   un référentiel FX qui la déborde des deux côtés, et des transactions toujours
   postérieures à l'ouverture de leur compte.

3. TAUX DE CHANGE RÉALISTES ET COHÉRENTS
   Avant : taux_change_applique = random.uniform(0.85, 1.30) quelle que soit la
   devise — un JPY au même taux qu'un USD —, sans aucun rapport avec la table
   raw_fx_rates. Impossible de valider l'US 4.2 (« recalculer montant_eur et
   vérifier moins de 0,01 % d'écart »).
   Après : le taux appliqué est LU dans le référentiel FX du jour, et
   montant_eur = montant / taux (le référentiel cote EUR → devise).

4. TRANSACTIONS DE TEST
   Avant : is_test valait toujours False. La règle d'exclusion du staging
   n'était donc jamais exercée sur des données réelles.
   Après : environ 0,5 % de transactions de test.

5. _loaded_at DIFFÉRENCIÉ  ← le plus important pour le Sprint 3
   Avant : la colonne n'était pas générée, et le DEFAULT CURRENT_TIMESTAMP()
   donnait la même valeur à toutes les lignes d'un chargement. Les modèles
   incrémentaux filtrant sur `_loaded_at >= max(_loaded_at) - N jours`
   sélectionnaient donc 100 % de la table à chaque run : l'incrémental ne
   servait à rien et ne pouvait pas être testé.
   Après : _loaded_at = date de l'événement + délai d'ingestion réaliste
   (quelques minutes à quelques heures). La fenêtre de lookback a enfin un sens.

6. HIÉRARCHIE DE CATÉGORIES
   Avant : 30 catégories toutes au niveau 1, sans parent. La CTE récursive de
   dim_categories ne descendait sur aucun niveau.
   Après : arbre sur 3 niveaux — groupe → catégorie → sous-catégorie.

NOUVEAUTÉS (US 2.2)
   raw_titulaires et raw_compte_titulaires : personnes physiques et comptes
   joints, avec allocation_factor et historisation.
------------------------------------------------------------------------------
"""

import argparse
import csv
import gzip
import random
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path

# La console Windows est fréquemment en cp1252 : sans cela, le moindre
# caractère accentué dans un print fait planter la génération.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    from faker import Faker
    import numpy as np
except ImportError:
    print("ERREUR : dépendances manquantes.")
    print("Installez avec : pip install faker numpy")
    sys.exit(1)


# ============================================================
# CONFIGURATION
# ============================================================

SCALE_PRESETS = {
    "XS":     {"n_transactions": 10_000,      "n_comptes": 200,      "n_tenants": 3},
    "S":      {"n_transactions": 100_000,     "n_comptes": 2_000,    "n_tenants": 5},
    "M":      {"n_transactions": 1_000_000,   "n_comptes": 20_000,   "n_tenants": 8},
    "L":      {"n_transactions": 10_000_000,  "n_comptes": 200_000,  "n_tenants": 12},
    "XL":     {"n_transactions": 50_000_000,  "n_comptes": 1_000_000, "n_tenants": 15},
    "XXL":    {"n_transactions": 100_000_000, "n_comptes": 2_000_000, "n_tenants": 20},
}

# --- Période de référence, commune à TOUS les faits ---------------------
# Tout événement (transaction, virement) tombe dans cette fenêtre.
PERIODE_DEBUT = datetime(2023, 1, 1)
PERIODE_FIN   = datetime(2024, 12, 31)

# Les comptes sont ouverts avant ou pendant la période.
OUVERTURE_DEBUT = datetime(2021, 1, 1)

# Le référentiel FX déborde la période des deux côtés : les modèles aval
# doivent toujours trouver un taux, y compris sur les bords.
FX_DEBUT = datetime(2022, 12, 1)
FX_FIN   = datetime(2025, 1, 31)

TENANTS_SEED = [
    ("BNP-FR",     "BNP Paribas France",           "FR", "EUR"),
    ("CA-FR",      "Crédit Agricole",              "FR", "EUR"),
    ("SG-FR",      "Société Générale",             "FR", "EUR"),
    ("ING-NL",     "ING Netherlands",              "NL", "EUR"),
    ("DB-DE",      "Deutsche Bank",                "DE", "EUR"),
    ("SANT-ES",    "Santander España",             "ES", "EUR"),
    ("UCG-IT",     "UniCredit Italia",             "IT", "EUR"),
    ("HSBC-UK",    "HSBC UK",                      "GB", "GBP"),
    ("BARC-UK",    "Barclays",                     "GB", "GBP"),
    ("UBS-CH",     "UBS Switzerland",              "CH", "CHF"),
    ("CS-CH",      "Credit Suisse",                "CH", "CHF"),
    ("KBC-BE",     "KBC Belgique",                 "BE", "EUR"),
    ("NORDEA-SE",  "Nordea Sweden",                "SE", "SEK"),
    ("DNB-NO",     "DNB Norway",                   "NO", "NOK"),
    ("REVOLUT",    "Revolut Business",             "GB", "GBP"),
    ("N26",        "N26",                          "DE", "EUR"),
    ("QONTO",      "Qonto",                        "FR", "EUR"),
    ("LYDIA",      "Lydia",                        "FR", "EUR"),
    ("BUNQ",       "bunq",                         "NL", "EUR"),
    ("STARLING",   "Starling Bank",                "GB", "GBP"),
]

DEVISES = ["EUR", "USD", "GBP", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "JPY"]
DEVISES_POIDS = [0.55, 0.15, 0.10, 0.05, 0.03, 0.03, 0.03, 0.02, 0.02, 0.02]

# Taux de départ EUR → devise (1 EUR = N unités de la devise)
FX_TAUX_INITIAUX = {
    "USD": 1.08, "GBP": 0.85, "CHF": 0.96, "SEK": 11.20,
    "NOK": 11.50, "DKK": 7.45, "PLN": 4.30, "CZK": 24.50, "JPY": 160.00,
}

# --- Référentiel de catégories sur 3 niveaux ----------------------------
# Niveau 1 : les groupes (racines). Niveau 2 : les catégories.
# Niveau 3 : quelques sous-catégories, pour que la récursion descende
# réellement sur trois étages.
GROUPES = [
    (100, "Revenus"),
    (200, "Quotidien"),
    (300, "Logement"),
    (400, "Loisirs"),
    (500, "Épargne"),
    (600, "Enfants"),
    (700, "Fiscal"),
    (800, "Divers"),
]

# (id, nom, type, id_groupe_parent)
CATEGORIES = [
    (1,  "Salaire",              "revenu",  100),
    (2,  "Freelance",            "revenu",  100),
    (3,  "Dividendes",           "revenu",  100),
    (4,  "Alimentation",         "depense", 200),
    (5,  "Transport",            "depense", 200),
    (6,  "Carburant",            "depense", 200),
    (7,  "Loyer",                "depense", 300),
    (8,  "Électricité",          "depense", 300),
    (9,  "Gaz",                  "depense", 300),
    (10, "Internet",             "depense", 300),
    (11, "Assurance habitation", "depense", 300),
    (12, "Restaurant",           "depense", 400),
    (13, "Bar",                  "depense", 400),
    (14, "Cinéma",               "depense", 400),
    (15, "Voyage",               "depense", 400),
    (16, "Abonnements SVOD",     "depense", 400),
    (17, "Épargne versée",       "depense", 500),
    (18, "PEA",                  "depense", 500),
    (19, "Assurance vie",        "depense", 500),
    (20, "Remboursement",        "revenu",  800),
    (21, "Santé",                "depense", 200),
    (22, "Mutuelle",             "depense", 200),
    (23, "Vêtements",            "depense", 400),
    (24, "Éducation",            "depense", 600),
    (25, "Crèche",               "depense", 600),
    (26, "Impôts",               "depense", 700),
    (27, "Cotisations sociales", "depense", 700),
    (28, "Frais bancaires",      "depense", 800),
    (29, "Intérêts crédit",      "depense", 800),
    (30, "Cashback",             "revenu",  800),
]

# (id, nom, type, id_categorie_parent) — niveau 3
SOUS_CATEGORIES = [
    (31, "Fast-food",            "depense", 12),
    (32, "Restaurant gastro",    "depense", 12),
    (33, "Supermarché",          "depense", 4),
    (34, "Commerce de proximité", "depense", 4),
    (35, "Train",                "depense", 5),
    (36, "Avion",                "depense", 5),
    (37, "Taxi / VTC",           "depense", 5),
]

CANAUX = ["web", "mobile_ios", "mobile_android", "api", "batch", "atm", "pos"]
DEVICES = ["desktop", "smartphone", "tablet", "atm", "pos_terminal", "server"]
STATUTS_TX = ["validee", "en_attente", "rejetee", "annulee", "en_cours_verification"]
STATUTS_TX_WEIGHTS = [0.92, 0.03, 0.02, 0.01, 0.02]
TYPES_OPERATION = ["debit", "credit"]
KYC_LEVELS = ["basic", "intermediate", "advanced", "not_verified"]
AML_FLAGS = ["clean", "watchlist_check", "manual_review", "suspicious", "cleared"]
AML_WEIGHTS = [0.985, 0.005, 0.005, 0.002, 0.003]
MOYENS_PAIEMENT = ["carte", "virement", "prelevement", "cheque", "especes", "wallet"]
MARCHANDS_CATS = ["retail", "food", "travel", "utilities", "healthcare", "education",
                  "entertainment", "financial_services", "government", "other"]

# Part de transactions marquées comme tests techniques
TAUX_TRANSACTIONS_TEST = 0.005

# Part de comptes détenus en indivision (comptes joints)
TAUX_COMPTES_JOINTS = 0.12


# ============================================================
# GÉNÉRATEURS
# ============================================================

def generate_tenants(n: int, output_dir: Path) -> list:
    """Table des tenants (banques partenaires B2B2C)."""
    path = output_dir / "raw_tenants.csv.gz"
    tenants = TENANTS_SEED[:n]
    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["tenant_id", "tenant_code", "tenant_name", "country_code",
                    "devise_locale", "date_onboarding", "sla_freshness_hours",
                    "contract_tier", "is_active", "_loaded_at"])
        for i, (code, name, country, devise) in enumerate(tenants, start=1):
            onboarding = OUVERTURE_DEBUT + timedelta(days=random.randint(0, 500))
            w.writerow([
                i, code, name, country, devise,
                onboarding.date().isoformat(),
                random.choice([2, 4, 6, 12, 24]),
                random.choices(["gold", "silver", "bronze"], weights=[0.2, 0.5, 0.3])[0],
                random.random() > 0.05,
                PERIODE_FIN.isoformat(),
            ])
    print(f"  [OK] {path.name} ({n} tenants)")
    return list(range(1, n + 1))


def generate_categories(output_dir: Path) -> list:
    """Référentiel hiérarchique sur 3 niveaux : groupe → catégorie → sous-catégorie."""
    path = output_dir / "raw_categories.csv.gz"
    groupes_par_id = dict(GROUPES)
    categories_ids = []

    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["categorie_id", "nom_categorie", "type_categorie",
                    "groupe", "categorie_parent_id", "niveau_hierarchique",
                    "is_active", "date_creation", "_loaded_at"])

        # Niveau 1 — les groupes sont des catégories racines
        for gid, nom in GROUPES:
            w.writerow([gid, nom, "groupe", nom, "", 1, True,
                        "2023-01-01", PERIODE_FIN.isoformat()])

        # Niveau 2 — les catégories, rattachées à leur groupe
        for (cid, nom, type_c, parent_id) in CATEGORIES:
            w.writerow([cid, nom, type_c, groupes_par_id[parent_id], parent_id, 2,
                        True, "2023-01-01", PERIODE_FIN.isoformat()])
            categories_ids.append(cid)

        # Niveau 3 — les sous-catégories
        categories_par_id = {c[0]: c for c in CATEGORIES}
        for (sid, nom, type_c, parent_id) in SOUS_CATEGORIES:
            groupe_nom = groupes_par_id[categories_par_id[parent_id][3]]
            w.writerow([sid, nom, type_c, groupe_nom, parent_id, 3,
                        True, "2023-01-01", PERIODE_FIN.isoformat()])
            categories_ids.append(sid)

    total = len(GROUPES) + len(CATEGORIES) + len(SOUS_CATEGORIES)
    print(f"  [OK] {path.name} ({total} catégories sur 3 niveaux)")
    return categories_ids


def generate_fx_rates(output_dir: Path) -> dict:
    """Taux de change quotidiens EUR → devise.

    Retourne le référentiel sous forme de dictionnaire {(date, devise): taux},
    afin que les transactions utilisent EXACTEMENT ces taux — condition pour
    que montant_eur soit recalculable à l'identique en aval (US 4.2).
    """
    path = output_dir / "raw_fx_rates.csv.gz"
    n_days = (FX_FIN - FX_DEBUT).days + 1
    taux_courants = dict(FX_TAUX_INITIAUX)
    referentiel = {}
    rows = 0

    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["fx_id", "devise_source", "devise_cible", "date_cotation",
                    "taux", "source_provider", "loaded_at", "_loaded_at"])
        fx_id = 1
        for d in range(n_days):
            current = FX_DEBUT + timedelta(days=d)
            jour = current.date()
            for devise, _ in FX_TAUX_INITIAUX.items():
                # Marche aléatoire bornée pour éviter les dérives absurdes
                base = taux_courants[devise]
                bruit = np.random.normal(0, base * 0.004)
                nouveau = max(FX_TAUX_INITIAUX[devise] * 0.70,
                              min(FX_TAUX_INITIAUX[devise] * 1.30, base + bruit))
                taux_courants[devise] = nouveau
                taux_arrondi = round(nouveau, 6)
                referentiel[(jour, devise)] = taux_arrondi
                w.writerow([fx_id, "EUR", devise, jour.isoformat(),
                            taux_arrondi,
                            random.choice(["ECB", "Reuters", "Bloomberg"]),
                            current.isoformat(),
                            (current + timedelta(hours=6)).isoformat()])
                fx_id += 1
                rows += 1
            # L'euro contre lui-même : toujours 1
            referentiel[(jour, "EUR")] = 1.0

    print(f"  [OK] {path.name} ({rows:,} lignes, {FX_DEBUT.date()} -> {FX_FIN.date()})")
    return referentiel


def generate_comptes(n: int, tenant_ids: list, output_dir: Path, fake: Faker) -> dict:
    """Comptes clients — schéma large avec KYC, adresse, préférences.

    Retourne des tableaux numpy alignés (compte_id, tenant_id, offset
    d'ouverture en jours depuis PERIODE_DEBUT) pour que les transactions
    héritent du bon tenant et ne précèdent jamais l'ouverture du compte.
    """
    path = output_dir / "raw_comptes.csv.gz"
    periode_jours = (PERIODE_FIN - PERIODE_DEBUT).days

    tenants_arr = np.empty(n, dtype=np.int32)
    ouverture_offsets = np.empty(n, dtype=np.int32)
    types_compte = []

    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "compte_id", "tenant_id", "numero_compte", "iban", "bic",
            "nom_client", "prenom_client", "email", "telephone", "date_naissance",
            "adresse_ligne1", "adresse_ligne2", "code_postal", "ville", "pays",
            "type_compte", "devise", "solde_initial", "solde_actuel",
            "date_ouverture", "date_derniere_activite", "statut",
            "kyc_level", "kyc_date_verification", "aml_flag",
            "customer_segment", "preferred_language", "consent_marketing",
            "consent_data_sharing", "is_pep", "risk_score",
            "created_at", "updated_at", "created_by_source_system", "_loaded_at",
        ])
        jours_ouverture_possibles = (PERIODE_FIN - OUVERTURE_DEBUT).days

        for cid in range(1, n + 1):
            tenant = random.choice(tenant_ids)
            open_dt = OUVERTURE_DEBUT + timedelta(
                days=random.randint(0, jours_ouverture_possibles))
            open_date = open_dt.date()

            # Offset de l'ouverture dans la période de référence (0 si antérieure)
            offset = max(0, (open_dt - PERIODE_DEBUT).days)
            offset = min(offset, periode_jours)

            tenants_arr[cid - 1] = tenant
            ouverture_offsets[cid - 1] = offset

            derniere_activite = PERIODE_DEBUT + timedelta(
                days=random.randint(offset, periode_jours))

            type_compte = random.choices(
                ["courant", "epargne", "joint", "pro", "jeune"],
                weights=[0.55, 0.25, 0.10, 0.07, 0.03])[0]
            types_compte.append(type_compte)

            statut = random.choices(
                ["actif", "inactif", "cloture", "suspendu"],
                weights=[0.82, 0.10, 0.06, 0.02])[0]

            w.writerow([
                cid, tenant, fake.bban(), fake.iban(), fake.swift(),
                fake.last_name(), fake.first_name(), fake.email(),
                fake.phone_number(),
                fake.date_of_birth(minimum_age=18, maximum_age=85).isoformat(),
                fake.street_address(),
                fake.secondary_address() if random.random() < 0.3 else "",
                fake.postcode(), fake.city(), fake.country_code(),
                type_compte,
                random.choices(DEVISES, weights=DEVISES_POIDS)[0],
                round(random.uniform(0, 15000), 2),
                round(random.uniform(-500, 50000), 2),
                open_date.isoformat(),
                derniere_activite.date().isoformat(),
                statut,
                random.choices(KYC_LEVELS, weights=[0.30, 0.40, 0.25, 0.05])[0],
                (open_dt + timedelta(days=random.randint(0, 60))).date().isoformat(),
                random.choices(AML_FLAGS, weights=AML_WEIGHTS)[0],
                random.choices(["mass_market", "affluent", "premium", "private"],
                               weights=[0.75, 0.18, 0.05, 0.02])[0],
                random.choices(["fr", "en", "de", "es", "it", "nl"],
                               weights=[0.50, 0.20, 0.10, 0.08, 0.07, 0.05])[0],
                random.random() > 0.4,
                random.random() > 0.6,
                random.random() < 0.008,
                round(random.uniform(0, 100), 1),
                open_dt.isoformat(),
                derniere_activite.isoformat(),
                random.choice(["core_banking_v1", "core_banking_v2",
                               "onboarding_app", "legacy_import"]),
                (derniere_activite + timedelta(hours=4)).isoformat(),
            ])
            if cid % 100_000 == 0:
                print(f"    ... {cid:,} comptes générés")

    print(f"  [OK] {path.name} ({n:,} comptes)")
    return {
        "ids": np.arange(1, n + 1, dtype=np.int64),
        "tenants": tenants_arr,
        "ouverture_offsets": ouverture_offsets,
        "types": types_compte,
    }


def generate_titulaires(comptes: dict, output_dir: Path, fake: Faker) -> None:
    """US 2.2 — personnes physiques et rattachements compte ↔ titulaire.

    Un compte a un titulaire principal ; les comptes joints en ont deux, avec
    une clé de répartition (allocation_factor) dont la somme vaut 1 par compte.
    Le rattachement est historisé : date_debut / date_fin.
    """
    path_t = output_dir / "raw_titulaires.csv.gz"
    path_ct = output_dir / "raw_compte_titulaires.csv.gz"

    n_comptes = len(comptes["ids"])
    types = comptes["types"]

    with gzip.open(path_t, "wt", encoding="utf-8", newline="") as ft, \
         gzip.open(path_ct, "wt", encoding="utf-8", newline="") as fct:

        wt = csv.writer(ft)
        wt.writerow(["titulaire_id", "nom", "prenom", "email", "telephone",
                     "date_naissance", "pays_residence", "is_pep",
                     "created_at", "updated_at", "_loaded_at"])

        wct = csv.writer(fct)
        wct.writerow(["compte_titulaire_id", "compte_id", "titulaire_id",
                      "role_titulaire", "allocation_factor", "is_primary",
                      "date_debut", "date_fin", "created_at", "updated_at",
                      "_loaded_at"])

        titulaire_id = 0
        lien_id = 0
        n_joints = 0

        for idx in range(n_comptes):
            compte_id = int(comptes["ids"][idx])
            offset = int(comptes["ouverture_offsets"][idx])
            date_debut = (PERIODE_DEBUT + timedelta(days=offset)).date()

            # Un compte "joint" a deux titulaires ; les autres en ont un,
            # avec une petite part de co-détention sur les comptes courants.
            est_joint = (types[idx] == "joint") or (random.random() < TAUX_COMPTES_JOINTS
                                                    and types[idx] == "courant")
            nb_titulaires = 2 if est_joint else 1
            if est_joint:
                n_joints += 1

            # Répartition : 50/50 sur un compte joint, sinon 100 %
            if nb_titulaires == 2:
                part_principale = round(random.choice([0.5, 0.6, 0.7]), 2)
                parts = [part_principale, round(1 - part_principale, 2)]
            else:
                parts = [1.0]

            for rang in range(nb_titulaires):
                titulaire_id += 1
                lien_id += 1

                wt.writerow([
                    titulaire_id,
                    fake.last_name(), fake.first_name(), fake.email(),
                    fake.phone_number(),
                    fake.date_of_birth(minimum_age=18, maximum_age=85).isoformat(),
                    fake.country_code(),
                    random.random() < 0.008,
                    date_debut.isoformat(),
                    date_debut.isoformat(),
                    PERIODE_FIN.isoformat(),
                ])

                wct.writerow([
                    lien_id, compte_id, titulaire_id,
                    "titulaire_principal" if rang == 0 else "co_titulaire",
                    parts[rang],
                    rang == 0,
                    date_debut.isoformat(),
                    "",                       # rattachement toujours en cours
                    date_debut.isoformat(),
                    date_debut.isoformat(),
                    PERIODE_FIN.isoformat(),
                ])

            if compte_id % 100_000 == 0:
                print(f"    ... {compte_id:,} comptes traités")

    print(f"  [OK] {path_t.name} ({titulaire_id:,} titulaires)")
    print(f"  [OK] {path_ct.name} ({lien_id:,} rattachements, "
          f"dont {n_joints:,} comptes joints)")


def generate_transactions(n: int, comptes: dict, output_dir: Path, fake: Faker,
                          fx: dict, categories_ids: list,
                          batch_size: int = 500_000) -> None:
    """Table de faits large — ~80 colonnes réalistes.

    Écrit en batches pour éviter de saturer la mémoire.
    """
    path = output_dir / "raw_transactions.csv.gz"
    periode_jours = (PERIODE_FIN - PERIODE_DEBUT).days
    comptes_ids = comptes["ids"]
    comptes_tenants = comptes["tenants"]
    comptes_ouvertures = comptes["ouverture_offsets"]
    n_comptes = len(comptes_ids)
    categories_arr_source = np.array(categories_ids, dtype=np.int32)

    columns = [
        # Identifiants
        "transaction_id", "external_transaction_id", "tenant_id", "compte_id",
        "compte_source_iban", "compte_dest_iban",
        # Temporalité (multiple timestamps — typique en finance)
        "date_transaction", "date_valeur", "date_comptabilisation",
        "date_reception", "date_traitement", "date_settlement",
        # Montants et devises
        "montant", "devise", "montant_eur", "taux_change_applique",
        "frais", "frais_devise", "montant_net",
        "type_operation", "sens",
        # Catégorisation
        "categorie_id", "categorie_auto_detectee", "confiance_categorie",
        "sous_categorie", "tags",
        # Marchand
        "marchand_nom", "marchand_id", "marchand_categorie", "marchand_pays",
        "marchand_mcc", "marchand_siret",
        # Moyen de paiement
        "moyen_paiement", "carte_id", "carte_last4", "carte_type",
        "carte_reseau", "authentification_3ds",
        # Contexte technique
        "canal", "device_type", "device_id", "user_agent",
        "ip_address", "session_id", "geolocation_lat", "geolocation_lon",
        # Statut et workflow
        "statut", "statut_precedent", "nb_tentatives", "date_derniere_tentative",
        "raison_rejet", "code_erreur", "message_erreur",
        # Audit et compliance
        "aml_score", "aml_flag", "aml_reviewed_by", "aml_review_date",
        "fraud_score", "fraud_rules_triggered", "is_flagged_for_review",
        # Rapprochement bancaire
        "is_reconciled", "date_reconciliation", "reconciliation_batch_id",
        "external_reference", "internal_reference",
        # Description
        "description", "description_brute", "description_enrichie",
        "libelle_court",
        # Métadonnées
        "source_system", "source_file_batch_id",
        "created_at", "updated_at", "loaded_at", "processing_version",
        "is_test", "is_reversal", "original_transaction_id",
        "_loaded_at",
    ]

    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(columns)

        n_batches = (n + batch_size - 1) // batch_size
        for b in range(n_batches):
            b_size = min(batch_size, n - b * batch_size)
            offset = b * batch_size

            # Tirages vectorisés — un indice de compte, pas un compte_id :
            # on a besoin de l'indice pour retrouver tenant et date d'ouverture.
            idx_comptes = np.random.randint(0, n_comptes, size=b_size)
            montants = np.round(np.random.lognormal(3.5, 1.2, b_size), 2)

            # La transaction tombe toujours APRÈS l'ouverture de son compte
            ouvertures = comptes_ouvertures[idx_comptes]
            marge = (periode_jours - ouvertures).astype(np.float64)
            days_offsets = ouvertures + np.floor(
                np.random.random(b_size) * (marge + 1)).astype(np.int32)

            hour_offsets = np.random.randint(0, 24, size=b_size)
            minute_offsets = np.random.randint(0, 60, size=b_size)
            statuts = np.random.choice(STATUTS_TX, size=b_size, p=STATUTS_TX_WEIGHTS)
            types_op = np.random.choice(TYPES_OPERATION, size=b_size, p=[0.78, 0.22])
            categories_arr = np.random.choice(categories_arr_source, size=b_size)
            devises_arr = np.random.choice(DEVISES, size=b_size, p=DEVISES_POIDS)
            canaux_arr = np.random.choice(CANAUX, size=b_size,
                                          p=[0.20, 0.28, 0.30, 0.15, 0.04, 0.02, 0.01])
            aml_flags_arr = np.random.choice(AML_FLAGS, size=b_size, p=AML_WEIGHTS)
            aml_scores = np.round(np.random.beta(1, 30, b_size) * 100, 2)
            fraud_scores = np.round(np.random.beta(1, 50, b_size) * 100, 2)
            is_test_arr = np.random.random(b_size) < TAUX_TRANSACTIONS_TEST

            for i in range(b_size):
                tx_id = offset + i + 1
                idx = idx_comptes[i]
                compte_id = int(comptes_ids[idx])
                tenant_id = int(comptes_tenants[idx])   # ← cohérence multi-tenant

                dt = PERIODE_DEBUT + timedelta(days=int(days_offsets[i]),
                                               hours=int(hour_offsets[i]),
                                               minutes=int(minute_offsets[i]))
                dt_valeur = dt + timedelta(hours=random.randint(-2, 48))
                dt_compta = dt + timedelta(hours=random.randint(1, 72))
                dt_reception = dt + timedelta(minutes=random.randint(0, 5))
                dt_traitement = dt + timedelta(minutes=random.randint(5, 120))
                dt_settlement = dt + timedelta(days=random.randint(0, 3))

                # Ingestion : l'événement arrive dans le SI avec un délai court.
                # C'est ce décalage qui donne un _loaded_at exploitable par les
                # modèles incrémentaux.
                dt_ingestion = dt + timedelta(hours=random.randint(1, 10),
                                              minutes=random.randint(0, 59))

                montant = float(montants[i])
                devise = devises_arr[i]

                # Taux du jour, lu dans le référentiel FX réellement chargé
                taux = fx.get((dt.date(), devise), 1.0)
                # Le référentiel cote EUR → devise : on divise pour revenir en EUR
                montant_eur = round(montant / taux, 2) if taux else montant

                frais = round(random.uniform(0, 2.5), 2) if random.random() < 0.15 else 0
                sens = "sortant" if types_op[i] == "debit" else "entrant"
                is_flagged = aml_flags_arr[i] in ("suspicious", "manual_review")

                w.writerow([
                    tx_id,
                    f"EXT-{uuid.uuid4().hex[:16].upper()}",
                    tenant_id,
                    compte_id,
                    fake.iban() if random.random() < 0.4 else "",
                    fake.iban() if types_op[i] == "credit" and random.random() < 0.5 else "",
                    dt.isoformat(),
                    dt_valeur.isoformat(),
                    dt_compta.isoformat(),
                    dt_reception.isoformat(),
                    dt_traitement.isoformat(),
                    dt_settlement.isoformat(),
                    montant, devise, montant_eur, taux, frais, devise,
                    round(montant - frais, 2),
                    types_op[i], sens,
                    int(categories_arr[i]),
                    random.random() < 0.85,
                    round(random.uniform(0.3, 1.0), 3),
                    "" if random.random() < 0.6 else fake.word(),
                    "" if random.random() < 0.7 else ",".join(fake.words(nb=2)),
                    fake.company() if types_op[i] == "debit" else "",
                    f"MRC-{random.randint(1000, 99999)}" if types_op[i] == "debit" else "",
                    random.choice(MARCHANDS_CATS) if types_op[i] == "debit" else "",
                    fake.country_code() if types_op[i] == "debit" else "",
                    random.randint(1000, 9999) if types_op[i] == "debit" else "",
                    fake.numerify("###############") if random.random() < 0.3 else "",
                    random.choice(MOYENS_PAIEMENT),
                    f"CARD-{random.randint(10000, 99999)}" if random.random() < 0.7 else "",
                    fake.credit_card_number()[-4:] if random.random() < 0.7 else "",
                    random.choice(["visa", "mastercard", "amex", ""]) if random.random() < 0.7 else "",
                    random.choice(["visa_electron", "mastercard_debit", "amex_gold", ""]) if random.random() < 0.5 else "",
                    random.random() < 0.85,
                    canaux_arr[i],
                    random.choice(DEVICES),
                    f"DEV-{uuid.uuid4().hex[:12]}" if random.random() < 0.6 else "",
                    fake.user_agent() if random.random() < 0.5 else "",
                    fake.ipv4() if random.random() < 0.7 else "",
                    f"SESS-{uuid.uuid4().hex[:16]}" if random.random() < 0.4 else "",
                    round(fake.latitude(), 4) if random.random() < 0.3 else "",
                    round(fake.longitude(), 4) if random.random() < 0.3 else "",
                    statuts[i],
                    "en_attente" if statuts[i] != "en_attente" else "",
                    random.randint(1, 3) if statuts[i] in ("rejetee", "annulee") else 1,
                    dt_traitement.isoformat() if statuts[i] in ("rejetee", "annulee") else "",
                    random.choice(["insufficient_funds", "auth_failed", "expired_card",
                                   "fraud_suspected", "invalid_iban", ""]) if statuts[i] == "rejetee" else "",
                    f"ERR-{random.randint(100, 999)}" if statuts[i] == "rejetee" else "",
                    fake.sentence(nb_words=6) if statuts[i] == "rejetee" else "",
                    float(aml_scores[i]),
                    aml_flags_arr[i],
                    fake.user_name() if aml_flags_arr[i] != "clean" else "",
                    dt.isoformat() if aml_flags_arr[i] != "clean" else "",
                    float(fraud_scores[i]),
                    "|".join(random.sample(["velocity", "geo_anomaly", "amount_anomaly",
                                            "device_change", "known_fraudster"],
                                           k=random.randint(0, 2))),
                    is_flagged,
                    random.random() < 0.90,
                    dt_settlement.isoformat() if random.random() < 0.90 else "",
                    # Lot de rapprochement : un lot par jour et par tenant, afin
                    # que mart_reconciliation agrège réellement quelque chose.
                    f"BATCH-{dt.strftime('%Y%m%d')}-T{tenant_id}" if random.random() < 0.90 else "",
                    f"REF-{uuid.uuid4().hex[:20].upper()}",
                    f"INT-{tx_id:012d}",
                    fake.sentence(nb_words=random.randint(3, 10)),
                    fake.text(max_nb_chars=80).replace("\n", " ")[:80],
                    fake.text(max_nb_chars=120).replace("\n", " ")[:120],
                    fake.text(max_nb_chars=30).replace("\n", " ")[:30],
                    random.choice(["core_banking_v1", "core_banking_v2",
                                   "payment_gateway", "batch_import"]),
                    f"FILE-{dt.strftime('%Y%m%d')}-{random.randint(1, 20)}",
                    dt_reception.isoformat(),
                    dt_traitement.isoformat(),
                    dt_traitement.isoformat(),
                    f"v{random.choice(['1.0', '1.1', '2.0', '2.1'])}",
                    bool(is_test_arr[i]),
                    random.random() < 0.005,
                    tx_id - random.randint(1, 100) if random.random() < 0.005 else "",
                    dt_ingestion.isoformat(),
                ])
            print(f"    ... batch {b+1}/{n_batches} — "
                  f"{min((b+1)*batch_size, n):,}/{n:,} transactions")
    print(f"  [OK] {path.name} ({n:,} transactions, {len(columns)} colonnes)")


def generate_virements(n: int, comptes: dict, output_dir: Path, fake: Faker) -> None:
    """Virements internes entre comptes d'un MÊME tenant.

    Un virement interne traverse rarement deux banques partenaires : source et
    destination appartiennent donc au même tenant, et le tenant_id du virement
    est celui des comptes concernés.
    """
    path = output_dir / "raw_virements.csv.gz"
    comptes_ids = comptes["ids"]
    comptes_tenants = comptes["tenants"]
    comptes_ouvertures = comptes["ouverture_offsets"]
    periode_jours = (PERIODE_FIN - PERIODE_DEBUT).days

    # Indices de comptes groupés par tenant, pour tirer deux comptes compatibles
    comptes_par_tenant = {}
    for idx, tenant in enumerate(comptes_tenants):
        comptes_par_tenant.setdefault(int(tenant), []).append(idx)
    tenants_eligibles = [t for t, v in comptes_par_tenant.items() if len(v) >= 2]

    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["virement_id", "tenant_id", "compte_source_id", "compte_dest_id",
                    "montant", "devise", "date_virement", "date_execution",
                    "motif", "reference", "statut", "type_virement",
                    "frais", "created_at", "updated_at", "_loaded_at"])

        for i in range(1, n + 1):
            tenant = random.choice(tenants_eligibles)
            idx_src, idx_dst = random.sample(comptes_par_tenant[tenant], 2)

            # Le virement est postérieur à l'ouverture des DEUX comptes
            offset_min = int(max(comptes_ouvertures[idx_src],
                                 comptes_ouvertures[idx_dst]))
            dt = PERIODE_DEBUT + timedelta(
                days=random.randint(offset_min, periode_jours),
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59))

            dt_execution = dt + timedelta(hours=random.randint(0, 48))
            dt_ingestion = dt + timedelta(hours=random.randint(1, 10))

            w.writerow([
                i, tenant,
                int(comptes_ids[idx_src]), int(comptes_ids[idx_dst]),
                round(random.uniform(10, 5000), 2),
                random.choice(DEVISES[:3]),
                dt.isoformat(),
                dt_execution.isoformat(),
                fake.sentence(nb_words=5),
                f"VIR-{uuid.uuid4().hex[:12].upper()}",
                random.choices(["execute", "en_attente", "annule", "rejete"],
                               weights=[0.88, 0.05, 0.04, 0.03])[0],
                random.choice(["ponctuel", "recurrent", "sepa", "swift", "instant"]),
                round(random.uniform(0, 5), 2) if random.random() < 0.3 else 0,
                dt.isoformat(),
                dt_execution.isoformat(),
                dt_ingestion.isoformat(),
            ])
    print(f"  [OK] {path.name} ({n:,} virements)")


# ============================================================
# MAIN
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scale", choices=list(SCALE_PRESETS.keys()),
                        default="S", help="Volume preset (default: S)")
    parser.add_argument("--output", default="data/raw",
                        help="Répertoire de sortie (default: data/raw)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--tenants", type=int, help="Override n_tenants")
    parser.add_argument("--comptes", type=int, help="Override n_comptes")
    parser.add_argument("--transactions", type=int, help="Override n_transactions")
    args = parser.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    Faker.seed(args.seed)
    fake = Faker(["fr_FR", "en_GB", "de_DE"])

    preset = SCALE_PRESETS[args.scale].copy()
    if args.tenants:      preset["n_tenants"] = args.tenants
    if args.comptes:      preset["n_comptes"] = args.comptes
    if args.transactions: preset["n_transactions"] = args.transactions

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("FinTrack Perf & Scale — Génération de données")
    print("=" * 60)
    print(f"Scale         : {args.scale}")
    print(f"Tenants       : {preset['n_tenants']:>15,}")
    print(f"Comptes       : {preset['n_comptes']:>15,}")
    print(f"Transactions  : {preset['n_transactions']:>15,}")
    print(f"Virements     : {preset['n_comptes'] // 10:>15,}")
    print(f"Periode faits : {PERIODE_DEBUT.date()} -> {PERIODE_FIN.date()}")
    print(f"Output        : {output_dir}")
    print(f"Seed          : {args.seed}")
    print("=" * 60)

    start = datetime.now()

    print("\n[1/7] Tenants ...")
    tenant_ids = generate_tenants(preset["n_tenants"], output_dir)

    print("\n[2/7] Catégories (hiérarchie 3 niveaux) ...")
    categories_ids = generate_categories(output_dir)

    print("\n[3/7] Taux FX ...")
    fx = generate_fx_rates(output_dir)

    print("\n[4/7] Comptes ...")
    comptes = generate_comptes(preset["n_comptes"], tenant_ids, output_dir, fake)

    print("\n[5/7] Titulaires et comptes joints ...")
    generate_titulaires(comptes, output_dir, fake)

    print("\n[6/7] Transactions ...")
    generate_transactions(preset["n_transactions"], comptes, output_dir,
                          fake, fx, categories_ids)

    print("\n[7/7] Virements ...")
    generate_virements(preset["n_comptes"] // 10, comptes, output_dir, fake)

    duration = datetime.now() - start
    print("\n" + "=" * 60)
    print(f"✓ Génération terminée en {duration}")
    print(f"  Fichiers dans : {output_dir.resolve()}")
    print("=" * 60)
    print("\nProchaine étape : charger dans Snowflake via les scripts")
    print("  scripts/snowflake/03_stage_and_copy_split.sql")


if __name__ == "__main__":
    main()
