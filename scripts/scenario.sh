#!/usr/bin/env bash
# Scénario de test de bout en bout sur un environnement déployé, à lancer depuis la racine du dépôt.
# Prérequis : curl, jq, AWS CLI configuré (région eu-west-3), terraform init fait dans infra/envs/<env>.
# Usage : scripts/scenario.sh [dev|prod] [email]
set -euo pipefail

ENV="${1:-dev}"
EMAIL="${2:-test@example.com}"
sortie() { terraform -chdir="infra/envs/$ENV" output -raw "$1"; }
API=$(sortie api_url)
TABLE=$(sortie table_commandes)
BUCKET=$(sortie bucket_audit)
export AWS_REGION="${AWS_REGION:-eu-west-3}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-3}"

titre() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

titre "1. Catalogue (GET /produits)"
curl -sf "$API/produits" | jq -r '.[] | "\(.id)  \(.nom)  \(.prix) €  stock=\(.stock)"'

titre "2. Commandes invalides (attendu : 400 puis 409)"
curl -s -o /dev/null -w "produit inconnu   -> HTTP %{http_code}\n" -X POST "$API/commandes" \
  -H 'Content-Type: application/json' -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p999\",\"quantite\":1}]}"
curl -s -o /dev/null -w "stock insuffisant -> HTTP %{http_code}\n" -X POST "$API/commandes" \
  -H 'Content-Type: application/json' -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p006\",\"quantite\":10}]}" || true

titre "3. Commande valide (POST /commandes)"
REPONSE=$(curl -sf -X POST "$API/commandes" -H 'Content-Type: application/json' \
  -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p001\",\"quantite\":2},{\"id\":\"p003\",\"quantite\":1}]}")
echo "$REPONSE" | jq .
ID=$(echo "$REPONSE" | jq -r .order_id)

titre "4. Suivi du traitement asynchrone (Streams -> SNS -> SQS -> Lambda -> Step Functions)"
PRECEDENT=""
for i in $(seq 1 60); do
  STATUT=$(curl -sf "$API/commandes/$ID" | jq -r .statut)
  [ "$STATUT" != "$PRECEDENT" ] && echo "  t+$((i*2))s : $STATUT"
  PRECEDENT=$STATUT
  [ "$STATUT" = "LIVREE" ] && break
  sleep 2
done
curl -sf "$API/commandes/$ID" | jq '{statut, transporteur, numero_suivi, historique}'
SITE=$(sortie site_url)
echo "  Page de suivi : $SITE/suivi/$ID"

titre "5. Enregistrement en base (DynamoDB)"
aws dynamodb get-item --table-name "$TABLE" --key "{\"order_id\":{\"S\":\"$ID\"}}" \
  --query 'Item.{statut:statut.S,total:total.N,client:client_email.S}' --output table

titre "6. Trace d'audit (S3)"
sleep 3
CLE=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix audit/ \
  --query "Contents[?ends_with(Key, '$ID.json')].Key | [0]" --output text)
echo "  s3://$BUCKET/$CLE"
aws s3 cp "s3://$BUCKET/$CLE" - | jq .

titre "7. Exécution Step Functions"
MACHINE=$(sortie machine_expedition)
aws stepfunctions describe-execution --execution-arn "${MACHINE/:stateMachine:/:execution:}:$ID" \
  --query '{statut:status,debut:startDate,fin:stopDate}' --output table

titre "8. Interface admin (attendu : 401 sans jeton, puis 403 pour un compte hors groupe, 200 pour un admin)"
curl -s -o /dev/null -w "GET /admin/stats sans jeton -> HTTP %{http_code}\n" "$API/admin/stats"
aws lambda invoke --function-name "$(sortie fonction_admin)" --cli-binary-format raw-in-base64-out \
  --payload '{"routeKey":"GET /admin/stats","queryStringParameters":{"jours":"7"},"requestContext":{"authorizer":{"jwt":{"claims":{"email":"scenario","cognito:groups":"[admins]"}}}}}' \
  /tmp/shopimt-admin.json > /dev/null
SEMAINE=$(jq -r '.body' /tmp/shopimt-admin.json | jq -c '{commandes, chiffre_affaires, panier_moyen}')
echo "Stats 7 jours (Lambda admin, groupe admins simulé) : $SEMAINE"

titre "Terminé"
echo "Si $EMAIL est l'adresse abonnée (notification_email), l'e-mail de confirmation est arrivé."
