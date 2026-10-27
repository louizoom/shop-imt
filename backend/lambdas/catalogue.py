"""GET /produits : renvoie le catalogue depuis DynamoDB.

Version anglaise des noms : Amazon Translate traduit chaque nom une seule fois (fr -> en),
puis le résultat est enregistré dans la table (attribut nom_en). Les appels suivants lisent
la traduction stockée : quelques dizaines de caractères traduits au total, coût nul en pratique.
Un nom_en saisi à la main dans la table est conservé tel quel.
"""
import json
import os
from decimal import Decimal

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_PRODUITS"])
translate = boto3.client("translate")


def _json(o):
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError(type(o))


def _traduire(produit):
    try:
        texte = translate.translate_text(Text=produit["nom"], SourceLanguageCode="fr", TargetLanguageCode="en")["TranslatedText"]
    except Exception as e:  # Translate indisponible : le site affiche le nom français
        print(json.dumps({"evenement": "TRADUCTION_ECHEC", "produit": produit["id"], "erreur": str(e)}))
        return produit["nom"]
    table.update_item(Key={"id": produit["id"]}, UpdateExpression="SET nom_en = :n",
                      ExpressionAttributeValues={":n": texte})
    print(json.dumps({"evenement": "TRADUCTION", "produit": produit["id"], "nom_en": texte}))
    return texte


def handler(event, context):
    produits = []
    kwargs = {}
    while True:  # le Scan est paginé à 1 Mo
        page = table.scan(**kwargs)
        produits.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    for p in produits:
        if not p.get("nom_en"):
            p["nom_en"] = _traduire(p)
    produits.sort(key=lambda p: p["id"])
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(produits, default=_json, ensure_ascii=False),
    }
