"""Publication des événements de commande.

- Amazon SNS : COMMANDE_CREEE, diffusé vers la file SQS de traitement (modèle événementiel, comme en serverless).
- Apache Kafka (un broker sur le serveur de traitement) : tout le cycle de vie de la commande dans le topic
  « commandes », lu par deux groupes de consommateurs indépendants (audit S3, e-mails de suivi).

Kafka est un journal en continu : un consommateur peut relire l'historique depuis le début (rejeu), ce que SNS
ne permet pas. Si le broker est indisponible, la commande est quand même traitée (SNS et SQS suffisent) :
l'événement Kafka est seulement journalisé comme perdu.
"""
import json
import logging
import threading

import boto3

from . import config

log = logging.getLogger("shopimt.evenements")
_sns = None
_producteur = None
_verrou = threading.Lock()


def publier_sns(evenement):
    global _sns
    if not config.TOPIC_COMMANDES:
        return
    _sns = _sns or boto3.client("sns", region_name=config.REGION)
    _sns.publish(TopicArn=config.TOPIC_COMMANDES, Message=json.dumps(evenement, ensure_ascii=False),
                 MessageAttributes={"type": {"DataType": "String", "StringValue": evenement["type"]}})


def _kafka():
    global _producteur
    with _verrou:
        if _producteur is None:
            from kafka import KafkaProducer
            _producteur = KafkaProducer(
                bootstrap_servers=config.KAFKA.split(","), acks="all", linger_ms=5, api_version=(3, 9),
                max_block_ms=2000, request_timeout_ms=5000,
                key_serializer=str.encode, value_serializer=lambda v: json.dumps(v, ensure_ascii=False).encode(),
            )
        return _producteur


def publier_kafka(evenement):
    """Clé = numéro de commande : tous les événements d'une commande vont dans la même partition, dans l'ordre."""
    if not config.KAFKA:
        return
    try:
        _kafka().send(config.TOPIC_KAFKA, key=evenement["order_id"], value=evenement).get(timeout=5)
    except Exception as e:  # le broker est un nœud unique : la boutique continue sans lui
        log.warning(json.dumps({"evenement": "KAFKA_INDISPONIBLE", "order_id": evenement["order_id"], "erreur": str(e)}))
