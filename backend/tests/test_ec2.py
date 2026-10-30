"""Solution EC2 : serveur web et serveur de traitement contre un vrai MySQL.

Lancés quand SHOPIMT_TEST_BDD vaut l'hôte MySQL (service mysql:8.4 de la CI, ou MySQL/MariaDB local),
sautés sinon. Kafka, SNS et SES sont désactivés (variables vides) : seuls RDS et la logique sont testés.
"""
import importlib.util
import json
import os
import random
import sys

import pytest

HOTE = os.environ.get("SHOPIMT_TEST_BDD")
pytestmark = pytest.mark.skipif(not HOTE or importlib.util.find_spec("pymysql") is None,
                                reason="MySQL de test absent (SHOPIMT_TEST_BDD)")

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(scope="module")
def client():
    os.environ.update({"BDD_HOTE": HOTE or "", "BDD_MOT_DE_PASSE": os.environ.get("SHOPIMT_TEST_MDP", "test"),
                       "BDD_NOM": os.environ.get("SHOPIMT_TEST_NOM", "boutique_test"), "EXPEDITEUR": "",
                       "DOSSIER_SITE": os.path.join(RACINE, "tests")})
    # Le dépôt fournit un faux boto3 pour les Lambdas : ici le vrai client n'est jamais appelé (SNS, SES vides)
    sys.path[:0] = [os.path.join(RACINE, "ec2"), os.path.join(RACINE, "lambdas")]
    from shopimt_ec2 import bdd, web
    with bdd.connexion() as c, c.cursor() as cur:
        for table in ("historique", "commandes", "produits"):
            cur.execute(f"DROP TABLE IF EXISTS {table}")
        c.commit()
    bdd.initialiser()
    bdd.initialiser()  # idempotent : plusieurs serveurs démarrent en même temps
    yield web.app.test_client()
    # Les tests des Lambdas importent les mêmes modules avec un faux boto3 : on rend la place
    del sys.path[:2]
    for nom in [n for n in sys.modules if n.split(".")[0] in {"shopimt_ec2", "commandes", "notification", "traitement",
                                                              "boto3", "botocore"}]:
        del sys.modules[nom]


def _commander(client, articles, email="client@exemple.fr"):
    return client.post("/commandes", data=json.dumps({"client_email": email, "articles": articles, "langue": "en"}))


def test_catalogue(client):
    produits = client.get("/produits").get_json()
    assert [p["id"] for p in produits] == ["p001", "p002", "p003", "p004", "p005", "p006"]
    assert produits[0]["prix"] == 19.9 and produits[0]["nom_en"] == "IMT T-shirt"


def test_commande_puis_suivi(client):
    r = _commander(client, [{"id": "p001", "quantite": 2}, {"id": "p003", "quantite": 1}])
    assert r.status_code == 201
    corps = r.get_json()
    assert corps["total"] == "49.30" and corps["order_id"].startswith("SHOP-000001-")
    stock = {p["id"]: p["stock"] for p in client.get("/produits").get_json()}
    assert stock["p001"] == 48 and stock["p003"] == 99

    suivi = client.get(f"/commandes/{corps['order_id']}").get_json()
    assert suivi["statut"] == "RECUE" and len(suivi["historique"]) == 1
    assert suivi["historique"][0].split(" ", 2)[1] == "RECUE"

    ics = client.get(f"/commandes/{corps['order_id']}/agenda")
    assert ics.status_code == 200 and b"BEGIN:VCALENDAR" in ics.data


def test_refus(client):
    assert _commander(client, [{"id": "p006", "quantite": 6}]).status_code == 409   # 5 en stock
    assert _commander(client, [{"id": "zzz", "quantite": 1}]).status_code == 400
    assert _commander(client, [{"id": "p001", "quantite": 1}], email="pas-un-email").status_code == 400
    assert client.get("/commandes/SHOP-000001-AAAA").status_code == 404
    assert client.get("/commandes/n'importe quoi").status_code == 400
    assert {p["id"]: p["stock"] for p in client.get("/produits").get_json()}["p006"] == 5


def test_simulation_jusqua_livraison(client):
    from shopimt_ec2 import worker
    order_id = _commander(client, [{"id": "p002", "quantite": 1}]).get_json()["order_id"]
    evenement = {"order_id": order_id, "client_email": "client@exemple.fr", "articles": [], "total": "39.90"}
    worker.traiter(evenement, rng=random.Random(1), attendre=lambda s: None)
    worker.traiter(evenement, rng=random.Random(1), attendre=lambda s: None)  # message SQS relivré : rien ne se rejoue

    suivi = client.get(f"/commandes/{order_id}").get_json()
    statuts = [h.split(" ", 2)[1] for h in suivi["historique"]]
    assert suivi["statut"] == "LIVREE" and statuts[0] == "RECUE" and statuts[-1] == "LIVREE"
    assert statuts.count("LIVREE") == 1 and suivi["transporteur"] and suivi["numero_suivi"]


def test_site_et_sante(client):
    assert client.get("/sante").status_code == 200
    r = client.get("/suivi/SHOP-000001-AAAA")  # page du routeur Vue : index.html (ici absent du dossier de test)
    assert r.status_code in (200, 404)
