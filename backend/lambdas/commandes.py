"""POST /commandes : crée une commande ; GET /commandes/{id} : suivi de statut.
POST /compte/commandes et GET /compte/commandes : mêmes actions pour un client connecté
(jeton Cognito vérifié par l'autorisateur JWT d'API Gateway avant d'arriver ici).

Création :
  1. validation de la requête
  2. lecture des produits (prix côté serveur, jamais celui envoyé par le client)
  3. transaction DynamoDB : décrément du stock (conditionnel) + écriture de la commande
La publication sur SNS est faite par la Lambda publication, déclenchée par DynamoDB Streams
(pattern outbox) : pas d'écriture en base sans événement, ni d'événement sans écriture.
"""
import datetime
import json
import os
import re
import secrets
import uuid
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

ddb = boto3.client("dynamodb")

T_PRODUITS = os.environ["TABLE_PRODUITS"]
T_COMMANDES = os.environ["TABLE_COMMANDES"]

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
# Numéro de commande lisible : SHOP-000042-K7QF. Le nombre vient d'un compteur atomique DynamoDB
# (ligne « #compteur » de la table commandes, UpdateItem ADD) ; les 4 caractères aléatoires empêchent
# de deviner la commande d'un autre client en incrémentant le numéro (la page de suivi est publique).
COMPTEUR = "#compteur"
ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"  # sans 0/O ni 1/I/L, faciles à confondre
ID_RE = re.compile(r"^SHOP-\d{6,}-[2-9A-HJKMNP-Z]{4}$")
MAX_LIGNES = 10
MAX_QUANTITE = 20
_deser = TypeDeserializer()


def _rep(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _client(event):
    """(sub, email) du client connecté, d'après les claims du jeton déjà vérifié par API Gateway."""
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    return claims["sub"], claims["email"].lower()


def handler(event, context):
    route = event.get("routeKey")
    if route == "POST /commandes":
        return creer(event)
    if route == "GET /commandes/{id}":
        return lire((event.get("pathParameters") or {}).get("id", ""))
    if route == "GET /commandes/{id}/agenda":
        return agenda((event.get("pathParameters") or {}).get("id", ""))
    if route == "POST /compte/commandes":
        sub, email = _client(event)
        return creer(event, client=(sub, email))
    if route == "GET /compte/commandes":
        return lister(_client(event)[0])
    return _rep(404, {"erreur": "route inconnue"})


def _valider(event, email_impose=None):
    """Renvoie (email, {id_produit: quantite}, langue) ou lève ValueError."""
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        raise ValueError("corps JSON invalide") from None
    if not isinstance(body, dict):
        raise ValueError("corps JSON invalide") from None

    email = email_impose or str(body.get("client_email", "")).strip().lower()
    if not EMAIL_RE.match(email) or len(email) > 254:
        raise ValueError("client_email invalide")

    articles = body.get("articles")
    if not isinstance(articles, list) or not 1 <= len(articles) <= MAX_LIGNES:
        raise ValueError(f"articles doit contenir 1 à {MAX_LIGNES} lignes")

    quantites = {}
    for a in articles:
        try:
            pid, q = str(a["id"]), int(a["quantite"])
        except (KeyError, TypeError, ValueError):
            raise ValueError("chaque article doit avoir un id et une quantite entière") from None
        if not 1 <= q <= MAX_QUANTITE:
            raise ValueError(f"quantite entre 1 et {MAX_QUANTITE}")
        quantites[pid] = quantites.get(pid, 0) + q
    if any(q > MAX_QUANTITE for q in quantites.values()):
        raise ValueError(f"quantite entre 1 et {MAX_QUANTITE}")
    langue = "en" if body.get("langue") == "en" else "fr"   # langue des e-mails envoyés au client
    return email, quantites, langue


def creer(event, client=None):
    try:
        email, quantites, langue = _valider(event, email_impose=client and client[1])
    except ValueError as e:
        return _rep(400, {"erreur": str(e)})

    resp = ddb.batch_get_item(
        RequestItems={T_PRODUITS: {"Keys": [{"id": {"S": pid}} for pid in quantites]}}
    )
    produits = {i["id"]["S"]: i for i in resp["Responses"].get(T_PRODUITS, [])}
    inconnus = sorted(set(quantites) - set(produits))
    if inconnus:
        return _rep(400, {"erreur": "produit inconnu", "produits": inconnus})

    lignes, total = [], Decimal("0")
    for pid, q in sorted(quantites.items()):
        prix = Decimal(produits[pid]["prix"]["N"])
        ligne = {"id": pid, "nom": produits[pid]["nom"]["S"], "quantite": q, "prix_unitaire": f"{prix:.2f}"}
        if "nom_en" in produits[pid]:
            ligne["nom_en"] = produits[pid]["nom_en"]["S"]
        lignes.append(ligne)
        total += prix * q
    total_str = f"{total:.2f}"

    order_id = nouvel_identifiant()
    maintenant = datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds")

    transaction = [
        {"Update": {
            "TableName": T_PRODUITS,
            "Key": {"id": {"S": pid}},
            "UpdateExpression": "SET stock = stock - :q",
            "ConditionExpression": "stock >= :q",
            "ExpressionAttributeValues": {":q": {"N": str(q)}},
        }}
        for pid, q in quantites.items()
    ]
    commande = {
        "order_id": {"S": order_id},
        "client_email": {"S": email},
        "articles": {"S": json.dumps(lignes, ensure_ascii=False)},
        "total": {"N": total_str},
        "statut": {"S": "RECUE"},
        "langue": {"S": langue},
        "cree_le": {"S": maintenant},
        "jour": {"S": maintenant[:10]},   # clé de l'index par-jour (interface admin)
        "livraison_estimee": {"S": livraison_estimee(datetime.date.fromisoformat(maintenant[:10]))},
        "historique": {"L": [{"S": f"{maintenant} RECUE | Commande enregistrée et stock réservé"}]},
    }
    if client:  # rattache la commande au compte : visible dans « Mes commandes » (index par-client)
        commande["client_sub"] = {"S": client[0]}
    transaction.append({"Put": {
        "TableName": T_COMMANDES,
        "Item": commande,
        "ConditionExpression": "attribute_not_exists(order_id)",
    }})

    try:
        ddb.transact_write_items(TransactItems=transaction)
    except ClientError as e:
        if e.response["Error"]["Code"] == "TransactionCanceledException":
            return _rep(409, {"erreur": "stock insuffisant"})
        raise

    return _rep(201, {
        "order_id": order_id,
        "statut": "RECUE",
        "total": total_str,
        "articles": lignes,
        "message": "Commande enregistrée, un e-mail de confirmation va vous être envoyé.",
    })


def nouvel_identifiant():
    r = ddb.update_item(
        TableName=T_COMMANDES,
        Key={"order_id": {"S": COMPTEUR}},
        UpdateExpression="ADD valeur :un",
        ExpressionAttributeValues={":un": {"N": "1"}},
        ReturnValues="UPDATED_NEW",
    )
    n = int(r["Attributes"]["valeur"]["N"])
    return f"SHOP-{n:06d}-" + "".join(secrets.choice(ALPHABET) for _ in range(4))


def identifiant_valide(order_id):
    """Nouveau format SHOP-…, ou UUID des commandes passées avant le changement de format."""
    if ID_RE.match(order_id):
        return True
    try:
        uuid.UUID(order_id)
        return True
    except ValueError:
        return False


def numero_court(order_id):
    """SHOP-000042 pour l'affichage (sans le code de contrôle) ; 8 caractères pour un ancien UUID."""
    return order_id.rsplit("-", 1)[0] if order_id.startswith("SHOP-") else order_id[:8]


def livraison_estimee(date, jours_ouvres=3):
    """Date de livraison annoncée au client : 3 jours ouvrés après la commande (week-end exclu)."""
    while jours_ouvres:
        date += datetime.timedelta(days=1)
        if date.weekday() < 5:
            jours_ouvres -= 1
    return date.isoformat()


def lire(order_id):
    if not identifiant_valide(order_id):
        return _rep(400, {"erreur": "identifiant invalide"})

    item = ddb.get_item(TableName=T_COMMANDES, Key={"order_id": {"S": order_id}}).get("Item")
    if not item:
        return _rep(404, {"erreur": "commande introuvable"})

    c = {k: _deser.deserialize(v) for k, v in item.items()}
    return _rep(200, {
        "order_id": c["order_id"],
        "statut": c["statut"],
        "total": f"{Decimal(c['total']):.2f}",
        "articles": json.loads(c["articles"]),
        "historique": c.get("historique", []),
        "transporteur": c.get("transporteur"),
        "numero_suivi": c.get("numero_suivi"),
        "cree_le": c["cree_le"],
        "livraison_estimee": c.get("livraison_estimee"),
    })


def _ics_texte(s):
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def agenda(order_id):
    """GET /commandes/{id}/agenda : la livraison estimée en événement d'agenda (.ics, RFC 5545).
    Sur iPhone, Safari propose directement « Ajouter au calendrier » ; ailleurs le fichier s'ouvre
    dans Outlook, Apple Calendrier ou Thunderbird. Google Agenda passe par un lien dédié (front)."""
    if not identifiant_valide(order_id):
        return _rep(400, {"erreur": "identifiant invalide"})
    item = ddb.get_item(TableName=T_COMMANDES, Key={"order_id": {"S": order_id}}).get("Item")
    if not item or "livraison_estimee" not in item:
        return _rep(404, {"erreur": "commande introuvable"})
    c = {k: _deser.deserialize(v) for k, v in item.items()}
    return reponse_agenda(order_id, c["livraison_estimee"], json.loads(c["articles"]), c["total"])


def reponse_agenda(order_id, livraison_estimee, articles, total):
    """Réponse .ics commune aux deux solutions (Lambda ici, serveur web de la solution EC2)."""
    jour = datetime.date.fromisoformat(str(livraison_estimee))
    articles = ", ".join(f"{a['quantite']} x {a['nom']}" for a in articles)
    lignes = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//SHOP'IMT//Livraison//FR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
        "BEGIN:VEVENT",
        f"UID:{order_id}@shop-imt",
        "DTSTAMP:" + datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ"),
        f"DTSTART;VALUE=DATE:{jour:%Y%m%d}",
        f"DTEND;VALUE=DATE:{jour + datetime.timedelta(days=1):%Y%m%d}",
        "SUMMARY:" + _ics_texte("Livraison SHOP'IMT"),
        "DESCRIPTION:" + _ics_texte(f"Commande {order_id}\n{articles}\nTotal : {Decimal(total):.2f} EUR"),
        "TRANSP:TRANSPARENT",
        "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + _ics_texte("Votre colis SHOP'IMT arrive aujourd'hui"),
        "TRIGGER:PT9H", "END:VALARM",   # rappel le jour même à 9 h
        "END:VEVENT", "END:VCALENDAR",
    ]
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/calendar; charset=utf-8",
                    "Content-Disposition": f'inline; filename="livraison-{numero_court(order_id).lower()}.ics"',
                    "Cache-Control": "max-age=300"},
        "body": "\r\n".join(lignes) + "\r\n",
    }


def lister(sub):
    """Historique du client connecté, du plus récent au plus ancien (index secondaire par-client)."""
    resp = ddb.query(
        TableName=T_COMMANDES,
        IndexName="par-client",
        KeyConditionExpression="client_sub = :s",
        ExpressionAttributeValues={":s": {"S": sub}},
        ScanIndexForward=False,
        Limit=50,
    )
    commandes = []
    for item in resp.get("Items", []):
        c = {k: _deser.deserialize(v) for k, v in item.items()}
        articles = json.loads(c["articles"])
        commandes.append({
            "order_id": c["order_id"],
            "statut": c["statut"],
            "total": f"{Decimal(c['total']):.2f}",
            "nb_articles": sum(a["quantite"] for a in articles),
            "articles": articles,
            "transporteur": c.get("transporteur"),
            "cree_le": c["cree_le"],
        })
    return _rep(200, {"commandes": commandes})
