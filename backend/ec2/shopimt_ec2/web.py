"""Serveur web de la solution EC2 (gunicorn, port 8080, derrière l'Application Load Balancer).

Sert le même front Vue que la solution serverless et la même API :
  GET /produits, POST /commandes, GET /commandes/<id>, GET /commandes/<id>/agenda, GET /sante (ALB).
Les comptes Cognito et la console de gestion restent propres à la solution serverless : sans config.json,
le front affiche la boutique sans comptes.

Création d'une commande : transaction MySQL (verrou des lignes produits, stock, commande, historique), puis
événement COMMANDE_CREEE sur SNS (traitement) et sur Kafka (flux du cycle de vie).
"""
import datetime
import json
import logging
import os
import secrets
from decimal import Decimal

from flask import Flask, Response, request, send_from_directory

from . import bdd, config, evenements
from .metier import commandes

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("shopimt.web")
logging.getLogger("kafka").setLevel(logging.WARNING)  # client Kafka très bavard en INFO
app = Flask(__name__, static_folder=None)


def _json(code, corps):
    return Response(json.dumps(corps, ensure_ascii=False, default=str), status=code, mimetype="application/json")


@app.get("/sante")
def sante():
    """Contrôle de santé de l'ALB : une instance qui n'atteint plus RDS est retirée du groupe cible."""
    try:
        with bdd.connexion() as c, c.cursor() as cur:
            cur.execute("SELECT 1")
        return _json(200, {"etat": "ok", "instance": os.environ.get("INSTANCE_ID", "")})
    except Exception as e:
        return _json(503, {"etat": "bdd indisponible", "erreur": str(e)})


@app.get("/produits")
def produits():
    with bdd.connexion() as c, c.cursor() as cur:
        cur.execute("SELECT id, nom, nom_en, prix, stock FROM produits ORDER BY id")
        lignes = cur.fetchall()
    return _json(200, [{**p, "prix": float(p["prix"])} for p in lignes])


@app.post("/commandes")
def creer():
    try:
        email, quantites, langue = commandes._valider({"body": request.get_data(as_text=True)})
    except ValueError as e:
        return _json(400, {"erreur": str(e)})

    maintenant = datetime.datetime.now(datetime.UTC).replace(microsecond=0)
    livraison = commandes.livraison_estimee(maintenant.date())
    with bdd.connexion() as c, c.cursor() as cur:
        marqueurs = ", ".join(["%s"] * len(quantites))
        # SELECT ... FOR UPDATE : deux commandes simultanées du même produit (sur deux serveurs) s'attendent
        cur.execute(f"SELECT id, nom, nom_en, prix, stock FROM produits WHERE id IN ({marqueurs}) ORDER BY id FOR UPDATE",
                    tuple(sorted(quantites)))
        trouves = {p["id"]: p for p in cur.fetchall()}
        inconnus = sorted(set(quantites) - set(trouves))
        if inconnus:
            c.rollback()
            return _json(400, {"erreur": "produit inconnu", "produits": inconnus})
        if any(trouves[pid]["stock"] < q for pid, q in quantites.items()):
            c.rollback()
            return _json(409, {"erreur": "stock insuffisant"})

        lignes, total = [], Decimal("0")
        for pid, q in sorted(quantites.items()):
            p = trouves[pid]
            lignes.append({"id": pid, "nom": p["nom"], "nom_en": p["nom_en"] or p["nom"], "quantite": q,
                           "prix_unitaire": f"{p['prix']:.2f}"})
            total += p["prix"] * q
            cur.execute("UPDATE produits SET stock = stock - %s WHERE id = %s", (q, pid))

        cur.execute("INSERT INTO commandes (client_email, langue, total, statut, articles, cree_le, livraison_estimee) "
                    "VALUES (%s, %s, %s, 'RECUE', %s, %s, %s)",
                    (email, langue, total, json.dumps(lignes, ensure_ascii=False), maintenant.replace(tzinfo=None), livraison))
        # Numéro lisible tiré de la clé AUTO_INCREMENT de MySQL (le compteur DynamoDB côté serverless)
        order_id = f"SHOP-{cur.lastrowid:06d}-" + "".join(secrets.choice(commandes.ALPHABET) for _ in range(4))
        cur.execute("UPDATE commandes SET order_id = %s WHERE numero = %s", (order_id, cur.lastrowid))
        bdd.ajouter_etape(cur, order_id, "RECUE", "Commande enregistrée et stock réservé", maintenant.replace(tzinfo=None))
        c.commit()

    evenement = {"type": "COMMANDE_CREEE", "order_id": order_id, "client_email": email, "langue": langue,
                 "total": f"{total:.2f}", "articles": lignes, "livraison_estimee": livraison,
                 "cree_le": maintenant.isoformat()}
    try:
        evenements.publier_sns(evenement)
    except Exception as e:  # la commande est enregistrée : le serveur de traitement la rattrapera (balayage RDS)
        log.error(json.dumps({"evenement": "SNS_ECHEC", "order_id": order_id, "erreur": str(e)}))
    evenements.publier_kafka(evenement)
    log.info(json.dumps({"evenement": "COMMANDE_CREEE", "order_id": order_id, "total": f"{total:.2f}"}))
    return _json(201, {"order_id": order_id, "statut": "RECUE", "total": f"{total:.2f}", "articles": lignes,
                       "message": "Commande enregistrée, un e-mail de confirmation va vous être envoyé."})


def _commande(order_id):
    if not commandes.identifiant_valide(order_id):
        return None, _json(400, {"erreur": "identifiant invalide"})
    with bdd.connexion() as c, c.cursor() as cur:
        commande = bdd.lire_commande(cur, order_id)
    if commande is None:
        return None, _json(404, {"erreur": "commande introuvable"})
    return commande, None


@app.get("/commandes/<order_id>")
def lire(order_id):
    c, erreur = _commande(order_id)
    if erreur:
        return erreur
    return _json(200, {
        "order_id": c["order_id"], "statut": c["statut"], "total": f"{c['total']:.2f}", "articles": c["articles"],
        "historique": c["historique"], "transporteur": c["transporteur"], "numero_suivi": c["numero_suivi"],
        "cree_le": c["cree_le"].isoformat() + "+00:00",
        "livraison_estimee": c["livraison_estimee"].isoformat() if c["livraison_estimee"] else None,
    })


@app.get("/commandes/<order_id>/agenda")
def agenda(order_id):
    c, erreur = _commande(order_id)
    if erreur:
        return erreur
    r = commandes.reponse_agenda(order_id, c["livraison_estimee"], c["articles"], c["total"])
    return Response(r["body"], status=r["statusCode"], headers=r["headers"])


@app.get("/")
@app.get("/<path:chemin>")
def site(chemin="index.html"):
    """Fichiers du front ; toute autre page (/suivi/…, /compte) renvoie index.html, le routeur Vue prend le relais."""
    fichier = os.path.join(config.DOSSIER_SITE, chemin)
    if chemin != "index.html" and os.path.isfile(fichier):
        r = send_from_directory(config.DOSSIER_SITE, chemin)
        if chemin.startswith("assets/"):  # noms avec empreinte (Vite) : cache long dans CloudFront
            r.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        return r
    if chemin == "config.json":  # pas de comptes Cognito dans cette solution
        return _json(404, {"erreur": "introuvable"})
    r = send_from_directory(config.DOSSIER_SITE, "index.html")
    r.headers["Cache-Control"] = "no-cache"
    return r


@app.after_request
def entetes(r):
    r.headers.setdefault("X-Content-Type-Options", "nosniff")
    r.headers["X-Servi-Par"] = os.environ.get("INSTANCE_ID", "local")  # démonstration de la répartition de charge
    return r
