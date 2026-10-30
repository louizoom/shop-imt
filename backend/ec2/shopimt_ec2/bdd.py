"""Accès à Amazon RDS for MySQL : schéma, catalogue initial, commandes et historique.

Le mot de passe n'est ni dans le code ni dans le user_data : l'instance le lit dans SSM Parameter Store
(SecureString chiffré par KMS) grâce à son rôle IAM. La connexion à RDS est chiffrée (TLS, certificat vérifié).
"""
import functools
import json

import boto3
import pymysql
from pymysql.cursors import DictCursor

from . import config

CATALOGUE = [
    ("p001", "T-shirt IMT", "IMT T-shirt", "19.90", 50),
    ("p002", "Sweat à capuche", "Hoodie", "39.90", 30),
    ("p003", "Mug cloud", "Cloud mug", "9.50", 100),
    ("p004", "Casquette", "Cap", "14.00", 40),
    ("p005", "Carnet de notes", "Notebook", "6.90", 80),
    ("p006", "Gourde inox (série limitée)", "Stainless steel bottle (limited edition)", "17.50", 5),
]

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS produits (
         id VARCHAR(16) PRIMARY KEY,
         nom VARCHAR(120) NOT NULL,
         nom_en VARCHAR(120),
         prix DECIMAL(8,2) NOT NULL,
         stock INT NOT NULL,
         CONSTRAINT stock_positif CHECK (stock >= 0))""",
    """CREATE TABLE IF NOT EXISTS commandes (
         numero INT AUTO_INCREMENT PRIMARY KEY,
         order_id VARCHAR(32) UNIQUE,
         client_email VARCHAR(254) NOT NULL,
         langue CHAR(2) NOT NULL DEFAULT 'fr',
         total DECIMAL(10,2) NOT NULL,
         statut VARCHAR(24) NOT NULL,
         articles JSON NOT NULL,
         transporteur VARCHAR(40),
         numero_suivi VARCHAR(40),
         cree_le DATETIME NOT NULL,
         livraison_estimee DATE,
         INDEX par_jour (cree_le))""",
    """CREATE TABLE IF NOT EXISTS historique (
         id INT AUTO_INCREMENT PRIMARY KEY,
         order_id VARCHAR(32) NOT NULL,
         horodatage DATETIME NOT NULL,
         statut VARCHAR(24) NOT NULL,
         detail VARCHAR(200) NOT NULL,
         INDEX par_commande (order_id, id))""",
]


@functools.cache
def _mot_de_passe():
    if config.BDD_MOT_DE_PASSE:
        return config.BDD_MOT_DE_PASSE
    ssm = boto3.client("ssm", region_name=config.REGION)
    return ssm.get_parameter(Name=config.BDD_PARAMETRE, WithDecryption=True)["Parameter"]["Value"]


def connexion():
    return pymysql.connect(
        host=config.BDD_HOTE, port=config.BDD_PORT, user=config.BDD_UTILISATEUR, password=_mot_de_passe(),
        database=config.BDD_NOM, charset="utf8mb4", cursorclass=DictCursor, autocommit=False,
        connect_timeout=5, ssl={"ca": config.BDD_CA} if config.BDD_CA else None,
    )


def initialiser():
    """Crée les tables et le catalogue s'ils n'existent pas (plusieurs serveurs peuvent le faire en même temps)."""
    with connexion() as c, c.cursor() as cur:
        for requete in SCHEMA:
            cur.execute(requete)
        cur.executemany("INSERT IGNORE INTO produits (id, nom, nom_en, prix, stock) VALUES (%s, %s, %s, %s, %s)", CATALOGUE)
        c.commit()


def lire_commande(cur, order_id):
    cur.execute("SELECT * FROM commandes WHERE order_id = %s", (order_id,))
    c = cur.fetchone()
    if c is None:
        return None
    cur.execute("SELECT horodatage, statut, detail FROM historique WHERE order_id = %s ORDER BY id", (order_id,))
    c["historique"] = [f"{h['horodatage'].isoformat()}+00:00 {h['statut']} | {h['detail']}" for h in cur.fetchall()]
    c["articles"] = json.loads(c["articles"]) if isinstance(c["articles"], str) else c["articles"]
    return c


def ajouter_etape(cur, order_id, statut, detail, horodatage):
    cur.execute("UPDATE commandes SET statut = %s WHERE order_id = %s", (statut, order_id))
    cur.execute("INSERT INTO historique (order_id, horodatage, statut, detail) VALUES (%s, %s, %s, %s)",
                (order_id, horodatage, statut, detail))
