#!/usr/bin/env bash
# terraform destroy d'un environnement, lancé par le workflow Autodestruction depuis infra/envs/<env>.
# Usage : scripts/destroy-env.sh simulation|reel
set -euo pipefail

terraform init -input=false
terraform plan -destroy -input=false -no-color -out=destroy.tfplan | tee destroy.txt
{ echo "### Destroy $(basename "$PWD") ($1)"; echo '```'; grep -E '^Plan:|^No changes' destroy.txt || true; echo '```'; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
if [ "$1" = "reel" ]; then
  terraform apply -input=false destroy.tfplan
fi
