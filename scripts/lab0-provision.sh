#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lab0-provision.sh - self-service Azure environment for DevOps: CI/CD
#
# Run this YOURSELF, as a student, in Lab 0 -- there is no instructor-run
# provisioning step in this course. Each student has their own dedicated
# Azure subscription, so every resource below lives only in YOUR subscription;
# nothing here can collide with another student's environment except the one
# resource whose name must be unique across all of Azure: the container
# registry (ACR). That is the only thing you pick a name for.
#
# Prereqs (do these first, in Lab 0):
#   1. az login                         (your own student account)
#   2. gh auth login                    (your own personal GitHub account)
#   3. Fork the ShipIt template under your own GitHub account, named "shipit"
#      (the OIDC federated credential below is bound to that repo, so it
#      must already exist before this script runs)
#
# Usage:
#   ./scripts/lab0-provision.sh <your-initials>
#   e.g. ./scripts/lab0-provision.sh jrs
#
# This kicks off two slow cloud operations (resource-provider registration and
# AKS cluster creation) as early as possible so you can do the rest of Lab 0
# (forking the repo, setting up VS Code) while they finish in the background.
# ---------------------------------------------------------------------------
set -euo pipefail

# On Windows Git Bash (MSYS2), any argument that looks like a POSIX path
# (starts with /) gets silently rewritten into a Windows path before it
# reaches a native .exe like az -- so "--scope /subscriptions/..." becomes
# garbage and every role assignment below fails with a confusing
# "MissingSubscription" error that has nothing to do with subscriptions.
# This disables that rewriting. Harmless on macOS/Linux, where it's unset.
export MSYS_NO_PATHCONV=1

INITIALS="${1:?your initials required, e.g. jrs}"
LOCATION="${LOCATION:-eastus}"
REPO="shipit"

RG="rg-shipit"
AKS="shipit-aks"
CAENV="shipit-cae"
APP_NAME="gh-shipit-${INITIALS}"

echo "== Confirming your Azure and GitHub logins =="
GH_USER="$(gh api user --jq .login)"
SUB="$(az account show --query id -o tsv)"
TENANT="$(az account show --query tenantId -o tsv)"
echo "GitHub user:        $GH_USER"
echo "Azure subscription: $SUB"
echo "Azure tenant:       $TENANT"
echo "Location:            $LOCATION"

# 1) Resource providers -- these take several minutes to register the first
#    time in a fresh subscription. Kick this off first so it runs in the
#    background while you do the rest of Lab 0.
echo
echo "== Registering resource providers (this runs in the background, several minutes) =="
PROVIDER_PIDS=()
for P in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.App Microsoft.Insights Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
  az provider register -n "$P" --wait -o none &
  PROVIDER_PIDS+=($!)
done

# 2) Resource group
echo
echo "== Creating resource group $RG in $LOCATION =="
az group create -n "$RG" -l "$LOCATION" -o none

# 3) Azure Container Registry -- the ONE resource whose name must be unique
#    across all of Azure, not just your subscription. Try your initials first;
#    if that name is already taken by someone else in the world, append a
#    number and try again. If you already ran this script before and it made
#    one, reuse it instead of creating another.
echo
echo "== Creating your Container Registry =="
ACR="$(az acr list -g "$RG" --query "[?starts_with(name, 'shipit${INITIALS}')].name | [0]" -o tsv)"
if [ -n "$ACR" ]; then
  echo "Reusing existing registry from a previous run: $ACR"
else
  for SUFFIX in "" 2 3 4 5; do
    CANDIDATE="shipit${INITIALS}${SUFFIX}acr"
    AVAILABLE="$(az acr check-name -n "$CANDIDATE" --query nameAvailable -o tsv)"
    if [ "$AVAILABLE" = "true" ]; then
      ACR="$CANDIDATE"
      break
    fi
    echo "  $CANDIDATE is already taken globally, trying another..."
  done
  if [ -z "$ACR" ]; then
    echo "ERROR: could not find an available ACR name starting with shipit${INITIALS}. Pick different initials and re-run." >&2
    exit 1
  fi
  echo "Using ACR name: $ACR"
  az acr create -g "$RG" -n "$ACR" --sku Basic -o none
fi

# 4) AKS -- one small node, ACR attached for pull at creation time (AcrPull on
#    the kubelet identity). This is the slow one (5-10 minutes); it also runs
#    in the background so you can move on to the GitHub/App-registration
#    steps below while it finishes. If it already exists (e.g. a previous run
#    got this far), skip creating it again -- az aks create errors on an
#    existing cluster name instead of behaving idempotently, and under `set
#    -e` that would silently kill the rest of the script later at `wait`.
#
# Not every VM family is offered in every subscription; override with
# NODE_SIZE=... if the create fails with "not allowed in your subscription".
NODE_SIZE="${NODE_SIZE:-Standard_D2s_v3}"
echo
if az aks show -g "$RG" -n "$AKS" -o none 2>/dev/null; then
  echo "AKS cluster $AKS already exists, skipping creation."
  ( : ) &
  AKS_PID=$!
else
  echo "== Starting AKS cluster creation in the background (5-10 minutes): $AKS =="
  (
    az aks create -g "$RG" -n "$AKS" \
      --node-count 1 --node-vm-size "$NODE_SIZE" \
      --generate-ssh-keys --attach-acr "$ACR" \
      --tier free -o none
    echo "AKS cluster $AKS is ready."
  ) &
  AKS_PID=$!
fi

# 5) Container Apps environment + staging/production apps (Lab 5 targets)
echo
echo "== Creating Container Apps environment and staging/production apps =="
az extension add --name containerapp --upgrade -o none
echo "Waiting for resource-provider registration to finish..."
wait "${PROVIDER_PIDS[@]}"
if az containerapp env show -g "$RG" -n "$CAENV" -o none 2>/dev/null; then
  echo "Container Apps environment $CAENV already exists, skipping creation."
else
  az containerapp env create -g "$RG" -n "$CAENV" -l "$LOCATION" -o none
fi
ACR_ID="$(az acr show -n "$ACR" --query id -o tsv)"
if ! [[ "$ACR_ID" =~ ^/subscriptions/ ]]; then
  echo "ERROR: could not read a valid resource ID for ACR $ACR (got: '$ACR_ID')." >&2
  exit 1
fi
for ENV in staging production; do
  if az containerapp show -g "$RG" -n "shipit-${ENV}" -o none 2>/dev/null; then
    echo "Container app shipit-${ENV} already exists, skipping creation."
  else
    az containerapp create -g "$RG" -n "shipit-${ENV}" \
      --environment "$CAENV" \
      --image mcr.microsoft.com/k8se/quickstart:latest \
      --ingress external --target-port 8080 \
      --min-replicas 1 -o none
  fi
  # Assign the identity, then read its principal ID back with a separate,
  # plain "show" call. Capturing the ID directly from "identity assign"'s own
  # output is unreliable -- that command's progress spinner can leak stray
  # characters into the captured value, which then makes the next command
  # (role assignment create) fail with a confusing "MissingSubscription"
  # error that has nothing to do with subscriptions or providers.
  az containerapp identity assign -g "$RG" -n "shipit-${ENV}" --system-assigned -o none
  CA_PID="$(az containerapp show -g "$RG" -n "shipit-${ENV}" --query identity.principalId -o tsv)"
  if ! [[ "$CA_PID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "ERROR: could not read a valid principal ID for shipit-${ENV} (got: '$CA_PID')." >&2
    exit 1
  fi
  if [ -z "$(az role assignment list --assignee "$CA_PID" --scope "$ACR_ID" --role AcrPull --query "[0].id" -o tsv)" ]; then
    az role assignment create --assignee-object-id "$CA_PID" \
      --assignee-principal-type ServicePrincipal \
      --role AcrPull --scope "$ACR_ID" -o none
  fi
  az containerapp registry set -g "$RG" -n "shipit-${ENV}" \
    --server "${ACR}.azurecr.io" --identity system -o none
done

# 6) Entra app registration + GitHub OIDC federated credentials (no secret)
#
# GitHub's OIDC token "sub" embeds immutable numeric IDs:
#   repo:<user>@<ownerId>/<repo>@<repoId>:environment:staging
# We read your repo's real IDs (public, no auth needed) and build the subject
# from them, plus the legacy form as a fallback for older accounts.
echo
echo "== Creating your Entra app registration and OIDC federated credentials =="
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [ -n "$APP_ID" ]; then
  echo "Reusing existing app registration from a previous run: $APP_NAME ($APP_ID)"
else
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
fi
if [ -z "$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)" ]; then
  az ad sp create --id "$APP_ID" -o none
fi

SUB_PREFIX="$(gh api "repos/${GH_USER}/${REPO}/actions/oidc/customization/sub" --jq .sub_claim_prefix)"
echo "Your repo's real OIDC subject prefix: $SUB_PREFIX"
SUBJECTS="$SUB_PREFIX repo:${GH_USER}/${REPO}" # current form + legacy fallback

# Contexts the pipelines present:
#  - ref:refs/heads/main               -> CI job pushing the image on main (Lab 3, Day 1)
#  - environment:staging / production  -> CD jobs (Lab 5-7, Day 2)
EXISTING_FC_NAMES="$(az ad app federated-credential list --id "$APP_ID" --query "[].name" -o tsv)"
i=0
for PREFIX in $SUBJECTS; do
  for CTX in "ref:refs/heads/main" "environment:staging" "environment:production"; do
    i=$((i+1))
    FC_NAME="shipit-fc-${i}"
    if grep -qx "$FC_NAME" <<<"$EXISTING_FC_NAMES"; then
      continue
    fi
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"${FC_NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"${PREFIX}:${CTX}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" -o none
  done
done

# 7) Give the pipeline identity Contributor on your resource group
if [ -z "$(az role assignment list --assignee "$APP_ID" --scope "/subscriptions/${SUB}/resourceGroups/${RG}" --role Contributor --query "[0].id" -o tsv)" ]; then
  az role assignment create --assignee "$APP_ID" --role Contributor \
    --scope "/subscriptions/${SUB}/resourceGroups/${RG}" -o none
fi

# Wait for the AKS create to finish before printing the final summary
wait "$AKS_PID"

cat <<CARD

================  Set these as GitHub repository variables  ================
On https://github.com/${GH_USER}/${REPO} -> Settings -> Secrets and variables
-> Actions -> Variables tab, add:

 RG                    = ${RG}
 ACR                   = ${ACR}
 AKS                   = ${AKS}
 AZURE_CLIENT_ID       = ${APP_ID}
 AZURE_TENANT_ID       = ${TENANT}
 AZURE_SUBSCRIPTION_ID = ${SUB}

None of these are secrets -- auth is OIDC, so there is no client secret to
protect. They live at the repository level (not environment level) so the
Module 2 CI job, which has no environment, can still read them to push images
in Module 3.
==============================================================================
CARD
