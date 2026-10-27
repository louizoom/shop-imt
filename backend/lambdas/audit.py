"""Consommateur SQS : archive chaque événement de commande dans S3 (audit / reporting).

Clé : audit/AAAA/MM/JJ/<order_id>.json  -> partitionnement par date, prêt pour Athena.
"""
import datetime
import json
import os

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET_AUDIT"]


def handler(event, context):
    echecs = []
    for record in event.get("Records", []):
        try:
            evenement = json.loads(record["body"])
            jour = evenement.get("cree_le", "")[:10] or datetime.date.today().isoformat()
            annee, mois, j = jour.split("-")
            trace = {
                **evenement,
                "audit": {
                    "archive_le": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds"),
                    "sqs_message_id": record.get("messageId"),
                    "recu_par_sqs_ms": record.get("attributes", {}).get("SentTimestamp"),
                },
            }
            s3.put_object(
                Bucket=BUCKET,
                Key=f"audit/{annee}/{mois}/{j}/{evenement['order_id']}.json",
                Body=json.dumps(trace, ensure_ascii=False).encode("utf-8"),
                ContentType="application/json",
            )
        except Exception as e:
            print(json.dumps({"evenement": "ECHEC_AUDIT", "messageId": record.get("messageId"),
                              "erreur": str(e)}))
            echecs.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": echecs}
