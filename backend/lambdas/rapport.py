"""Récap quotidien des ventes, envoyé par e-mail aux administrateurs.

Déclenché chaque soir par Amazon EventBridge Scheduler (fuseau Europe/Paris).
  1. commandes du jour : index par-jour de la table commandes (Query, jamais de Scan)
  2. stocks bas : table produits (6 articles, Scan)
  3. e-mail HTML via SES aux adresses de la variable Terraform « admins »
"""
import datetime
import html
import json
import os
from collections import Counter
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeDeserializer

ddb = boto3.client("dynamodb")
ses = boto3.client("sesv2")

T_COMMANDES = os.environ["TABLE_COMMANDES"]
T_PRODUITS = os.environ["TABLE_PRODUITS"]
EXPEDITEUR = os.environ.get("EXPEDITEUR", "")
DESTINATAIRES = [a for a in os.environ.get("DESTINATAIRES", "").split(",") if a]
SITE_URL = os.environ.get("SITE_URL", "")
SEUIL_STOCK = int(os.environ.get("SEUIL_STOCK", "5"))
_deser = TypeDeserializer()

ROUGE, NOIR, CARTE, TEXTE, DOUX = "#ff2e45", "#090405", "#13090b", "#f6e8ea", "#a8878c"
POLICE = "Helvetica, Arial, sans-serif"


def _euros(v):
    return f"{Decimal(v):,.2f} €".replace(",", " ").replace(".", ",")


def _commandes(jour):
    items, cle = [], None
    while True:
        params = {"TableName": T_COMMANDES, "IndexName": "par-jour",
                  "KeyConditionExpression": "jour = :j", "ExpressionAttributeValues": {":j": {"S": jour}}}
        if cle:
            params["ExclusiveStartKey"] = cle
        resp = ddb.query(**params)
        items += [{k: _deser.deserialize(v) for k, v in i.items()} for i in resp.get("Items", [])]
        cle = resp.get("LastEvaluatedKey")
        if not cle:
            return items


def _stocks_bas():
    produits = [{k: _deser.deserialize(v) for k, v in i.items()} for i in ddb.scan(TableName=T_PRODUITS)["Items"]]
    return sorted(((p["nom"], int(p["stock"])) for p in produits if int(p["stock"]) <= SEUIL_STOCK), key=lambda p: p[1])


def resume(jour, commandes, stocks):
    ca = sum((Decimal(c["total"]) for c in commandes), Decimal("0"))
    ventes = Counter()
    for c in commandes:
        for a in json.loads(c["articles"]):
            ventes[a["nom"]] += a["quantite"]
    return {
        "jour": jour,
        "commandes": len(commandes),
        "chiffre_affaires": f"{ca:.2f}",
        "panier_moyen": f"{(ca / len(commandes)) if commandes else 0:.2f}",
        "clients": len({c["client_email"] for c in commandes}),
        "top": ventes.most_common(3),
        "stocks_bas": stocks,
    }


def construire_email(r):
    date = datetime.date.fromisoformat(r["jour"]).strftime("%d/%m/%Y")
    sujet = f"SHOP'IMT - Récap du {date} : {r['commandes']} commande(s), {_euros(r['chiffre_affaires'])}"
    tuile = lambda titre, valeur: (  # noqa: E731
        f'<td style="padding:6px;"><div style="background:{CARTE};border:1px solid #36161c;border-radius:12px;padding:14px;">'
        f'<div style="font-size:11px;letter-spacing:2px;color:{DOUX};text-transform:uppercase;">{titre}</div>'
        f'<div style="font-size:22px;font-weight:700;color:{TEXTE};margin-top:6px;">{valeur}</div></div></td>')
    top = "".join(f'<li style="margin:4px 0;">{html.escape(n)} : {q}</li>' for n, q in r["top"]) or "<li>Aucune vente aujourd'hui.</li>"
    if r["stocks_bas"]:
        alertes = "".join(f'<li style="margin:4px 0;"><b style="color:{ROUGE};">{s}</b> restant(s) : {html.escape(n)}</li>' for n, s in r["stocks_bas"])
        bloc_stock = f'<h3 style="color:{ROUGE};font-size:13px;letter-spacing:2px;text-transform:uppercase;">Stocks bas</h3><ul style="padding-left:18px;color:{TEXTE};">{alertes}</ul>'
    else:
        bloc_stock = f'<p style="color:{DOUX};">Aucun stock sous {SEUIL_STOCK} unités.</p>'
    corps = f"""<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>{html.escape(sujet)}</title></head>
<body style="margin:0;background:{NOIR};font-family:{POLICE};color:{TEXTE};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;">
<tr><td style="padding:8px 6px 18px;">
  <div style="font-size:11px;letter-spacing:3px;color:{ROUGE};text-transform:uppercase;font-weight:700;">Console administrateur</div>
  <div style="font-size:26px;font-weight:700;margin-top:6px;">Récap du {date}</div>
</td></tr>
<tr><td><table role="presentation" width="100%"><tr>{tuile("Commandes", r["commandes"])}{tuile("Chiffre d'affaires", _euros(r["chiffre_affaires"]))}</tr>
<tr>{tuile("Panier moyen", _euros(r["panier_moyen"]))}{tuile("Clients", r["clients"])}</tr></table></td></tr>
<tr><td style="padding:12px 6px;">
  <h3 style="color:{DOUX};font-size:13px;letter-spacing:2px;text-transform:uppercase;">Meilleures ventes</h3>
  <ul style="padding-left:18px;color:{TEXTE};">{top}</ul>
  {bloc_stock}
  <p style="margin-top:24px;"><a href="{SITE_URL}/admin" style="background:{ROUGE};color:#fff;text-decoration:none;font-weight:700;padding:12px 20px;border-radius:999px;display:inline-block;">Ouvrir la console admin</a></p>
</td></tr>
<tr><td style="padding:16px 6px;font-size:11px;color:{DOUX};">Envoyé chaque soir par Amazon EventBridge Scheduler aux administrateurs SHOP'IMT.</td></tr>
</table></td></tr></table></body></html>"""
    texte = (f"Récap SHOP'IMT du {date}\nCommandes : {r['commandes']}\nChiffre d'affaires : {_euros(r['chiffre_affaires'])}\n"
             f"Panier moyen : {_euros(r['panier_moyen'])}\nStocks bas : "
             + (", ".join(f"{n} ({s})" for n, s in r["stocks_bas"]) or "aucun") + f"\n{SITE_URL}/admin")
    return sujet, corps, texte


def handler(event, context):
    jour = (event or {}).get("jour") or datetime.datetime.now(datetime.UTC).date().isoformat()
    r = resume(jour, _commandes(jour), _stocks_bas())
    sujet, corps, texte = construire_email(r)
    envoyes = []
    for dest in DESTINATAIRES:
        try:
            ses.send_email(FromEmailAddress=f"SHOP'IMT Admin <{EXPEDITEUR}>", Destination={"ToAddresses": [dest]},
                           Content={"Simple": {"Subject": {"Data": sujet, "Charset": "UTF-8"},
                                               "Body": {"Html": {"Data": corps, "Charset": "UTF-8"},
                                                        "Text": {"Data": texte, "Charset": "UTF-8"}}}})
            envoyes.append(dest)
        except Exception as e:  # une adresse refusée (sandbox SES) ne bloque pas les autres
            print(json.dumps({"evenement": "RAPPORT_REFUSE", "destinataire": dest, "erreur": str(e)}))
    print(json.dumps({"evenement": "RAPPORT_ENVOYE", "jour": jour, "commandes": r["commandes"], "destinataires": len(envoyes)}))
    return {"jour": jour, "commandes": r["commandes"], "chiffre_affaires": r["chiffre_affaires"], "envoyes": len(envoyes)}
