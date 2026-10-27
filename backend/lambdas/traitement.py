"""Consommateur SQS : lance la simulation des opérations internes d'une commande.

La Lambda tire au sort un transporteur, un numéro de suivi, la durée de chaque étape et
parfois un incident de transport, puis confie le déroulé à Step Functions (machine
"expedition") : les attentes se font dans Step Functions, la Lambda ne dort jamais.

RECUE -> EN_PREPARATION -> EMBALLEE -> EXPEDIEE [-> INCIDENT_TRANSPORT] -> EN_LIVRAISON -> LIVREE

Idempotent : l'exécution porte le nom de la commande, une relivraison SQS ne relance rien.
"""
import json
import os
import random
import uuid

import boto3
from botocore.exceptions import ClientError

ddb = boto3.client("dynamodb")
sfn = boto3.client("stepfunctions")
T_COMMANDES = os.environ["TABLE_COMMANDES"]
MACHINE = os.environ["STATE_MACHINE_ARN"]
DELAI_MAX = int(os.environ.get("DELAI_MAX", "8"))

TRANSPORTEURS = {"Colissimo": "6A", "Chronopost": "XY", "DPD": "DP", "Mondial Relay": "MR"}
INCIDENTS = [
    "Colis retardé au centre de tri",
    "Adresse à confirmer auprès du client",
    "Retard dû aux conditions météo",
]
PROBA_INCIDENT = 0.25


def _plan(rng):
    """Étapes à jouer, avec leur délai d'attente avant passage (en secondes).
    « notifier » : Step Functions envoie alors un e-mail au client (Lambda notification)."""
    d = lambda mini: rng.randint(mini, max(mini, DELAI_MAX))
    etapes = [
        {"statut": "EN_PREPARATION", "delai": d(1), "detail": "Articles prélevés en entrepôt"},
        {"statut": "EMBALLEE", "delai": d(2), "detail": "Colis emballé et étiqueté"},
        {"statut": "EXPEDIEE", "delai": d(2), "detail": "Colis remis au transporteur", "notifier": True},
    ]
    if rng.random() < PROBA_INCIDENT:
        etapes.append({"statut": "INCIDENT_TRANSPORT", "delai": d(2), "detail": rng.choice(INCIDENTS), "notifier": True})
    etapes += [
        {"statut": "EN_LIVRAISON", "delai": d(3), "detail": "Colis en cours de livraison"},
        {"statut": "LIVREE", "delai": d(3), "detail": "Colis livré", "notifier": True},
    ]
    return etapes


def _traiter(evenement, rng):
    order_id = evenement["order_id"]
    item = ddb.get_item(TableName=T_COMMANDES, Key={"order_id": {"S": order_id}},
                        ConsistentRead=True).get("Item")
    if item is None:
        raise RuntimeError(f"commande {order_id} absente")
    if item["statut"]["S"] != "RECUE":
        print(json.dumps({"evenement": "DEJA_TRAITEE", "order_id": order_id}))
        return

    transporteur = rng.choice(sorted(TRANSPORTEURS))
    suivi = TRANSPORTEURS[transporteur] + uuid.uuid4().hex[:11].upper()
    try:  # ne fixe le transporteur qu'une fois, même si le message est relivré
        ddb.update_item(
            TableName=T_COMMANDES,
            Key={"order_id": {"S": order_id}},
            UpdateExpression="SET transporteur = :t, numero_suivi = :n",
            ConditionExpression="attribute_exists(order_id) AND attribute_not_exists(numero_suivi)",
            ExpressionAttributeValues={":t": {"S": transporteur}, ":n": {"S": suivi}},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise

    try:
        sfn.start_execution(stateMachineArn=MACHINE, name=order_id,
                            input=json.dumps({"order_id": order_id, "etapes": _plan(rng)}))
    except ClientError as e:
        if e.response["Error"]["Code"] != "ExecutionAlreadyExists":
            raise
        print(json.dumps({"evenement": "DEJA_LANCEE", "order_id": order_id}))
        return
    print(json.dumps({"evenement": "SIMULATION_LANCEE", "order_id": order_id, "transporteur": transporteur}))


_ALEA = random.SystemRandom()


def handler(event, context, rng=_ALEA):
    echecs = []
    for record in event.get("Records", []):
        try:
            _traiter(json.loads(record["body"]), rng)
        except Exception as e:  # le message repartira dans la file, puis en DLQ après 3 essais
            print(json.dumps({"evenement": "ECHEC_TRAITEMENT", "messageId": record.get("messageId"),
                              "erreur": str(e)}))
            echecs.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": echecs}
