"""Interface admin : GET /admin/stats et GET /admin/commandes (lecture seule).

Deux contrôles d'accès :
  1. API Gateway (autorisateur JWT Cognito) refuse toute requête sans jeton valide : 401.
  2. Cette Lambda vérifie que le jeton porte le groupe Cognito « admins » : sinon 403.

Lecture par l'index secondaire « par-jour » (une requête Query par jour, jamais de Scan).
Les statistiques sont calculées ici plutôt que lues dans CloudWatch : GetMetricData est
facturé dès le premier appel, une Query DynamoDB reste dans l'offre gratuite.

GET /admin/stock et POST /admin/stock : réassort du catalogue. Mise à jour atomique côté DynamoDB
(SET stock = stock + :delta) avec une condition qui interdit un stock négatif : deux admins qui
cliquent en même temps ne peuvent pas s'écraser.

GET /admin/export : fichier CSV déposé dans le bucket d'audit (exports/, supprimé après 1 jour)
et téléchargé par une URL S3 présignée valable 5 minutes. Le bucket reste privé.
"""
import base64
import csv
import datetime
import io
import json
import os
from collections import Counter, defaultdict
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

ddb = boto3.client("dynamodb")
s3 = boto3.client("s3")
T_COMMANDES = os.environ["TABLE_COMMANDES"]
T_PRODUITS = os.environ.get("TABLE_PRODUITS", "")
STOCK_MAX = 999
BUCKET_EXPORT = os.environ.get("BUCKET_EXPORT", "")
GROUPE_ADMIN = "admins"
JOURS_MAX = 90
_deser = TypeDeserializer()


def _rep(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _groupes(claims):
    """API Gateway HTTP transmet la liste des groupes sous forme de texte : "[admins autre]"."""
    brut = claims.get("cognito:groups", "")
    if isinstance(brut, list):
        return set(brut)
    return set(brut.strip("[]").replace(",", " ").split())


def _jours(n, aujourd_hui=None):
    fin = aujourd_hui or datetime.datetime.now(datetime.UTC).date()
    return [(fin - datetime.timedelta(days=i)).isoformat() for i in range(n - 1, -1, -1)]


def _commandes_du_jour(jour):
    items, cle = [], None
    while True:
        params = {
            "TableName": T_COMMANDES,
            "IndexName": "par-jour",
            "KeyConditionExpression": "jour = :j",
            "ExpressionAttributeValues": {":j": {"S": jour}},
            "ScanIndexForward": False,
        }
        if cle:
            params["ExclusiveStartKey"] = cle
        resp = ddb.query(**params)
        items += resp.get("Items", [])
        cle = resp.get("LastEvaluatedKey")
        if not cle:
            return items


def _charger(nb_jours):
    jours = _jours(nb_jours)
    commandes = []
    for jour in jours:
        for item in _commandes_du_jour(jour):
            c = {k: _deser.deserialize(v) for k, v in item.items()}
            commandes.append({
                "order_id": c["order_id"],
                "jour": c["jour"],
                "cree_le": c["cree_le"],
                "client_email": c["client_email"],
                "compte": "client_sub" in c,
                "statut": c["statut"],
                "total": Decimal(c["total"]),
                "articles": json.loads(c["articles"]),
            })
    commandes.sort(key=lambda c: c["cree_le"], reverse=True)
    return jours, commandes


def statistiques(jours, commandes):
    par_jour = {j: {"jour": j, "commandes": 0, "chiffre_affaires": Decimal("0")} for j in jours}
    produits = defaultdict(lambda: {"quantite": 0, "chiffre_affaires": Decimal("0")})
    for c in commandes:
        par_jour[c["jour"]]["commandes"] += 1
        par_jour[c["jour"]]["chiffre_affaires"] += c["total"]
        for a in c["articles"]:
            p = produits[a["nom"]]
            p["quantite"] += a["quantite"]
            p["chiffre_affaires"] += Decimal(a["prix_unitaire"]) * a["quantite"]

    ca = sum((c["total"] for c in commandes), Decimal("0"))
    clients = {c["client_email"] for c in commandes}
    sept = set(jours[-7:])
    return {
        "periode_jours": len(jours),
        "commandes": len(commandes),
        "commandes_aujourdhui": par_jour[jours[-1]]["commandes"],
        "commandes_7_jours": sum(1 for c in commandes if c["jour"] in sept),
        "chiffre_affaires": f"{ca:.2f}",
        "panier_moyen": f"{(ca / len(commandes)) if commandes else 0:.2f}",
        "clients_uniques": len(clients),
        "par_jour": [dict(v, chiffre_affaires=f"{v['chiffre_affaires']:.2f}") for v in par_jour.values()],
        "statuts": dict(Counter(c["statut"] for c in commandes)),
        "produits": sorted(
            ({"nom": n, "quantite": v["quantite"], "chiffre_affaires": f"{v['chiffre_affaires']:.2f}"} for n, v in produits.items()),
            key=lambda p: -p["quantite"],
        ),
    }


def _publique(c):
    return dict(c, total=f"{c['total']:.2f}", nb_articles=sum(a["quantite"] for a in c["articles"]))


def exporter(commandes, nb_jours):
    tampon = io.StringIO()
    w = csv.writer(tampon, delimiter=";")   # point-virgule : ouverture directe dans Excel en français
    w.writerow(["date", "commande", "client", "compte", "articles", "total_eur", "statut"])
    for c in commandes:
        w.writerow([c["cree_le"], c["order_id"], c["client_email"], "oui" if c["compte"] else "non",
                    " + ".join(f"{a['quantite']} x {a['nom']}" for a in c["articles"]),
                    f"{c['total']:.2f}".replace(".", ","), c["statut"]])
    horodatage = datetime.datetime.now(datetime.UTC).strftime("%Y%m%d-%H%M%S")
    nom = f"shopimt-commandes-{nb_jours}j-{horodatage}.csv"
    cle = f"exports/{nom}"
    s3.put_object(Bucket=BUCKET_EXPORT, Key=cle, Body=("\ufeff" + tampon.getvalue()).encode("utf-8"),
                  ContentType="text/csv; charset=utf-8")
    url = s3.generate_presigned_url("get_object", ExpiresIn=300, Params={
        "Bucket": BUCKET_EXPORT, "Key": cle, "ResponseContentDisposition": f'attachment; filename="{nom}"'})
    return {"url": url, "fichier": nom, "lignes": len(commandes)}


def lister_stock():
    items, cle = [], None
    while True:
        params = {"TableName": T_PRODUITS}
        if cle:
            params["ExclusiveStartKey"] = cle
        resp = ddb.scan(**params)
        items += resp.get("Items", [])
        cle = resp.get("LastEvaluatedKey")
        if not cle:
            break
    produits = [{k: _deser.deserialize(v) for k, v in i.items()} for i in items]
    return sorted(({"id": p["id"], "nom": p["nom"], "nom_en": p.get("nom_en"), "prix": f"{Decimal(p['prix']):.2f}", "stock": int(p["stock"])}
                   for p in produits), key=lambda p: p["id"])


def modifier_stock(corps, qui):
    try:
        produit = str(corps["id"])
        delta = int(corps["delta"])
    except (KeyError, TypeError, ValueError):
        return _rep(400, {"erreur": "id et delta (entier) sont obligatoires"})
    if delta == 0 or abs(delta) > 100:
        return _rep(400, {"erreur": "delta doit être compris entre -100 et 100, hors 0"})
    try:
        resp = ddb.update_item(
            TableName=T_PRODUITS,
            Key={"id": {"S": produit}},
            UpdateExpression="SET stock = stock + :d",
            ConditionExpression="attribute_exists(id) AND stock >= :min AND stock <= :max",
            ExpressionAttributeValues={":d": {"N": str(delta)}, ":min": {"N": str(max(0, -delta))},
                                       ":max": {"N": str(STOCK_MAX - max(0, delta))}},
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        return _rep(409, {"erreur": f"stock hors limites (0 à {STOCK_MAX}) ou produit inconnu"})
    stock = int(resp["Attributes"]["stock"]["N"])
    print(json.dumps({"evenement": "ADMIN_STOCK", "qui": qui, "produit": produit, "delta": delta, "stock": stock}))
    return _rep(200, {"id": produit, "stock": stock})


def _corps(event):
    brut = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        brut = base64.b64decode(brut).decode("utf-8")
    try:
        return json.loads(brut)
    except ValueError:
        return None


def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    qui = claims.get("email", claims.get("sub"))
    route = event.get("routeKey")
    if GROUPE_ADMIN not in _groupes(claims):
        print(json.dumps({"evenement": "ADMIN_REFUSE", "qui": qui, "route": route}))
        return _rep(403, {"erreur": "réservé aux administrateurs"})

    if route == "GET /admin/stock":
        return _rep(200, {"produits": lister_stock()})
    if route == "POST /admin/stock":
        corps = _corps(event)
        if not isinstance(corps, dict):
            return _rep(400, {"erreur": "corps JSON invalide"})
        return modifier_stock(corps, qui)

    params = event.get("queryStringParameters") or {}
    try:
        nb_jours = min(max(int(params.get("jours", 30)), 1), JOURS_MAX)
    except ValueError:
        return _rep(400, {"erreur": "jours doit être un entier"})

    jours, commandes = _charger(nb_jours)
    print(json.dumps({"evenement": "ADMIN_CONSULTATION", "qui": qui, "route": route, "jours": nb_jours}))

    if route == "GET /admin/stats":
        return _rep(200, statistiques(jours, commandes))
    if route == "GET /admin/export":
        return _rep(200, exporter(commandes, nb_jours))
    if route == "GET /admin/commandes":
        recherche = params.get("q", "").strip().lower()
        if recherche:
            commandes = [c for c in commandes if recherche in c["client_email"]]
        return _rep(200, {"commandes": [_publique(c) for c in commandes[:500]]})
    return _rep(404, {"erreur": "route inconnue"})
