"""Réglages lus dans l'environnement (fichier /etc/shopimt/env écrit par le user_data de l'instance)."""
import os

REGION = os.environ.get("AWS_REGION", "eu-west-3")
BDD_HOTE = os.environ.get("BDD_HOTE", "127.0.0.1")
BDD_PORT = int(os.environ.get("BDD_PORT", "3306"))
BDD_NOM = os.environ.get("BDD_NOM", "boutique")
BDD_UTILISATEUR = os.environ.get("BDD_UTILISATEUR", "shopimt")
BDD_PARAMETRE = os.environ.get("BDD_PARAMETRE", "")       # paramètre SSM SecureString du mot de passe
BDD_MOT_DE_PASSE = os.environ.get("BDD_MOT_DE_PASSE", "")  # tests locaux seulement
BDD_CA = os.environ.get("BDD_CA", "")                      # bundle de certificats RDS : connexion TLS vérifiée
TOPIC_COMMANDES = os.environ.get("TOPIC_COMMANDES", "")
FILE_TRAITEMENT = os.environ.get("FILE_TRAITEMENT", "")
KAFKA = os.environ.get("KAFKA", "")                        # ex. 10.20.1.10:9092 ; vide = pas de streaming
TOPIC_KAFKA = os.environ.get("TOPIC_KAFKA", "commandes")
BUCKET_AUDIT = os.environ.get("BUCKET_AUDIT", "")
DOSSIER_SITE = os.environ.get("DOSSIER_SITE", "/opt/shopimt/site")
DELAI_MAX = int(os.environ.get("DELAI_MAX", "8"))
