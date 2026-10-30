#!/usr/bin/env bash
# Scénario de test de bout en bout de la solution EC2 (solution_ec2 = true), à lancer depuis la racine du dépôt.
# Prérequis : curl, jq, AWS CLI configuré (région eu-west-3), terraform init fait dans infra/envs/<env>.
# Usage : scripts/scenario-ec2.sh [dev|prod] [email]
set -euo pipefail

ENV="${1:-dev}"
EMAIL="${2:-test@example.com}"
sortie() { terraform -chdir="infra/envs/$ENV" output -raw "$1"; }
ressource() { terraform -chdir="infra/envs/$ENV" output -json ec2 | jq -r ".$1"; }
SITE=$(sortie ec2_site_url)
[ -n "$SITE" ] || { echo "Solution EC2 désactivée : passer solution_ec2 à true dans /shopimt/$ENV/config"; exit 1; }
BUCKET=$(ressource bucket)
export AWS_REGION="${AWS_REGION:-eu-west-3}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-3}"

titre() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

titre "1. Serveurs web derrière l'ALB (Auto Scaling group)"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$(ressource auto_scaling_group)" \
  --query 'AutoScalingGroups[0].Instances[].{instance:InstanceId,zone:AvailabilityZone,sante:HealthStatus}' --output table
curl -s -o /dev/null -w "ALB en direct, sans CloudFront (attendu : 403) -> HTTP %{http_code}\n" "http://$(ressource alb)/sante"
curl -sf "$SITE/sante" | jq -c .

titre "2. Catalogue (GET /produits, lu dans RDS MySQL)"
curl -sf "$SITE/produits" | jq -r '.[] | "\(.id)  \(.nom)  \(.prix) €  stock=\(.stock)"'

titre "3. Commandes invalides (attendu : 400 puis 409)"
curl -s -o /dev/null -w "produit inconnu   -> HTTP %{http_code}\n" -X POST "$SITE/commandes" \
  -H 'Content-Type: application/json' -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p999\",\"quantite\":1}]}"
curl -s -o /dev/null -w "stock insuffisant -> HTTP %{http_code}\n" -X POST "$SITE/commandes" \
  -H 'Content-Type: application/json' -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p006\",\"quantite\":10}]}" || true

titre "4. Commande valide (POST /commandes, transaction MySQL puis SNS et Kafka)"
REPONSE=$(curl -sf -X POST "$SITE/commandes" -H 'Content-Type: application/json' \
  -d "{\"client_email\":\"$EMAIL\",\"articles\":[{\"id\":\"p001\",\"quantite\":2},{\"id\":\"p003\",\"quantite\":1}]}")
echo "$REPONSE" | jq .
ID=$(echo "$REPONSE" | jq -r .order_id)

titre "5. Suivi du traitement (SNS -> SQS -> serveur de traitement -> Kafka)"
PRECEDENT=""
for i in $(seq 1 60); do
  STATUT=$(curl -sf "$SITE/commandes/$ID" | jq -r .statut)
  [ "$STATUT" != "$PRECEDENT" ] && echo "  t+$((i*2))s : $STATUT"
  PRECEDENT=$STATUT
  [ "$STATUT" = "LIVREE" ] && break
  sleep 2
done
curl -sf "$SITE/commandes/$ID" | jq '{statut, transporteur, numero_suivi, historique}'
echo "  Page de suivi : $SITE/suivi/$ID"

titre "6. Trace d'audit écrite par le groupe Kafka « audit » (S3)"
sleep 3
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "audit/$(date -u +%Y/%m/%d)/$ID/" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' | sed "s|^|  s3://$BUCKET/|"

titre "Terminé"
echo "Si $EMAIL est une adresse vérifiée dans SES, les e-mails de confirmation et de suivi sont arrivés."
echo "Tableau de bord CloudWatch : $(ressource tableau_de_bord)"
