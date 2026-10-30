# SHOP'IMT : guide pas à pas

Projet AWS FISA 2026 · Louison, Gabin et Félix

Ce guide explique tout ce qu'il faut faire : retrouver les rendus, montrer la démo, redéployer le projet sur un
compte AWS, jouer les scénarios de test, puis tout arrêter. Le détail technique est dans le `README.md`.

## 1. Les rendus (consigne, partie 4)

| Rendu | Fichier |
| --- | --- |
| 4.1 Présentation | `docs/SHOP-IMT-presentation.pptx` (13 slides, l'orateur est indiqué sur chaque slide, le texte à dire est dans les notes) |
| 4.2 Rapport | `docs/SHOP-IMT-rapport.pdf` (rapport + LLD serverless en annexe A + LLD EC2 en annexe B) |
| 4.3 Terraform et tests | dossier `infra/`, scripts `scripts/scenario.sh` et `scripts/scenario-ec2.sh`, sections 3 à 5 ci-dessous |

Les LLD existent aussi séparément : `docs/SHOP-IMT-LLD.pdf` (serverless) et `docs/SHOP-IMT-EC2-LLD.pdf` (EC2).

## 2. La démo (rien à installer)

Les deux solutions tournent déjà en même temps sur notre compte AWS :

| | Serverless | EC2 |
| --- | --- | --- |
| Prod | https://shopimt.prodhommed.fr | https://d16dvaumexekob.cloudfront.net |
| Dev | https://d2953k75zk1mhb.cloudfront.net | https://dwpgpgkoyjtum.cloudfront.net |

Déroulé conseillé :

1. Ouvrir le site serverless, ajouter deux produits au panier, commander avec une adresse vérifiée dans SES.
2. Montrer le numéro `SHOP-000042-K7QF`, la page de suivi qui avance toute seule jusqu'à « Livrée », puis l'e-mail.
3. Refaire la même commande sur le site EC2 : même site, même e-mail, autre infrastructure.
4. Dans la console AWS : Step Functions (serverless), groupe cible de l'ALB et Auto Scaling (EC2), fichiers
   `audit/` dans S3, tableaux de bord CloudWatch.
5. Résilience EC2 : arrêter le serveur web dans la console EC2. L'ALB le retire, l'Auto Scaling en relance un.

SES est en mode sandbox : seules les adresses vérifiées dans SES reçoivent les e-mails. Pour le jury, ajouter son
adresse dans `emails_verifies` (section 3, étape 3) ou commander avec une des nôtres.

## 3. Déployer sur un compte AWS

### Prérequis

- Un compte AWS avec un utilisateur administrateur, et l'AWS CLI configurée en `eu-west-3`
  (`aws configure`, puis `aws sts get-caller-identity` pour vérifier).
- Terraform 1.10 ou plus, Node 22, Python 3.12, `jq` et `curl`.

### Étapes

1. **Construire le front** (Terraform le dépose dans S3) :
   ```bash
   cd frontend && npm install && npm run build && cd ..
   ```
2. **Créer le socle**, une seule fois par compte (bucket d'état Terraform et rôles GitHub) :
   ```bash
   cd infra/bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
   terraform init && terraform plan -out tfplan && terraform apply tfplan
   cd ../..
   ```
   Sur notre compte, c'est déjà fait. Sur un autre compte, le bucket s'appelle `shopimt-tfstate-<numéro du compte>`.
3. **Écrire les réglages** dans SSM, un JSON par environnement (ici dev) :
   ```bash
   aws ssm put-parameter --name /shopimt/dev/config --type String --overwrite --value '{
     "notification_email": "moi@exemple.fr", "domaine_email": "", "expediteur_domaine": false,
     "emails_verifies": ["moi@exemple.fr"], "admins": ["moi@exemple.fr"], "gestionnaires_stock": [],
     "lecteurs_ventes": [], "budget_email": "", "solution_ec2": true}'
   ```
   `"solution_ec2": true` déploie aussi la solution EC2 ; `false` ne déploie que le serverless.
4. **Déployer** :
   ```bash
   cd infra/envs/dev
   terraform init                                                    # sur notre compte
   terraform init -backend-config="bucket=shopimt-tfstate-<numéro>"  # sur un autre compte
   terraform plan -out tfplan
   terraform apply tfplan
   terraform output site_url ec2_site_url
   cd ../../..
   ```
   Compter environ 5 minutes pour le serverless (CloudFront), et 15 minutes de plus avec EC2 (RDS, puis
   installation des serveurs).
5. **Confirmer les e-mails** : c'est l'environnement prod qui déclare les adresses dans SES (dev partage le même
   compte). Si vous ne déployez que dev sur un nouveau compte, déclarez l'adresse à la main :
   `aws sesv2 create-email-identity --email-identity moi@exemple.fr`. AWS envoie alors un lien de vérification,
   il faut cliquer dessus.

Sur notre dépôt GitHub, le déploiement se fait aussi tout seul : un push sur `dev` déploie dev, une fusion de `dev`
dans `main` déploie la prod après approbation.

## 4. Scénarios de test

Depuis la racine du projet, une fois le déploiement terminé :

```bash
scripts/scenario.sh dev moi@exemple.fr       # solution serverless
scripts/scenario-ec2.sh dev moi@exemple.fr   # solution EC2
```

| Étape | Serverless | EC2 |
| --- | --- | --- |
| Infrastructure | | Instances de l'Auto Scaling group, ALB fermé sans CloudFront (403) |
| Catalogue | `GET /produits` (DynamoDB) | `GET /produits` (RDS MySQL) |
| Erreurs attendues | produit inconnu 400, stock insuffisant 409 | idem |
| Commande | `POST /commandes`, numéro `SHOP-…` | idem, transaction MySQL |
| Traitement | statuts jusqu'à `LIVREE` (Step Functions) | statuts jusqu'à `LIVREE` (SQS, Kafka) |
| Audit | fichier dans S3, ligne DynamoDB | fichiers écrits dans S3 par le groupe Kafka `audit` |
| Admin | 401 sans jeton, 200 pour un admin | |

## 5. Tests sans AWS

```bash
pip install pytest ruff -r backend/ec2/requirements.txt
ruff check . && pytest                                   # à la racine
cd frontend && npm run lint && npm test && npm run build
```

Les tests de la solution EC2 ont besoin d'une base MySQL (`SHOPIMT_TEST_BDD=127.0.0.1`), sinon ils sont sautés.
La CI GitHub les lance avec MySQL 8.4 à chaque pull request.

## 6. Coût et arrêt après la soutenance

- Serverless : environ 0 $, dans l'offre gratuite.
- EC2 : environ 0,60 $ par jour (adresses IPv4 publiques et 2e instance).

Pour couper la solution EC2 sans toucher au serverless : passer `"solution_ec2": false` dans
`/shopimt/<env>/config`, puis `terraform plan -out tfplan && terraform apply tfplan` dans `infra/envs/<env>`
(ou un nouveau déploiement par GitHub). Pour tout supprimer : `terraform destroy` dans `infra/envs/dev` puis
`infra/envs/prod`, et en dernier dans `infra/bootstrap`.

## 7. Envoyer le projet par mail

Gmail refuse les zip qui contiennent des fichiers `.js`, ce qui est le cas de ce projet. Passer par la messagerie de
l'IMT (Zimbra), par un lien Google Drive, ou par le lien de téléchargement GitHub :
https://github.com/louizoom/shop-imt/archive/refs/heads/main.zip
