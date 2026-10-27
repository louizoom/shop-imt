# SHOP'IMT

Boutique en ligne des étudiants de l'IMT Nord Europe, en **serverless sur AWS**, décrite entièrement en **Terraform**,
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
| Cognito | Comptes clients, groupe `admins` pour la console |
| EventBridge Scheduler | Récapitulatif quotidien, rappel la veille de la livraison |
| Amazon Translate | Nom anglais des produits, traduit une fois puis gardé en cache dans DynamoDB |
| CloudWatch | Logs, métriques EMF (ventes), tableau de bord, alarmes |
| SSM Parameter Store | Réglages personnels (adresses e-mail) hors du dépôt |
| IAM + OIDC GitHub | Déploiement depuis GitHub Actions sans clé d'accès stockée |

## Organisation du dépôt

```
backend/
  lambdas/           Code des fonctions Lambda (une par fichier)
  tests/             Parcours complet avec un faux boto3 (pytest)
frontend/            Vue 3, TypeScript, Vite, vue-i18n, Vue Router
  src/i18n/          Textes fr.ts et en.ts (mêmes clés, vérifié par TypeScript et un test)
  src/views/         Pages : boutique, suivi, compte, admin
  src/components/    NavBar, sélecteur de langue, carte produit, panier, fiche de suivi
infra/
  modules/boutique/  Toute l'infrastructure, paramétrée (préfixe, capacités…)
  envs/dev/          Environnement dev : état S3 dev/terraform.tfstate
  envs/prod/         Environnement prod : état S3 prod/terraform.tfstate
  bootstrap/         Bucket d'état et rôles GitHub OIDC, créés une seule fois
scripts/scenario.sh  Test de bout en bout sur un environnement déployé
docs/                LLD (PDF) et présentation
```

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
| Déploiement | à chaque push sur `main` | à la demande, avec validation |

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
     "emails_verifies": [], "admins": ["moi@exemple.fr"], "budget_email": ""}'
   ```
3. **GitHub** : dans *Settings > Secrets and variables > Actions > Variables*, créer `AWS_ROLE_PLAN` et
   `AWS_ROLE_DEPLOY` (sorties `role_plan` et `role_deploiement` du socle), puis les environnements `dev` et `prod`
   dans *Settings > Environments* (avec *Required reviewers* sur `prod`).
4. **Déploiement** : push sur `main` pour dev, *Actions > Deploy > Run workflow > prod* pour la prod.
   En local : `cd infra/envs/dev && terraform init && terraform plan -out tfplan && terraform apply tfplan`.

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
