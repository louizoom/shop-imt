"""Consommateur DynamoDB Streams : publie chaque nouvelle commande sur SNS.

Pattern "transactional outbox" : la Lambda commandes n'écrit qu'en base ; c'est le flux
(streaming) de la table commandes qui déclenche la publication. Une commande enregistrée
est donc toujours publiée, même si SNS est indisponible au moment de l'écriture
(Lambda réessaie le lot, puis l'envoie en DLQ).
"""
import json
import os
import time

import boto3
from boto3.dynamodb.types import TypeDeserializer

sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]
SITE_URL = os.environ.get("SITE_URL", "")
METRIQUES_NS = os.environ.get("METRIQUES_NS", "SHOPIMT")
_deser = TypeDeserializer()



def numero_court(order_id):
    """SHOP-000042 (sans le code de contrôle) ; 8 caractères pour un ancien UUID."""
    return order_id.rsplit("-", 1)[0] if order_id.startswith("SHOP-") else order_id[:8]

def _evenement(image):
    c = {k: _deser.deserialize(v) for k, v in image.items()}
    return {
        "type": "COMMANDE_CREEE",
        "order_id": c["order_id"],
        "client_email": c["client_email"],
        "articles": json.loads(c["articles"]),
        "total": f"{c['total']:.2f}",
        "cree_le": c["cree_le"],
        "livraison_estimee": c.get("livraison_estimee"),
        "langue": c.get("langue", "fr"),
    }


def _publier(evenement):
    lignes = evenement["articles"]
    order_id = evenement["order_id"]
    detail = "\n".join(f"  - {ligne['quantite']} x {ligne['nom']} ({ligne['prix_unitaire']} €)" for ligne in lignes)
    texte_email = (
        f"Bonjour,\n\nVotre commande SHOP'IMT {order_id} a bien été enregistrée.\n\n"
        f"{detail}\n\nTotal : {evenement['total']} €\n\n"
        f"Suivez sa préparation et sa livraison en direct :\n{SITE_URL}/suivi/{order_id}\n\n"
        "Merci pour votre achat et à bientôt sur SHOP'IMT !"
    )

    # MessageStructure=json : les files SQS reçoivent l'événement JSON ("default"),
    # l'abonné e-mail reçoit le texte lisible ("email").
    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"SHOP'IMT - Confirmation de commande {numero_court(order_id)}",
        MessageStructure="json",
        Message=json.dumps({"default": json.dumps(evenement, ensure_ascii=False),
                            "email": texte_email}, ensure_ascii=False),
        MessageAttributes={
            "client_email": {"DataType": "String", "StringValue": evenement["client_email"]},
            "type": {"DataType": "String", "StringValue": "COMMANDE_CREEE"},
        },
    )


def _metriques(evenement):
    """Métriques métier au format EMF (Embedded Metric Format) : une simple ligne de journal,
    que CloudWatch transforme en métriques. Aucun appel d'API, donc rien à facturer à l'écriture."""
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": METRIQUES_NS,
                "Dimensions": [["Boutique"]],
                "Metrics": [{"Name": "Commandes", "Unit": "Count"}, {"Name": "ChiffreAffaires", "Unit": "None"}],
            }],
        },
        "Boutique": "SHOP'IMT",
        "Commandes": 1,
        "ChiffreAffaires": float(evenement["total"]),
    }))


def handler(event, context):
    echecs = []
    for record in event.get("Records", []):
        try:
            if record.get("eventName") != "INSERT":  # déjà filtré côté déclencheur, par sécurité
                continue
            evenement = _evenement(record["dynamodb"]["NewImage"])
            _publier(evenement)
            _metriques(evenement)
            print(json.dumps({"evenement": "COMMANDE_PUBLIEE", "order_id": evenement["order_id"]}))
        except Exception as e:
            print(json.dumps({"evenement": "ECHEC_PUBLICATION", "erreur": str(e)}))
            # Flux ordonné : on signale le premier échec, Lambda reprendra à partir de lui.
            echecs.append({"itemIdentifier": record["dynamodb"]["SequenceNumber"]})
            break
    return {"batchItemFailures": echecs}
