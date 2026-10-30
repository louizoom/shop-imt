# SHOP'IMT

Boutique en ligne des étudiants de l'IMT Nord Europe sur AWS, en **deux solutions qui tournent en parallèle**
(**serverless** et **machines virtuelles EC2**), décrite entièrement en **Terraform**,
avec deux environnements (**dev** et **prod**) et un front **Vue 3 + TypeScript** bilingue (français / anglais).

Projet du cours AWS : boutique en ligne avec SNS et une file de messages, en Terraform.

## Architecture

```
Navigateur ──► CloudFront ──► S3 (front Vue compilé)
                  │  CloudFront Functions : langue (cookie lang) et routage (/suivi/…, /admin)
                  └──► API Gateway HTTP ──► Lambda (catalogue, commandes, compte, admin)
                                               │
                         DynamoDB ◄────────────┤ (commandes, produits, stock atomique)
                                               ▼
                             SNS (commande créée) ──► SQS ──► Step Functions (préparation, expédition, livraison)
                                                       │
                                                       └──► Lambda notification ──► SES (e-mails FR/EN)
```

| Service | Rôle |
| --- | --- |
| CloudFront, S3 | Site statique, cache, en-têtes de sécurité, accès S3 privé (OAC) |
| CloudFront Functions | Langue par défaut d'après `Accept-Language`, routage des pages du front |
| API Gateway HTTP | API REST, autorisateur JWT Cognito pour `/compte/*` et `/admin/*` |
| Lambda (Python 3.12, arm64) | Logique métier |
| DynamoDB | Commandes, catalogue, stock (mise à jour conditionnelle) |
| SNS, SQS | Bus d'événements des commandes, file d'attente et DLQ |
| Step Functions | Cycle de vie simulé d'une commande |
| SES v2 | E-mails de confirmation, de suivi et de rappel, dans la langue de la commande |
| Cognito | Comptes clients, groupes `admins`, `ventes` et `stock` (rôles de la console de gestion) |
| EventBridge Scheduler | Récapitulatif quotidien, rappel la veille de la livraison |
| Amazon Translate | Nom anglais des produits, traduit une fois puis gardé en cache dans DynamoDB |
| CloudWatch | Logs, métriques EMF (ventes), tableau de bord, alarmes |
| SSM Parameter Store | Réglages personnels (adresses e-mail) hors du dépôt |
| Trusted Advisor | Contrôles de bonnes pratiques du compte (sécurité, quotas) ; une règle EventBridge dans us-east-1 envoie par e-mail (SNS) tout contrôle qui passe en orange ou rouge, en prod seulement (le compte est commun) |
| IAM + OIDC GitHub | Déploiement depuis GitHub Actions sans clé d'accès stockée, groupe `shopimt-stock` en moindre privilège |

## Solution EC2 (machines virtuelles)

La même boutique (même front, même API, mêmes e-mails), sur des serveurs, à côté de la solution serverless :

```
Navigateur ──► CloudFront ──► ALB (2 zones) ──► Auto Scaling group : serveurs web t3.micro (Flask + gunicorn)
                                                    │                       │
                                                    ▼                       ▼
                                     RDS MySQL 8.4 (sous-réseaux privés)   SNS ──► SQS ──┐
                                                    ▲                                    ▼
                                                    └──────── serveur de traitement t3.micro : workers + Apache Kafka (KRaft)
                                                               │  topic « commandes » : groupes audit (S3) et e-mails (SES)
```

| Service | Rôle |
| --- | --- |
| VPC | 2 zones, sous-réseaux publics (ALB, serveurs) et privés (RDS, sans route Internet), endpoint Gateway S3 |
| EC2, Auto Scaling | Serveurs web dans un groupe de 1 à 2 instances réparties sur 2 zones, montée en charge sur le CPU, remplacement automatique d'une instance malade, mise à jour progressive (instance refresh) |
| Elastic Load Balancing (ALB) | Répartition de charge, contrôle de santé `/sante`, accepte seulement CloudFront (liste de préfixes + en-tête secret) |
| RDS for MySQL | Catalogue, commandes, historique ; transaction avec `SELECT … FOR UPDATE` pour le stock, TLS obligatoire, chiffrement KMS |
| SNS, SQS | `COMMANDE_CREEE` diffusé vers la file de traitement (long polling, DLQ) |
| Apache Kafka sur EC2 | Flux du cycle de vie des commandes, deux groupes de consommateurs (audit S3, e-mails de suivi) ; MSK serait l'équivalent géré, hors Free Tier |
| SSM | Mot de passe RDS en SecureString, Session Manager à la place de SSH |
| CloudWatch | Agent (logs, mémoire), alarmes, récupération automatique du serveur de traitement, tableau de bord |

- **Activation** : clé `solution_ec2` (`true`) du paramètre SSM `/shopimt/<env>/config`, puis `terraform apply`.
  `false` détruit la solution EC2 sans toucher au serverless.
- **Code** : `backend/ec2/` réutilise les modules des Lambdas (validation, numéros de commande, plan d'expédition, e-mails).
- **Coût** : RDS, ALB et une instance sont dans le Free Tier 12 mois ; la 2e instance et les adresses IPv4 publiques
  coûtent environ 0,60 $ par jour. À désactiver après la démonstration.

## Organisation du dépôt

```
backend/
  lambdas/           Code des fonctions Lambda (une par fichier)
  ec2/               Serveurs de la solution EC2 (web et traitement)
  tests/             Parcours complet avec un faux boto3 (pytest)
frontend/            Vue 3, TypeScript, Vite, vue-i18n, Vue Router
  src/i18n/          Textes fr.ts et en.ts (mêmes clés, vérifié par TypeScript et un test)
  src/views/         Pages : boutique, suivi, compte, admin
  src/components/    NavBar, sélecteur de langue, carte produit, panier, fiche de suivi
infra/
  modules/boutique/  Solution serverless, paramétrée (préfixe, capacités…)
  modules/ec2/       Solution EC2 : VPC, ALB, Auto Scaling, RDS, SNS/SQS, Kafka
  envs/dev/          Environnement dev : état S3 dev/terraform.tfstate
  envs/prod/         Environnement prod : état S3 prod/terraform.tfstate
  bootstrap/         Bucket d'état et rôles GitHub OIDC, créés une seule fois
scripts/scenario.sh  Test de bout en bout sur un environnement déployé
docs/                LLD (PDF) et présentation
```

## Nom de domaine

Facultatif, par environnement, dans le paramètre SSM (`domaine_site`, `domaine_site_actif`). Le certificat est
demandé à **ACM** en `us-east-1` (seule région lue par CloudFront), gratuit et renouvelé automatiquement.
Le domaine étant chez un autre registraire, il n'y a pas de zone Route 53 (payante) :

1. `domaine_site` renseigné, `terraform apply`, puis créer chez le registraire les enregistrements de la sortie `dns_site`
   (CNAME de validation du certificat, CNAME du site vers CloudFront) ;
2. quand `certificat_statut` vaut `ISSUED`, passer `domaine_site_actif` à `true` et relancer `terraform apply` :
   CloudFront répond sur le domaine et les e-mails pointent vers lui.

## Numéros de commande

`SHOP-000042-K7QF` : le nombre vient d'un compteur atomique DynamoDB (`UpdateItem ADD` sur la ligne `#compteur`
de la table commandes, seule ligne que la Lambda peut incrémenter), les 4 caractères aléatoires empêchent de
deviner la commande d'un autre client. Les e-mails affichent `SHOP-000042`. Les anciennes commandes (UUID)
restent consultables.

## Rôles

Les rôles existent des deux côtés, sur le même principe : chacun n'a que ce dont il a besoin.

| Rôle | Site (groupe Cognito) | Console AWS (IAM) |
| --- | --- | --- |
| Admin | `admins` : ventes, export CSV, stock | administrateur |
| Ventes | `ventes` : graphiques et commandes, sans export ni stock | |
| Stock | `stock` : onglet Stock seulement (réassort +/-) | groupe `shopimt-stock` : lecture du catalogue DynamoDB et modification du seul attribut `stock` (condition `dynamodb:Attributes`), logs de la Lambda admin |

- **Site** : API Gateway vérifie le jeton (401), puis la Lambda `admin` vérifie le rôle route par route (403,
  tentative journalisée `ADMIN_REFUSE`). Le front n'affiche que les onglets permis.
- **Membres** : clés `admins`, `lecteurs_ventes` et `gestionnaires_stock` du paramètre SSM `/shopimt/<env>/config`.
  Un membre doit se reconnecter pour recevoir son nouveau rôle.
- **IAM** : `infra/bootstrap`, variable `utilisateurs_stock`.

## Développement local

Prérequis : Node 22, Python 3.12, Terraform 1.10 ou plus.

```bash
# Front : serveur Vite, les appels /produits, /commandes… partent vers l'API de prod (ou VITE_API)
cd frontend
npm install
npm run dev
VITE_API=https://<distribution-dev>.cloudfront.net npm run dev   # pour viser dev

npm run lint          # ESLint (Vue + TypeScript)
npm run format        # Prettier
npm test              # Vitest
npm run build         # vue-tsc puis build Vite dans frontend/dist

# Lambdas
pip install pytest ruff
ruff check .
pytest
```

## Langues (FR / EN)

- **Front** : vue-i18n, textes dans `frontend/src/i18n`. Choix mémorisé dans le navigateur.
- **CloudFront Function** `langue` : à la première visite, dépose le cookie `lang` d'après la langue du navigateur.
- **Amazon Translate** : le catalogue renvoie `nom_en`, traduit à la première demande puis stocké dans DynamoDB.
- **E-mails** : la commande garde sa langue, les e-mails SES (confirmation, statut, rappel) sont envoyés dans cette langue.

## Environnements

| | dev | prod |
| --- | --- | --- |
| Préfixe des ressources | `shopimt-dev` | `shopimt-sls` |
| Capacité DynamoDB | 1 RCU/WCU | 5 RCU/WCU |
| Identités SES | partagées (gérées par prod) | domaine et adresses vérifiées |
| Branche Git | `dev` | `main` |
| Déploiement | à chaque push sur `dev` | à chaque push sur `main`, avec validation |

Les deux environnements utilisent exactement le même module : seules les valeurs de `infra/envs/<env>/main.tf` changent.

## Première installation sur un compte AWS

1. **Socle** (une fois, avec un compte administrateur) :
   ```bash
   cd infra/bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
   terraform init && terraform plan -out tfplan && terraform apply tfplan
   rm backend_override.tf && terraform init -migrate-state   # range l'état du socle dans S3
   ```
2. **Réglages personnels** dans SSM (un JSON par environnement) :
   ```bash
   aws ssm put-parameter --name /shopimt/prod/config --type String --value '{
     "notification_email": "moi@exemple.fr", "domaine_email": "shop.exemple.fr", "expediteur_domaine": true,
     "emails_verifies": [], "admins": ["moi@exemple.fr"], "gestionnaires_stock": [], "lecteurs_ventes": [],
     "budget_email": ""}'
   ```
3. **GitHub** : dans *Settings > Secrets and variables > Actions > Variables*, créer `AWS_ROLE_PLAN` et
   `AWS_ROLE_DEPLOY` (sorties `role_plan` et `role_deploiement` du socle), puis les environnements `dev` et `prod`
   dans *Settings > Environments* (avec *Required reviewers* sur `prod`).
4. **Déploiement** : push sur `dev` pour l'environnement dev, merge de `dev` dans `main` pour la prod
   (ou *Actions > Deploy > Run workflow*).
   En local : `cd infra/envs/dev && terraform init && terraform plan -out tfplan && terraform apply tfplan`.

## Branches

- `dev` : branche de travail. On y fusionne les pull requests des branches de fonctionnalité ; chaque push déploie dev.
- `main` : ce qui tourne en prod. On y fusionne `dev` par une pull request quand dev est validé.

## Intégration continue

`.github/workflows/ci.yml`, à chaque pull request :

- Lambdas : `ruff` et `pytest`
- Front : ESLint, Prettier, Vitest, vérification des types, build
- Terraform : `fmt`, `validate`, puis **`terraform plan` de dev et de prod** (rôle IAM en lecture seule via OIDC),
  affiché dans le résumé du workflow

`.github/workflows/deploy.yml` applique le plan. Aucune clé AWS n'est stockée dans GitHub : chaque exécution reçoit
des identifiants temporaires d'une heure.

## Coûts

Tout reste dans l'offre gratuite AWS pour un usage de projet étudiant : pas de NAT, pas de MSK, pas de KMS dédié,
DynamoDB en capacité provisionnée : 2 tables et 2 index, 5 unités chacun en prod et 1 en dev, soit 24 des 25 unités gratuites.
