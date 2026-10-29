"""Parcours complet des Lambdas, sans compte AWS (faux SDK en mémoire dans fakeaws/).
Exécuté par pytest (test_lambdas.py) ou directement : python3 backend/tests/parcours.py"""
import json
import re, os, sys, importlib, datetime
ICI = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.join(ICI, "fakeaws"), os.path.join(ICI, "..", "lambdas")]
os.environ.update(GROUPE_RAPPELS="rappels", ROLE_RAPPELS="arn:role", TABLE_PRODUITS="p", TABLE_COMMANDES="c", TOPIC_ARN="arn:t", BUCKET_AUDIT="b", STATE_MACHINE_ARN="arn:sfn", SITE_URL="https://shop.test", EXPEDITEUR="shop@imt.test")
import boto3
boto3.KEYS.update(p="id", c="order_id")
boto3.TABLES.update(p={"p001": {"id":{"S":"p001"},"nom":{"S":"T-shirt"},"prix":{"N":"19.90"},"stock":{"N":"3"}},
                       "p003": {"id":{"S":"p003"},"nom":{"S":"Mug"},"prix":{"N":"9.50"},"stock":{"N":"10"}}}, c={})
catalogue, commandes, publication, notification, traitement, audit = (importlib.import_module(m) for m in ["catalogue","commandes","publication","notification","traitement","audit"])

def post(body): return commandes.handler({"routeKey":"POST /commandes","body":json.dumps(body)}, None)
def get(i): return commandes.handler({"routeKey":"GET /commandes/{id}","pathParameters":{"id":i}}, None)

r = catalogue.handler({}, None); prods = json.loads(r["body"])
assert r["statusCode"] == 200 and prods[0]["prix"] == 19.9 and prods[0]["stock"] == 3, prods
# Noms anglais : Amazon Translate une seule fois par produit, puis lus dans la table
assert prods[0]["nom_en"] == "T-shirt" and boto3.TABLES["p"]["p001"]["nom_en"]["S"] == "T-shirt" and len(boto3.TRADUCTIONS) == 2
catalogue.handler({}, None); assert len(boto3.TRADUCTIONS) == 2

assert post({"client_email":"pas-un-mail","articles":[{"id":"p001","quantite":1}]})["statusCode"] == 400
assert post({"client_email":"a@b.fr","articles":[]})["statusCode"] == 400
assert post({"client_email":"a@b.fr","articles":[{"id":"zzz","quantite":1}]})["statusCode"] == 400
assert post({"client_email":"a@b.fr","articles":[{"id":"p001","quantite":"x"}]})["statusCode"] == 400
assert commandes.handler({"routeKey":"POST /commandes","body":"{oops"}, None)["statusCode"] == 400

r = post({"client_email":"A@B.fr","articles":[{"id":"p001","quantite":4}]})
assert r["statusCode"] == 409, r   # stock 3 < 4
assert boto3.TABLES["p"]["p001"]["stock"]["N"] == "3"   # rollback

r = post({"client_email":"A@B.fr","articles":[{"id":"p001","quantite":2},{"id":"p003","quantite":1},{"id":"p001","quantite":1}]})
assert r["statusCode"] == 201, r
c = json.loads(r["body"]); oid = c["order_id"]
assert re.match(r"^SHOP-000002-[2-9A-HJKMNP-Z]{4}$", oid), oid   # compteur atomique (le 409 a pris le n° 1) + code de contrôle
assert boto3.TABLES["c"]["#compteur"]["valeur"]["N"] == "2"
assert get(oid[:-4] + "2222")["statusCode"] in (400, 404) and get("SHOP-000001")["statusCode"] == 400
assert get("123e4567-e89b-12d3-a456-426614174000")["statusCode"] == 404   # ancien format UUID toujours accepté
assert c["total"] == "69.20", c   # 3*19.90 + 9.50
assert boto3.TABLES["p"]["p001"]["stock"]["N"] == "0"
assert boto3.PUBLISHED == []   # commandes n'écrit qu'en base (outbox)

def flux(nom, image, seq): return {"eventName": nom, "dynamodb": {"NewImage": image, "SequenceNumber": seq}}
assert publication.handler({"Records":[flux("MODIFY", boto3.TABLES["c"][oid], "1")]}, None) == {"batchItemFailures": []}
assert boto3.PUBLISHED == []   # seules les insertions sont publiées
assert publication.handler({"Records":[flux("INSERT", boto3.TABLES["c"][oid], "2")]}, None) == {"batchItemFailures": []}
assert publication.handler({"Records":[flux("INSERT", {"order_id":{"S":"x"}}, "3"), flux("INSERT", boto3.TABLES["c"][oid], "4")]}, None) \
    == {"batchItemFailures": [{"itemIdentifier": "3"}]}   # flux ordonné : arrêt au premier échec
assert len(boto3.PUBLISHED) == 1
pub = boto3.PUBLISHED[-1]; msg = json.loads(pub["Message"]); evt = json.loads(msg["default"])
assert pub["MessageAttributes"]["client_email"]["StringValue"] == "a@b.fr"
assert f"https://shop.test/suivi/{oid}" in msg["email"]
assert evt["order_id"] == oid and evt["total"] == "69.20" and evt["articles"][0]["id"] == "p001" and "69.20" in msg["email"] and len(pub["Subject"]) < 100 and pub["Subject"].isascii()

assert json.loads(get(oid)["body"])["statut"] == "RECUE"
assert get("nope")["statusCode"] == 400 and get("00000000-0000-0000-0000-000000000000")["statusCode"] == 404

# Agenda : livraison estimée à J+3 ouvrés, fichier .ics, lien Google Agenda, rappel EventBridge Scheduler
livr = evt["livraison_estimee"]
assert livr == commandes.livraison_estimee(datetime.date.fromisoformat(evt["cree_le"][:10])) and json.loads(get(oid)["body"])["livraison_estimee"] == livr
assert commandes.livraison_estimee(datetime.date(2026, 10, 30)) == "2026-11-04"   # vendredi -> mercredi (week-end exclu)
ics = commandes.handler({"routeKey": "GET /commandes/{id}/agenda", "pathParameters": {"id": oid}}, None)
assert ics["headers"]["Content-Type"].startswith("text/calendar") and ics["body"].startswith("BEGIN:VCALENDAR\r\n"), ics
assert f"DTSTART;VALUE=DATE:{livr.replace('-', '')}" in ics["body"] and f"UID:{oid}@shop-imt" in ics["body"] and "\\, " in ics["body"]
assert commandes.handler({"routeKey": "GET /commandes/{id}/agenda", "pathParameters": {"id": "x"}}, None)["statusCode"] == 400
class Ctx: invoked_function_arn = "arn:aws:lambda:eu-west-3:1:function:notification"
sns_rec = {"Records":[{"Sns":{"Message": msg["default"]}}]}
notification.handler(sns_rec, Ctx())
(mail,) = boto3.EMAILS; corps = mail["Body"]["Html"]["Data"]
assert "calendar.google.com" in corps and f"/commandes/{oid}/agenda" in corps and "Livraison estimée" in corps
plan = boto3.SCHEDULES[("rappels", f"rappel-{oid}")]
veille = (datetime.date.fromisoformat(livr) - datetime.timedelta(days=1)).isoformat()
assert plan["ScheduleExpression"] == f"at({veille}T18:00:00)" and plan["ActionAfterCompletion"] == "DELETE", plan
assert json.loads(plan["Target"]["Input"]) == {"type": "RAPPEL_LIVRAISON", "order_id": oid} and plan["Target"]["Arn"] == Ctx.invoked_function_arn
notification.handler({"type": "RAPPEL_LIVRAISON", "order_id": oid}, None)
rappel = boto3.EMAILS.pop(); assert "arrive demain" in rappel["Subject"]["Data"] and rappel["to"] == ["a@b.fr"]
assert mail["to"] == ["a@b.fr"] and "shop@imt.test" in mail["from"] and oid[:8] in mail["Subject"]["Data"]
assert f'href="https://shop.test/suivi/{oid}"' in corps and "Suivre ma commande" in corps
assert 'src="https://shop.test/img/p001.png"' in corps and 'src="https://shop.test/img/p003.png"' in corps
assert "69,20 €" in corps and "3 × 19,90 €" in corps and "69,20 €" in mail["Body"]["Text"]["Data"]
boto3.NON_VERIFIES.add("a@b.fr"); notification.handler(sns_rec, Ctx())   # sandbox SES : ignoré, pas d'exception
assert len(boto3.EMAILS) == 1 and boto3.IDENTITES == ["a@b.fr"]   # lien de vérification demandé à SES
notification.handler(sns_rec, Ctx()); assert boto3.IDENTITES == ["a@b.fr"]   # une seule fois
# E-mails en anglais : langue enregistrée avec la commande, noms traduits, montants au format anglais
en = dict(json.loads(msg["default"]), langue="en", articles=[{"id":"p001","nom":"T-shirt IMT","nom_en":"IMT T-shirt","quantite":3,"prix_unitaire":"19.90"}])
s_en, h_en, t_en = notification.construire_email(en)
assert "is confirmed" in s_en and "IMT T-shirt" in h_en and "€59.70" in h_en and "Estimated delivery" in h_en and 'lang="en"' in h_en and "Track my order" in h_en
assert "Merci" not in h_en and "€69.20" in t_en and "3 x IMT T-shirt" in t_en
s_st = notification.construire_email_statut({"order_id": oid, "langue": "en", "articles": []}, "LIVREE", "Delivered")[0]
assert "Your parcel has arrived!" in s_st
evil = dict(json.loads(msg["default"]), articles=[{"id":"p001","nom":"<script>x</script>","quantite":1,"prix_unitaire":"1.00"}])
assert "<script>" not in notification.construire_email(evil)[1]   # pas d'injection HTML

# Comptes clients (Cognito) : commande rattachée au compte et historique
def compte(route, sub, body=None):
    claims = {"sub": sub, "email": "Membre@IMT.fr"}
    return commandes.handler({"routeKey": route, "body": json.dumps(body) if body else None,
                              "requestContext": {"authorizer": {"jwt": {"claims": claims}}}}, None)
r = compte("POST /compte/commandes", "sub-1", {"client_email": "pirate@x.fr", "articles": [{"id": "p003", "quantite": 1}]})
assert r["statusCode"] == 201, r
oid2 = json.loads(r["body"])["order_id"]
assert oid2.startswith("SHOP-000003-"), oid2
assert boto3.TABLES["c"][oid2]["client_email"]["S"] == "membre@imt.fr"   # e-mail du jeton, pas du corps
assert boto3.TABLES["c"][oid2]["client_sub"]["S"] == "sub-1"
h = json.loads(compte("GET /compte/commandes", "sub-1")["body"])["commandes"]
assert [c["order_id"] for c in h] == [oid2] and h[0]["nb_articles"] == 1 and h[0]["total"] == "9.50", h
assert json.loads(compte("GET /compte/commandes", "sub-2")["body"])["commandes"] == []   # chacun ne voit que les siennes
assert "client_sub" not in boto3.TABLES["c"][oid]   # commande anonyme : hors historique

rec = {"messageId":"m1","body":msg["default"],"attributes":{"SentTimestamp":"1"}}
assert traitement.handler({"Records":[rec]}, None) == {"batchItemFailures": []}
ex = json.loads(boto3.EXECUTIONS[oid]); etapes = [e["statut"] for e in ex["etapes"]]
assert ex["order_id"] == oid and etapes[:3] == ["EN_PREPARATION","EMBALLEE","EXPEDIEE"] and etapes[-2:] == ["EN_LIVRAISON","LIVREE"], etapes
assert all(1 <= e["delai"] <= 8 and e["detail"] for e in ex["etapes"])
item = boto3.TABLES["c"][oid]; suivi = item["numero_suivi"]["S"]
assert item["transporteur"]["S"] in traitement.TRANSPORTEURS and suivi.startswith(traitement.TRANSPORTEURS[item["transporteur"]["S"]])
assert traitement.handler({"Records":[rec]}, None) == {"batchItemFailures": []}   # relivraison -> idempotent
assert len(boto3.EXECUTIONS) == 1 and boto3.TABLES["c"][oid]["numero_suivi"]["S"] == suivi
import random
plans = [[e["statut"] for e in traitement._plan(random.Random(g))] for g in range(200)]
assert 20 < sum("INCIDENT_TRANSPORT" in p for p in plans) < 90   # ~25 % d'incidents
boto3.TABLES["c"][oid]["statut"] = {"S": "LIVREE"}
s = json.loads(get(oid)["body"]); assert s["statut"] == "LIVREE" and s["transporteur"] and s["numero_suivi"] == suivi, s
# E-mails de suivi envoyés par Step Functions
notifies = {e["statut"] for e in ex["etapes"] if e.get("notifier")}
assert {"EXPEDIEE", "LIVREE"} <= notifies <= set(notification.STATUTS_EMAIL), notifies
boto3.NON_VERIFIES.clear(); avant = len(boto3.EMAILS)
notification.handler({"type": "STATUT_COLIS", "order_id": oid, "statut": "EXPEDIEE", "detail": "Colis remis au transporteur"}, None)
mail = boto3.EMAILS[-1]; corps = mail["Body"]["Html"]["Data"]
assert len(boto3.EMAILS) == avant + 1 and mail["to"] == ["a@b.fr"] and "en route" in mail["Subject"]["Data"]
assert suivi in corps and item["transporteur"]["S"] in corps and f"/suivi/{oid}" in corps and "img/p001.png" in corps
notification.handler({"type": "STATUT_COLIS", "order_id": oid, "statut": "EN_LIVRAISON", "detail": "x"}, None)   # pas d'e-mail
notification.handler({"type": "STATUT_COLIS", "order_id": "inconnu", "statut": "LIVREE", "detail": "x"}, None)   # commande absente
assert len(boto3.EMAILS) == avant + 1
notification.handler({"type": "STATUT_COLIS", "order_id": oid, "statut": "LIVREE", "detail": "Colis livré"}, None)
assert "arrivé" in boto3.EMAILS[-1]["Subject"]["Data"]
assert ("rappels", f"rappel-{oid}") not in boto3.SCHEDULES   # livré : rappel supprimé
avant = len(boto3.EMAILS); notification.handler({"type": "RAPPEL_LIVRAISON", "order_id": oid}, None)
assert len(boto3.EMAILS) == avant   # plus de rappel une fois livré

bad = {"messageId":"m2","body":json.dumps({"order_id":"inconnu"})}
assert traitement.handler({"Records":[bad]}, None) == {"batchItemFailures":[{"itemIdentifier":"m2"}]}

assert audit.handler({"Records":[rec]}, None) == {"batchItemFailures": []}
(k, v), = boto3.S3.items()
assert k.startswith("audit/") and k.endswith(f"/{oid}.json") and json.loads(v)["audit"]["sqs_message_id"] == "m1", k

# Interface admin : groupe Cognito obligatoire, lecture par l'index par-jour
admin = importlib.import_module("admin")
import datetime
aujourdhui = datetime.datetime.now(datetime.UTC).date().isoformat()
assert boto3.TABLES["c"][oid]["jour"]["S"] == aujourdhui   # champ jour écrit à la création
def adm(route, groupes, qs=None):
    claims = {"sub": "s", "email": "chef@imt.fr", "cognito:groups": groupes}
    return admin.handler({"routeKey": route, "queryStringParameters": qs,
                          "requestContext": {"authorizer": {"jwt": {"claims": claims}}}}, None)
assert adm("GET /admin/stats", "")["statusCode"] == 403          # client connecté sans groupe
assert adm("GET /admin/stats", "[clients]")["statusCode"] == 403
assert adm("GET /admin/stats", "[admins]", {"jours": "x"})["statusCode"] == 400
st = json.loads(adm("GET /admin/stats", "[admins]", {"jours": "7"})["body"])
assert st["periode_jours"] == 7 and len(st["par_jour"]) == 7 and st["par_jour"][-1]["jour"] == aujourdhui
assert st["commandes"] == st["commandes_aujourdhui"] == 2 and st["chiffre_affaires"] == "78.70", st   # 69.20 + 9.50
assert st["panier_moyen"] == "39.35" and st["clients_uniques"] == 2 and sum(st["statuts"].values()) == 2
assert st["produits"][0] == {"nom": "T-shirt", "quantite": 3, "chiffre_affaires": "59.70"}, st["produits"]
lst = json.loads(adm("GET /admin/commandes", "[admins autre]")["body"])["commandes"]
assert {c["client_email"] for c in lst} == {"a@b.fr", "membre@imt.fr"} and lst[0]["cree_le"] >= lst[1]["cree_le"]
assert lst[0]["total"] in ("69.20", "9.50") and "nb_articles" in lst[0]
assert [c["client_email"] for c in json.loads(adm("GET /admin/commandes", "[admins]", {"q": "MEMBRE"})["body"])["commandes"]] == ["membre@imt.fr"]
os.environ["BUCKET_EXPORT"] = "b"; admin.BUCKET_EXPORT = "b"
ex = json.loads(adm("GET /admin/export", "[admins]", {"jours": "7"})["body"])
assert ex["lignes"] == 2 and ex["url"].startswith("https://b.s3.test/exports/") and "expire=300" in ex["url"], ex
csvtxt = boto3.S3["exports/" + ex["fichier"]].decode("utf-8-sig").splitlines()
assert csvtxt[0].startswith("date;commande;client") and any("membre@imt.fr" in l and ";9,50;" in l for l in csvtxt), csvtxt
assert adm("GET /admin/export", "")["statusCode"] == 403

# Onglet Stock : lecture du catalogue et réassort par +/- (jamais sous 0)
def stock(groupes, corps):
    claims = {"sub": "s", "email": "chef@imt.fr", "cognito:groups": groupes}
    return admin.handler({"routeKey": "POST /admin/stock", "body": json.dumps(corps),
                          "requestContext": {"authorizer": {"jwt": {"claims": claims}}}}, None)
admin.T_PRODUITS = "p"
inv = json.loads(adm("GET /admin/stock", "[admins]")["body"])["produits"]
assert [p["id"] for p in inv] == ["p001", "p003"] and inv[1] == {"id": "p003", "nom": "Mug", "nom_en": "Mug", "prix": "9.50", "stock": 8}, inv
assert stock("", {"id": "p003", "delta": 5})["statusCode"] == 403
r = stock("[admins]", {"id": "p003", "delta": 5})
assert r["statusCode"] == 200 and json.loads(r["body"]) == {"id": "p003", "stock": 13}, r
assert json.loads(stock("[admins]", {"id": "p003", "delta": -4})["body"])["stock"] == 9
assert stock("[admins]", {"id": "p003", "delta": -10})["statusCode"] == 409   # stock négatif refusé
assert stock("[admins]", {"id": "zzz", "delta": 1})["statusCode"] == 409      # produit inconnu
assert stock("[admins]", {"id": "p003", "delta": 0})["statusCode"] == 400
assert stock("[admins]", {"id": "p003"})["statusCode"] == 400
# Rôles : « stock » ne voit que le stock, « ventes » ne lit que les ventes (ni export ni stock)
assert stock("[stock]", {"id": "p003", "delta": 1})["statusCode"] == 200
assert stock("[stock]", {"id": "p003", "delta": -1})["statusCode"] == 200
assert adm("GET /admin/stock", "[stock]")["statusCode"] == 200
assert adm("GET /admin/stats", "[stock]")["statusCode"] == 403
assert adm("GET /admin/export", "[stock]")["statusCode"] == 403
assert adm("GET /admin/stats", "[ventes]")["statusCode"] == 200
assert adm("GET /admin/commandes", "[ventes]")["statusCode"] == 200
assert adm("GET /admin/export", "[ventes]")["statusCode"] == 403
assert stock("[ventes]", {"id": "p003", "delta": 1})["statusCode"] == 403
assert adm("GET /admin/stats", "[stock ventes]")["statusCode"] == 200   # plusieurs rôles : droits cumulés
assert boto3.TABLES["p"]["p003"]["stock"]["N"] == "9"

# Récap quotidien (EventBridge Scheduler) : commandes du jour, stocks bas, e-mail aux admins
os.environ.update(TABLE_PRODUITS="p", DESTINATAIRES="chef@imt.fr,autre@imt.fr")
rapport = importlib.import_module("rapport")
avant = len(boto3.EMAILS)
out = rapport.handler({}, None)
assert out == {"jour": aujourdhui, "commandes": 2, "chiffre_affaires": "78.70", "envoyes": 2}, out
mail = boto3.EMAILS[-1]; corps = mail["Body"]["Html"]["Data"]
assert len(boto3.EMAILS) == avant + 2 and "2 commande(s)" in mail["Subject"]["Data"] and "78,70 €" in mail["Subject"]["Data"]
assert "T-shirt : 3" in corps and "Stocks bas" in corps and "/admin" in corps   # p001 à 0 en stock
assert rapport.handler({"jour": "2001-01-01"}, None)["commandes"] == 0
print("Tous les tests passent ✔")
