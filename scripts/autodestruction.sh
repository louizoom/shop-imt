#!/usr/bin/env bash
# Nettoyage final du compte AWS, lancé par le workflow « Autodestruction » après terraform destroy de prod et dev.
# Supprime ce que Terraform ne gère pas (ou ne peut pas supprimer de lui-même), dans cet ordre :
#   reste  : ressources de test, paramètres SSM, journaux CloudWatch, identités SES, utilisateurs et groupes IAM,
#            budget du projet
#   socle  : bucket d'état Terraform (toutes les versions), rôle GitHub de lecture, fournisseur OIDC, puis retrait
#            des droits du rôle de déploiement (en dernier, car le workflow s'en sert pour s'authentifier)
# Usage : scripts/autodestruction.sh reste|socle [--simulation]
# En simulation, les commandes sont affichées sans être lancées.
set -uo pipefail

ETAPE="${1:?reste ou socle}"
SIMULATION="${2:-}"
export AWS_REGION="${AWS_REGION:-eu-west-3}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-3}"
COMPTE=$(aws sts get-caller-identity --query Account --output text)
ECHECS=0

lancer() {
  if [ "$SIMULATION" = "--simulation" ]; then
    echo "  [simulation] $*"
  else
    echo "  $*"
    "$@" >/dev/null || { echo "    échec (ignoré)"; ECHECS=$((ECHECS + 1)); }
  fi
}
titre() { printf '\n== %s\n' "$1"; }

vider_bucket() {
  local bucket=$1 lot
  if [ "$SIMULATION" = "--simulation" ]; then
    echo "  [simulation] vider puis supprimer s3://$bucket (toutes les versions)"
    return
  fi
  while :; do
    lot=$(aws s3api list-object-versions --bucket "$bucket" --max-items 500 --output json \
      --query '{Objects: [Versions[].{Key: Key, VersionId: VersionId}, DeleteMarkers[].{Key: Key, VersionId: VersionId}][]}')
    [ "$(echo "$lot" | jq '.Objects | length')" -gt 0 ] || break
    aws s3api delete-objects --bucket "$bucket" --delete "$(echo "$lot" | jq -c '. + {Quiet: true}')" >/dev/null || break
  done
  lancer aws s3api delete-bucket --bucket "$bucket"
}

supprimer_utilisateur() {
  local u=$1
  aws iam get-user --user-name "$u" >/dev/null 2>&1 || return 0
  for k in $(aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    lancer aws iam delete-access-key --user-name "$u" --access-key-id "$k"
  done
  aws iam get-login-profile --user-name "$u" >/dev/null 2>&1 && lancer aws iam delete-login-profile --user-name "$u"
  for m in $(aws iam list-mfa-devices --user-name "$u" --query 'MFADevices[].SerialNumber' --output text); do
    lancer aws iam deactivate-mfa-device --user-name "$u" --serial-number "$m"
  done
  for p in $(aws iam list-attached-user-policies --user-name "$u" --query 'AttachedPolicies[].PolicyArn' --output text); do
    lancer aws iam detach-user-policy --user-name "$u" --policy-arn "$p"
  done
  for p in $(aws iam list-user-policies --user-name "$u" --query 'PolicyNames[]' --output text); do
    lancer aws iam delete-user-policy --user-name "$u" --policy-name "$p"
  done
  for g in $(aws iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' --output text); do
    lancer aws iam remove-user-from-group --user-name "$u" --group-name "$g"
  done
  lancer aws iam delete-user --user-name "$u"
}

supprimer_groupe() {
  local g=$1
  aws iam get-group --group-name "$g" >/dev/null 2>&1 || return 0
  for p in $(aws iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyArn' --output text); do
    lancer aws iam detach-group-policy --group-name "$g" --policy-arn "$p"
  done
  for p in $(aws iam list-group-policies --group-name "$g" --query 'PolicyNames[]' --output text); do
    lancer aws iam delete-group-policy --group-name "$g" --policy-name "$p"
  done
  lancer aws iam delete-group --group-name "$g"
}

supprimer_role() {
  local r=$1
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || return 0
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    lancer aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text); do
    lancer aws iam delete-role-policy --role-name "$r" --policy-name "$p"
  done
  lancer aws iam delete-role --role-name "$r"
}

if [ "$ETAPE" = "reste" ]; then
  titre "Ressources de test boutique-test (créées à la main le 27 octobre)"
  aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$COMPTE:boutique-test-commandes" >/dev/null 2>&1 &&
    lancer aws sns delete-topic --topic-arn "arn:aws:sns:$AWS_REGION:$COMPTE:boutique-test-commandes"
  URL=$(aws sqs get-queue-url --queue-name boutique-test-audit --query QueueUrl --output text 2>/dev/null) &&
    lancer aws sqs delete-queue --queue-url "$URL"
  aws dynamodb describe-table --table-name boutique-test-commandes >/dev/null 2>&1 &&
    lancer aws dynamodb delete-table --table-name boutique-test-commandes
  aws s3api head-bucket --bucket "boutique-test-catalogue-$COMPTE" 2>/dev/null && vider_bucket "boutique-test-catalogue-$COMPTE"

  titre "Paramètres SSM /shopimt/"
  for p in $(aws ssm get-parameters-by-path --path /shopimt --recursive --query 'Parameters[].Name' --output text); do
    lancer aws ssm delete-parameter --name "$p"
  done

  titre "Journaux CloudWatch restants (créés par les services eux-mêmes)"
  for prefixe in /aws/lambda/shopimt /aws/apigateway/shopimt /aws/rds/instance/shopimt /aws/vendedlogs/states/shopimt /shopimt/; do
    for g in $(aws logs describe-log-groups --log-group-name-prefix "$prefixe" --query 'logGroups[].logGroupName' --output text); do
      lancer aws logs delete-log-group --log-group-name "$g"
    done
  done

  titre "Identités SES (domaine et adresses vérifiées)"
  for i in $(aws sesv2 list-email-identities --query 'EmailIdentities[].IdentityName' --output text); do
    lancer aws sesv2 delete-email-identity --email-identity "$i"
  done

  titre "Utilisateurs et groupes IAM du projet"
  for u in felix gabin shopimt-deployer; do supprimer_utilisateur "$u"; done
  supprimer_groupe boutique-admins
  supprimer_groupe shopimt-stock

  titre "Budget du projet (l'alerte alerte-1usd du compte est gardée)"
  aws budgets describe-budget --account-id "$COMPTE" --budget-name boutique-budget-1usd --region us-east-1 >/dev/null 2>&1 &&
    lancer aws budgets delete-budget --account-id "$COMPTE" --budget-name boutique-budget-1usd --region us-east-1
fi

if [ "$ETAPE" = "socle" ]; then
  titre "Bucket d'état Terraform"
  aws s3api head-bucket --bucket "shopimt-tfstate-$COMPTE" 2>/dev/null && vider_bucket "shopimt-tfstate-$COMPTE"

  titre "Rôle de lecture GitHub et fournisseur OIDC"
  supprimer_role shopimt-github-plan
  lancer aws iam delete-open-id-connect-provider \
    --open-id-connect-provider-arn "arn:aws:iam::$COMPTE:oidc-provider/token.actions.githubusercontent.com"

  # Le workflow agit avec ce rôle : il ne peut pas se supprimer lui-même. On lui retire ses droits en tout dernier,
  # il reste alors un rôle vide que plus personne ne peut assumer (fournisseur OIDC supprimé), à effacer depuis la
  # console IAM (gratuit).
  titre "Rôle de déploiement GitHub : retrait des droits (dernière action)"
  lancer aws iam detach-role-policy --role-name shopimt-github-deploy \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
fi

echo
echo "Terminé ($ECHECS échec(s))."
