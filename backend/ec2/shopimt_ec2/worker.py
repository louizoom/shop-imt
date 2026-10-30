"""Serveur de traitement de la solution EC2 (instance unique, à côté du broker Kafka).

Trois boucles, une par fil d'exécution :
  - traitement : file SQS (alimentée par SNS) -> e-mail de confirmation SES, puis préparation, expédition et
    livraison simulées (statuts écrits dans RDS, chaque étape publiée sur Kafka) ;
  - audit : groupe Kafka « audit » -> une trace JSON par événement dans S3 ;
  - suivi : groupe Kafka « emails-suivi » -> e-mails d'expédition, d'incident et de livraison.
Un balayage RDS rattrape les commandes restées RECUE (SNS indisponible au moment de la commande).

Idempotent : une commande n'est simulée que si elle est encore RECUE (verrou de ligne), un message SQS relivré
ne relance rien. Les étapes et leurs délais viennent du même tirage que la solution serverless.
"""
import datetime
import json
import logging
import random
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import boto3

from . import bdd, config, evenements
from .metier import notification, traitement

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("shopimt.traitement")
logging.getLogger("kafka").setLevel(logging.WARNING)  # client Kafka très bavard en INFO
_ALEA = random.SystemRandom()
traitement.DELAI_MAX = config.DELAI_MAX
_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="commande")


def _maintenant():
    return datetime.datetime.now(datetime.UTC).replace(microsecond=0, tzinfo=None)


def reserver(order_id, rng=_ALEA):
    """Passe la commande en préparation et lui attribue un transporteur. None si déjà prise en charge."""
    with bdd.connexion() as c, c.cursor() as cur:
        cur.execute("SELECT statut, numero_suivi FROM commandes WHERE order_id = %s FOR UPDATE", (order_id,))
        ligne = cur.fetchone()
        if ligne is None or ligne["statut"] != "RECUE" or ligne["numero_suivi"]:
            c.rollback()
            return None
        transporteur = rng.choice(sorted(traitement.TRANSPORTEURS))
        suivi = traitement.TRANSPORTEURS[transporteur] + uuid.uuid4().hex[:11].upper()
        cur.execute("UPDATE commandes SET transporteur = %s, numero_suivi = %s WHERE order_id = %s",
                    (transporteur, suivi, order_id))
        c.commit()
    return transporteur


def simuler(order_id, rng=_ALEA, attendre=time.sleep):
    """Joue les étapes tirées au sort (traitement._plan) : attente, statut dans RDS, événement Kafka."""
    for etape in traitement._plan(rng):
        attendre(etape["delai"])
        with bdd.connexion() as c, c.cursor() as cur:
            bdd.ajouter_etape(cur, order_id, etape["statut"], etape["detail"], _maintenant())
            c.commit()
        evenements.publier_kafka({"type": "STATUT_COLIS", "order_id": order_id, "statut": etape["statut"],
                                  "detail": etape["detail"], "notifier": bool(etape.get("notifier")),
                                  "horodatage": _maintenant().isoformat() + "+00:00"})
        log.info(json.dumps({"evenement": "ETAPE", "order_id": order_id, "statut": etape["statut"]}))


def traiter(evenement, rng=_ALEA, attendre=time.sleep):
    order_id = evenement["order_id"]
    transporteur = reserver(order_id, rng)
    if transporteur is None:
        log.info(json.dumps({"evenement": "DEJA_TRAITEE", "order_id": order_id}))
        return
    if notification.EXPEDITEUR:
        sujet, corps, texte = notification.construire_email(evenement)
        notification._envoyer(evenement["client_email"], order_id, sujet, corps, texte, "CONFIRMATION")
    log.info(json.dumps({"evenement": "SIMULATION_LANCEE", "order_id": order_id, "transporteur": transporteur}))
    simuler(order_id, rng, attendre)


# ---------- Boucle SQS (long polling : 20 s d'attente par requête, ~130 000 requêtes par mois, dans le Free Tier)

def boucle_sqs():
    sqs = boto3.client("sqs", region_name=config.REGION)
    while True:
        try:
            r = sqs.receive_message(QueueUrl=config.FILE_TRAITEMENT, MaxNumberOfMessages=10, WaitTimeSeconds=20)
        except Exception as e:
            log.error(json.dumps({"evenement": "SQS_ERREUR", "erreur": str(e)}))
            time.sleep(5)
            continue
        for m in r.get("Messages", []):
            _pool.submit(_message_sqs, sqs, m)


def _message_sqs(sqs, m):
    try:
        traiter(json.loads(m["Body"]))
    except Exception as e:  # le message réapparaît après le délai de visibilité, puis part en DLQ après 3 essais
        log.error(json.dumps({"evenement": "ECHEC_TRAITEMENT", "messageId": m["MessageId"], "erreur": str(e)}))
        return
    sqs.delete_message(QueueUrl=config.FILE_TRAITEMENT, ReceiptHandle=m["ReceiptHandle"])


def balayage():
    """Commandes RECUE depuis plus de 2 minutes sans message SQS : traitées depuis RDS."""
    while True:
        time.sleep(60)
        try:
            with bdd.connexion() as c, c.cursor() as cur:
                cur.execute("SELECT * FROM commandes WHERE statut = 'RECUE' AND numero_suivi IS NULL AND cree_le < %s LIMIT 20",
                            (_maintenant() - datetime.timedelta(minutes=2),))
                oubliees = cur.fetchall()
            for o in oubliees:
                log.warning(json.dumps({"evenement": "RATTRAPAGE", "order_id": o["order_id"]}))
                arts = json.loads(o["articles"]) if isinstance(o["articles"], str) else o["articles"]
                _pool.submit(traiter, {"order_id": o["order_id"], "client_email": o["client_email"], "langue": o["langue"],
                                       "total": f"{o['total']:.2f}", "articles": arts,
                                       "livraison_estimee": o["livraison_estimee"].isoformat() if o["livraison_estimee"] else None})
        except Exception as e:
            log.error(json.dumps({"evenement": "BALAYAGE_ERREUR", "erreur": str(e)}))


# ---------- Consommateurs Kafka : chaque groupe lit tout le flux, à son rythme, avec ses propres offsets

def consommer(groupe, traiter_evenement):
    from kafka import KafkaConsumer
    while True:
        try:
            consommateur = KafkaConsumer(
                config.TOPIC_KAFKA, bootstrap_servers=config.KAFKA.split(","), group_id=groupe, api_version=(3, 9),
                auto_offset_reset="earliest", enable_auto_commit=False,
                value_deserializer=lambda v: json.loads(v.decode()),
            )
            for message in consommateur:
                traiter_evenement(message.value, message)
                consommateur.commit()  # offset validé après traitement : au moins une fois
        except Exception as e:
            log.error(json.dumps({"evenement": "KAFKA_ERREUR", "groupe": groupe, "erreur": str(e)}))
            time.sleep(10)


_s3 = None


def archiver(evenement, message=None):
    """audit/AAAA/MM/JJ/<commande>/<offset>-<type>.json : rien ne se perd, même un événement rejoué."""
    global _s3
    _s3 = _s3 or boto3.client("s3", region_name=config.REGION)
    jour = _maintenant().strftime("%Y/%m/%d")
    position = f"{message.partition}-{message.offset}" if message is not None else str(int(time.time()))
    nom = evenement.get("statut") or evenement["type"]
    _s3.put_object(Bucket=config.BUCKET_AUDIT, Key=f"audit/{jour}/{evenement['order_id']}/{position}-{nom}.json",
                   Body=json.dumps(evenement, ensure_ascii=False).encode(), ContentType="application/json")


def email_suivi(evenement, message=None):
    if evenement.get("type") != "STATUT_COLIS" or not evenement.get("notifier") or not notification.EXPEDITEUR:
        return
    with bdd.connexion() as c, c.cursor() as cur:
        commande = bdd.lire_commande(cur, evenement["order_id"])
    if commande is None:
        return
    sujet, corps, texte = notification.construire_email_statut(commande, evenement["statut"], evenement.get("detail", ""))
    notification._envoyer(commande["client_email"], evenement["order_id"], sujet, corps, texte, evenement["statut"])


def main():
    bdd.initialiser()
    fils = [threading.Thread(target=boucle_sqs, name="sqs"), threading.Thread(target=balayage, name="balayage")]
    if config.KAFKA:
        fils += [threading.Thread(target=consommer, args=("audit", archiver), name="kafka-audit"),
                 threading.Thread(target=consommer, args=("emails-suivi", email_suivi), name="kafka-suivi")]
    for f in fils:
        f.daemon = True
        f.start()
    log.info(json.dumps({"evenement": "TRAITEMENT_DEMARRE", "fils": [f.name for f in fils]}))
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
