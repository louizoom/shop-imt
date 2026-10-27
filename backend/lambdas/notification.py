"""E-mails clients en HTML via Amazon SES, en français ou en anglais (langue choisie sur le site).

- Abonné SNS : e-mail de confirmation à la création de la commande.
- Appelée par Step Functions (machine « expedition ») : e-mail à l'expédition, en cas
  d'incident de transport et à la livraison.
- Appelée par EventBridge Scheduler : rappel « votre colis arrive demain ».

SNS ne sait envoyer que du texte brut ; SES permet un vrai e-mail mis en forme (logo, photos
des articles, bouton de suivi), avec une version texte pour les messageries qui n'affichent
pas le HTML. Les images sont des PNG servis par CloudFront (les messageries n'affichent pas le SVG).

Agenda : l'e-mail de confirmation annonce la livraison estimée avec deux boutons (Google Agenda,
Apple Calendrier via la route .ics de l'API) et programme le rappel avec une planification
unique at(...), supprimée après exécution, ou à la livraison si le colis arrive avant.

En mode « sandbox » SES (compte par défaut), seules les adresses vérifiées reçoivent les e-mails.
Pour un destinataire inconnu, la Lambda demande à SES de lui envoyer le lien de vérification
(une seule fois, à la confirmation de commande) : après un clic, il reçoit tous ses e-mails.
"""
import datetime
import html
import json
import os
from urllib.parse import urlencode

import boto3
from botocore.exceptions import ClientError

ses = boto3.client("sesv2")
scheduler = boto3.client("scheduler")
GROUPE_RAPPELS = os.environ.get("GROUPE_RAPPELS", "")
ROLE_RAPPELS = os.environ.get("ROLE_RAPPELS", "")
HEURE_RAPPEL = "18:00:00"   # la veille de la livraison, heure de Paris
ddb = boto3.client("dynamodb")
T_COMMANDES = os.environ.get("TABLE_COMMANDES", "")
EXPEDITEUR = os.environ["EXPEDITEUR"]
SITE_URL = os.environ.get("SITE_URL", "")

MARINE, BLEU, GRIS = "#14223C", "#00B8DE", "#EDF3F4"
POLICE = "Helvetica, Arial, sans-serif"

# ---------- Textes (fr / en)

TEXTES = {
    "fr": {
        "suivre": "Suivre ma commande", "numero": "N° de commande", "total": "Total",
        "pied": "SHOP'IMT, la boutique des étudiants de l'IMT · Projet AWS serverless (démonstration, aucun paiement réel).<br>"
                "Vous recevez cet e-mail car une commande a été passée avec cette adresse.",
        "signature": "SHOP'IMT, la boutique des étudiants de l'IMT",
        "conf_sujet": "SHOP'IMT - Votre commande {id} est confirmée", "conf_sur": "COMMANDE CONFIRMÉE",
        "conf_titre": "Merci pour votre commande&nbsp;!",
        "conf_phrase": "Nous préparons vos {nb} article(s). Vous pouvez suivre chaque étape en direct, de l'entrepôt jusqu'à votre porte.",
        "conf_apercu": "Merci ! {nb} article(s), total {total}. Suivez votre colis en direct.",
        "conf_ensuite": "<strong style=\"color:{marine};\">Et maintenant&nbsp;?</strong><br>1. Préparation en entrepôt &nbsp;·&nbsp; "
                        "2. Remise au transporteur &nbsp;·&nbsp; 3. Livraison.<br>Vous recevrez un e-mail à l'expédition puis à la livraison.",
        "conf_texte": "Merci pour votre commande SHOP'IMT {id} !", "suivre_texte": "Suivez-la en direct",
        "livraison": "Livraison estimée", "google": "Google Agenda", "apple": "Apple Calendrier",
        "google_texte": "Ajouter à Google Agenda", "agenda_titre": "Livraison SHOP'IMT", "agenda_suivi": "Suivi",
        "etape": "Étape", "transporteur": "Transporteur", "num_suivi": "N° de suivi",
        "rappel_sujet": "SHOP'IMT - Votre colis arrive demain", "rappel_sur": "RAPPEL DE LIVRAISON",
        "rappel_titre": "Votre colis arrive demain&nbsp;!",
        "rappel_phrase": "Livraison prévue {date}. Pensez à être disponible ou à prévenir un voisin.",
        "jours": ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"],
        "mois": ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
        "statuts": {
            "EXPEDIEE": ("COLIS EXPÉDIÉ", "Votre colis est en route&nbsp;!", "Il vient d'être remis au transporteur."),
            "INCIDENT_TRANSPORT": ("INCIDENT DE TRANSPORT", "Votre colis a un peu de retard",
                                   "Le transporteur nous signale un incident. Pas d'inquiétude : la livraison reprend dès que possible."),
            "LIVREE": ("COLIS LIVRÉ", "Votre colis est arrivé&nbsp;!", "Merci pour votre commande, à bientôt sur SHOP'IMT."),
        },
    },
    "en": {
        "suivre": "Track my order", "numero": "Order number", "total": "Total",
        "pied": "SHOP'IMT, the IMT students' shop · AWS serverless project (demo, no real payment).<br>"
                "You are receiving this e-mail because an order was placed with this address.",
        "signature": "SHOP'IMT, the IMT students' shop",
        "conf_sujet": "SHOP'IMT - Your order {id} is confirmed", "conf_sur": "ORDER CONFIRMED",
        "conf_titre": "Thank you for your order!",
        "conf_phrase": "We are preparing your {nb} item(s). Follow every step live, from the warehouse to your door.",
        "conf_apercu": "Thank you! {nb} item(s), total {total}. Track your parcel live.",
        "conf_ensuite": "<strong style=\"color:{marine};\">What's next?</strong><br>1. Picking in the warehouse &nbsp;·&nbsp; "
                        "2. Handed to the carrier &nbsp;·&nbsp; 3. Delivery.<br>You will get an e-mail when it ships and when it is delivered.",
        "conf_texte": "Thank you for your SHOP'IMT order {id}!", "suivre_texte": "Track it live",
        "livraison": "Estimated delivery", "google": "Google Calendar", "apple": "Apple Calendar",
        "google_texte": "Add to Google Calendar", "agenda_titre": "SHOP'IMT delivery", "agenda_suivi": "Tracking",
        "etape": "Step", "transporteur": "Carrier", "num_suivi": "Tracking number",
        "rappel_sujet": "SHOP'IMT - Your parcel arrives tomorrow", "rappel_sur": "DELIVERY REMINDER",
        "rappel_titre": "Your parcel arrives tomorrow!",
        "rappel_phrase": "Delivery expected on {date}. Make sure someone is home or let a neighbour know.",
        "jours": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        "mois": ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        "statuts": {
            "EXPEDIEE": ("PARCEL SHIPPED", "Your parcel is on its way!", "It has just been handed to the carrier."),
            "INCIDENT_TRANSPORT": ("TRANSPORT ISSUE", "Your parcel is a little late",
                                   "The carrier reported an issue. Don't worry: delivery resumes as soon as possible."),
            "LIVREE": ("PARCEL DELIVERED", "Your parcel has arrived!", "Thank you for your order, see you soon on SHOP'IMT."),
        },
    },
}
COULEURS_STATUT = {"EXPEDIEE": BLEU, "INCIDENT_TRANSPORT": "#c76a00", "LIVREE": "#1f8a4c"}
STATUTS_EMAIL = set(COULEURS_STATUT)   # seuls ces statuts déclenchent un e-mail


def _t(langue):
    return TEXTES["en" if langue == "en" else "fr"]


def _euros(montant, langue="fr"):
    if langue == "en":
        return f"€{float(montant):,.2f}"
    return f"{float(montant):.2f}".replace(".", ",") + " €"


def _nom(ligne, langue):
    return ligne.get("nom_en") or ligne["nom"] if langue == "en" else ligne["nom"]


def _date(iso, langue):
    d = datetime.date.fromisoformat(iso)
    t = _t(langue)
    if langue == "en":
        return f"{t['jours'][d.weekday()]}, {t['mois'][d.month - 1]} {d.day}"
    return f"{t['jours'][d.weekday()]} {d.day} {t['mois'][d.month - 1]}"


# ---------- Habillage commun

def _ligne_html(ligne, langue):
    nom = html.escape(_nom(ligne, langue))
    image = f"{SITE_URL}/img/{html.escape(ligne['id'])}.png"
    sous_total = _euros(float(ligne["prix_unitaire"]) * ligne["quantite"], langue)
    return f"""
          <tr>
            <td width="96" style="padding:12px 0;border-bottom:1px solid {GRIS};">
              <img src="{image}" width="96" height="72" alt="{nom}" style="display:block;border-radius:8px;background:{GRIS};">
            </td>
            <td style="padding:12px 16px;border-bottom:1px solid {GRIS};font-family:{POLICE};font-size:15px;color:{MARINE};">
              <strong>{nom}</strong><br>
              <span style="font-size:13px;color:#5b6b7c;">{ligne['quantite']} × {_euros(ligne['prix_unitaire'], langue)}</span>
            </td>
            <td align="right" style="padding:12px 0;border-bottom:1px solid {GRIS};font-family:{POLICE};font-size:15px;font-weight:bold;color:{MARINE};white-space:nowrap;">
              {sous_total}
            </td>
          </tr>"""


def _bouton(lien, order_id, langue):
    t = _t(langue)
    return f"""
        <tr><td align="center" style="padding:24px 32px 8px;">
          <table role="presentation" cellpadding="0" cellspacing="0"><tr>
            <td style="border-radius:10px;background:{MARINE};">
              <a href="{lien}" style="display:inline-block;padding:15px 32px;font-family:{POLICE};font-size:16px;font-weight:bold;color:#ffffff;text-decoration:none;border-radius:10px;">{t['suivre']} &rarr;</a>
            </td>
          </tr></table>
          <p style="margin:10px 0 0;font-family:{POLICE};font-size:12px;color:#5b6b7c;">{t['numero']} : <span style="font-family:monospace;">{html.escape(order_id)}</span></p>
        </td></tr>"""


def _page(sujet, apercu, contenu, langue):
    """Habillage commun : logo, liseré bleu IMT, contenu, logo IMT Nord Europe, pied de page."""
    return f"""<!doctype html>
<html lang="{'en' if langue == 'en' else 'fr'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>{html.escape(sujet)}</title></head>
<body style="margin:0;padding:0;background:{GRIS};">
  <div style="display:none;max-height:0;overflow:hidden;">{html.escape(apercu)}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{GRIS};">
    <tr><td align="center" style="padding:24px 12px;">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;">
        <tr><td style="background:{MARINE};padding:24px 32px;">
          <img src="{SITE_URL}/img/logo-email.png" width="196" height="48" alt="SHOP'IMT" style="display:block;">
        </td></tr>
        <tr><td style="height:4px;background:{BLEU};font-size:0;line-height:0;">&nbsp;</td></tr>{contenu}
        <tr><td align="center" style="padding:8px 32px 24px;">
          <img src="{SITE_URL}/img/logo-imt.png" width="110" height="68" alt="IMT Nord Europe" style="display:block;">
        </td></tr>
        <tr><td style="background:{MARINE};padding:20px 32px;font-family:{POLICE};font-size:12px;line-height:1.6;color:#9fb1c2;">
          {_t(langue)['pied']}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>"""


def _entete(sur_titre, couleur, titre, phrase):
    return f"""
        <tr><td style="padding:32px 32px 8px;font-family:{POLICE};color:{MARINE};">
          <p style="margin:0 0 4px;font-size:13px;letter-spacing:2px;color:{couleur};font-weight:bold;">{sur_titre}</p>
          <h1 style="margin:0 0 12px;font-size:26px;line-height:1.2;">{titre}</h1>
          <p style="margin:0;font-size:15px;line-height:1.5;color:#3d4c5e;">{phrase}</p>
        </td></tr>"""


# ---------- Agenda et rappel de livraison

def lien_google(order_id, livraison, langue="fr"):
    d = datetime.date.fromisoformat(livraison)
    t = _t(langue)
    return "https://calendar.google.com/calendar/render?" + urlencode({
        "action": "TEMPLATE",
        "text": t["agenda_titre"],
        "dates": f"{d:%Y%m%d}/{d + datetime.timedelta(days=1):%Y%m%d}",
        "details": f"{t['numero']} {order_id}\n{t['agenda_suivi']} : {SITE_URL}/suivi/{order_id}",
    })


def _bloc_agenda(order_id, livraison, langue):
    if not livraison:
        return ""
    t = _t(langue)
    lien = lambda url, texte: (  # noqa: E731
        f'<a href="{html.escape(url)}" style="display:inline-block;margin:4px;padding:10px 16px;border:1px solid {BLEU};'
        f'border-radius:999px;font-family:{POLICE};font-size:14px;font-weight:bold;color:{MARINE};text-decoration:none;">{texte}</a>')
    return f"""
        <tr><td align="center" style="padding:8px 32px 8px;font-family:{POLICE};">
          <p style="margin:0 0 8px;font-size:15px;color:{MARINE};">{t['livraison']} : <strong>{_date(livraison, langue)}</strong></p>
          {lien(lien_google(order_id, livraison, langue), t['google'])}{lien(f"{SITE_URL}/commandes/{order_id}/agenda", t['apple'])}
        </td></tr>"""


def planifier_rappel(order_id, livraison, arn_fonction):
    """Rappel unique la veille de la livraison, via EventBridge Scheduler (gratuit : 14 M d'appels/mois)."""
    if not (GROUPE_RAPPELS and ROLE_RAPPELS and livraison):
        return
    veille = datetime.date.fromisoformat(livraison) - datetime.timedelta(days=1)
    try:
        scheduler.create_schedule(
            Name=f"rappel-{order_id}", GroupName=GROUPE_RAPPELS,
            ScheduleExpression=f"at({veille.isoformat()}T{HEURE_RAPPEL})", ScheduleExpressionTimezone="Europe/Paris",
            FlexibleTimeWindow={"Mode": "OFF"}, ActionAfterCompletion="DELETE",
            Target={"Arn": arn_fonction, "RoleArn": ROLE_RAPPELS,
                    "Input": json.dumps({"type": "RAPPEL_LIVRAISON", "order_id": order_id})},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConflictException":   # SNS peut livrer deux fois : déjà planifié
            raise
    print(json.dumps({"evenement": "RAPPEL_PLANIFIE", "order_id": order_id, "le": f"{veille} {HEURE_RAPPEL}"}))


def annuler_rappel(order_id):
    if not GROUPE_RAPPELS:
        return
    try:
        scheduler.delete_schedule(Name=f"rappel-{order_id}", GroupName=GROUPE_RAPPELS)
        print(json.dumps({"evenement": "RAPPEL_ANNULE", "order_id": order_id}))
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise


# ---------- Contenu des e-mails

def construire_email(evenement):
    """Renvoie (sujet, html, texte) pour un événement COMMANDE_CREEE."""
    langue = evenement.get("langue", "fr")
    t = _t(langue)
    order_id = evenement["order_id"]
    lien = f"{SITE_URL}/suivi/{order_id}"
    lignes = evenement["articles"]
    nb = sum(ligne["quantite"] for ligne in lignes)
    total = _euros(evenement["total"], langue)
    sujet = t["conf_sujet"].format(id=order_id[:8])
    livraison = evenement.get("livraison_estimee")

    contenu = f"""{_entete(t['conf_sur'], BLEU, t['conf_titre'], t['conf_phrase'].format(nb=nb))}
        {_bouton(lien, order_id, langue)}
        {_bloc_agenda(order_id, livraison, langue)}
        <tr><td style="padding:16px 32px 0;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">{''.join(_ligne_html(ligne, langue) for ligne in lignes)}
            <tr>
              <td colspan="2" style="padding:16px 0;font-family:{POLICE};font-size:17px;font-weight:bold;color:{MARINE};">{t['total']}</td>
              <td align="right" style="padding:16px 0;font-family:{POLICE};font-size:20px;font-weight:bold;color:{MARINE};white-space:nowrap;">{total}</td>
            </tr>
          </table>
        </td></tr>
        <tr><td style="padding:8px 32px 32px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{GRIS};border-radius:12px;">
            <tr><td style="padding:16px 20px;font-family:{POLICE};font-size:13px;line-height:1.6;color:#3d4c5e;">
              {t['conf_ensuite'].format(marine=MARINE)}
            </td></tr>
          </table>
        </td></tr>"""
    corps = _page(sujet, t["conf_apercu"].format(nb=nb, total=total), contenu, langue)

    detail = "\n".join(f"  - {ligne['quantite']} x {_nom(ligne, langue)} ({_euros(ligne['prix_unitaire'], langue)})" for ligne in lignes)
    texte = (
        f"{t['conf_texte'].format(id=order_id)}\n\n{detail}\n\n{t['total']} : {total}\n\n"
        + (f"{t['livraison']} : {_date(livraison, langue)}\n{t['google_texte']} : {lien_google(order_id, livraison, langue)}\n\n"
           if livraison else "")
        + f"{t['suivre_texte']} : {lien}\n\n{t['signature']}"
    )
    return sujet, corps, texte


def construire_email_statut(commande, statut, detail):
    """Renvoie (sujet, html, texte) pour un changement de statut du colis."""
    langue = commande.get("langue") or "fr"
    t = _t(langue)
    order_id = commande["order_id"]
    sur_titre, titre, phrase = t["statuts"][statut]
    lien = f"{SITE_URL}/suivi/{order_id}"
    titre_texte = html.unescape(titre)
    sujet = f"SHOP'IMT - {titre_texte} ({order_id[:8]})"
    infos = [(t["etape"], detail)]
    if commande.get("transporteur"):
        infos.append((t["transporteur"], commande["transporteur"]))
    if commande.get("numero_suivi"):
        infos.append((t["num_suivi"], commande["numero_suivi"]))
    lignes_infos = "".join(
        f'<tr><td style="padding:6px 0;font-family:{POLICE};font-size:13px;color:#5b6b7c;width:120px;">{k}</td>'
        f'<td style="padding:6px 0;font-family:{POLICE};font-size:15px;font-weight:bold;color:{MARINE};">{html.escape(v)}</td></tr>'
        for k, v in infos)
    vignettes = "".join(
        f'<img src="{SITE_URL}/img/{html.escape(a["id"])}.png" width="80" height="60" alt="{html.escape(_nom(a, langue))}" '
        f'style="display:inline-block;margin:0 6px 6px 0;border-radius:8px;background:{GRIS};">'
        for a in commande.get("articles", []))
    contenu = f"""{_entete(sur_titre, COULEURS_STATUT[statut], titre, phrase)}
        <tr><td style="padding:16px 32px 0;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{GRIS};border-radius:12px;">
            <tr><td style="padding:12px 20px;"><table role="presentation" cellpadding="0" cellspacing="0">{lignes_infos}</table></td></tr>
          </table>
        </td></tr>
        <tr><td style="padding:16px 32px 0;">{vignettes}</td></tr>
        {_bouton(lien, order_id, langue)}
        <tr><td style="padding:0 0 24px;">&nbsp;</td></tr>"""
    corps = _page(sujet, f"{titre_texte} {detail}", contenu, langue)
    texte = "\n".join([titre_texte, html.unescape(phrase), ""] + [f"{k} : {v}" for k, v in infos]
                      + ["", f"{t['suivre']} : {lien}", "", t["signature"]])
    return sujet, corps, texte


def construire_email_rappel(commande):
    langue = commande.get("langue") or "fr"
    t = _t(langue)
    order_id = commande["order_id"]
    lien = f"{SITE_URL}/suivi/{order_id}"
    date = _date(commande["livraison_estimee"], langue)
    contenu = f"""{_entete(t['rappel_sur'], BLEU, t['rappel_titre'], t['rappel_phrase'].format(date=date))}
        {_bouton(lien, order_id, langue)}
        <tr><td style="height:24px;"></td></tr>"""
    corps = _page(t["rappel_sujet"], html.unescape(t["rappel_titre"]), contenu, langue)
    texte = f"{html.unescape(t['rappel_titre'])}\n{t['rappel_phrase'].format(date=date)}\n{t['suivre']} : {lien}"
    return t["rappel_sujet"], corps, texte


# ---------- Envoi

def _lire_commande(order_id):
    item = ddb.get_item(TableName=T_COMMANDES, Key={"order_id": {"S": order_id}}).get("Item")
    if not item:
        return None
    s = lambda k: item.get(k, {}).get("S")  # noqa: E731
    articles = json.loads(s("articles") or "[]")  # stockés en JSON par la Lambda commandes
    return {"order_id": order_id, "client_email": s("client_email"), "transporteur": s("transporteur"),
            "numero_suivi": s("numero_suivi"), "articles": articles, "statut": s("statut"),
            "livraison_estimee": s("livraison_estimee"), "langue": s("langue")}


def _demander_verification(adresse):
    """SES envoie à l'adresse un lien de vérification (sandbox). Sans effet si déjà demandé."""
    try:
        ses.create_email_identity(EmailIdentity=adresse, Tags=[{"Key": "Projet", "Value": "shop-imt"},
                                                               {"Key": "Origine", "Value": "verification-auto"}])
    except ClientError as e:
        if e.response["Error"]["Code"] != "AlreadyExistsException":
            print(json.dumps({"evenement": "VERIFICATION_ECHEC", "erreur": e.response["Error"]["Code"]}))
        return
    print(json.dumps({"evenement": "VERIFICATION_DEMANDEE"}))


def _envoyer(destinataire, order_id, sujet, corps, texte, type_email):
    try:
        ses.send_email(
            FromEmailAddress=f"SHOP'IMT <{EXPEDITEUR}>",
            Destination={"ToAddresses": [destinataire]},
            Content={"Simple": {
                "Subject": {"Data": sujet, "Charset": "UTF-8"},
                "Body": {"Html": {"Data": corps, "Charset": "UTF-8"},
                         "Text": {"Data": texte, "Charset": "UTF-8"}},
            }},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "MessageRejected":
            raise  # erreur passagère : l'appelant relancera
        # Sandbox SES : destinataire non vérifié. On le note sans réessayer.
        print(json.dumps({"evenement": "EMAIL_REFUSE", "type": type_email, "order_id": order_id,
                          "raison": e.response["Error"].get("Message", "")}))
        if type_email == "CONFIRMATION":
            _demander_verification(destinataire)
        return
    print(json.dumps({"evenement": "EMAIL_ENVOYE", "type": type_email, "order_id": order_id}))


def handler(event, context):
    if event.get("type") == "RAPPEL_LIVRAISON":  # appel par EventBridge Scheduler, la veille
        commande = _lire_commande(event["order_id"])
        if commande is None or not commande["client_email"] or commande.get("statut") == "LIVREE":
            print(json.dumps({"evenement": "RAPPEL_INUTILE", "order_id": event["order_id"]}))
            return
        sujet, corps, texte = construire_email_rappel(commande)
        _envoyer(commande["client_email"], event["order_id"], sujet, corps, texte, "RAPPEL")
        return
    if event.get("type") == "STATUT_COLIS":  # appel direct depuis Step Functions
        if event["statut"] == "LIVREE":
            annuler_rappel(event["order_id"])
        if event["statut"] not in STATUTS_EMAIL:
            return
        commande = _lire_commande(event["order_id"])
        if commande is None or not commande["client_email"]:
            return
        sujet, corps, texte = construire_email_statut(commande, event["statut"], event.get("detail", ""))
        _envoyer(commande["client_email"], event["order_id"], sujet, corps, texte, event["statut"])
        return
    for record in event.get("Records", []):
        evenement = json.loads(record["Sns"]["Message"])
        sujet, corps, texte = construire_email(evenement)
        _envoyer(evenement["client_email"], evenement["order_id"], sujet, corps, texte, "CONFIRMATION")
        planifier_rappel(evenement["order_id"], evenement.get("livraison_estimee"), context.invoked_function_arn)
