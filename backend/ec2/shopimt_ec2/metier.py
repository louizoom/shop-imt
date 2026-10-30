"""Réutilise le code métier des Lambdas, sans DynamoDB ni Step Functions.

Les modules des Lambdas lisent quelques variables d'environnement à l'import (noms de tables, ARN) :
on leur donne des valeurs neutres, la solution EC2 n'utilise que leurs fonctions pures et l'envoi SES.
"""
import os

for _cle, _valeur in {"TABLE_PRODUITS": "-", "TABLE_COMMANDES": "-", "STATE_MACHINE_ARN": "-",
                      "EXPEDITEUR": "", "AWS_DEFAULT_REGION": os.environ.get("AWS_REGION", "eu-west-3")}.items():
    os.environ.setdefault(_cle, _valeur)

import commandes  # noqa: E402  validation, numéros SHOP-000042-K7QF, date de livraison, agenda .ics
import notification  # noqa: E402  e-mails HTML FR/EN via SES
import traitement  # noqa: E402  transporteurs et plan d'expédition tiré au sort

__all__ = ["commandes", "notification", "traitement"]
