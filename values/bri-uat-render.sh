#!/usr/bin/env bash
# Render the BRI console stack for Azure UAT.
#
# The cluster already runs one console (namespace synstream) applied from rendered
# manifests, not a Helm release, and this chart names its ClusterRole and
# ClusterRoleBinding without a namespace. A plain `helm install` would take over
# those two objects and re-point the binding at the BRI ServiceAccount, cutting
# the existing console off from the API server. So: render, rename the two
# cluster-scoped objects, and apply with kubectl like the existing instance.
#
#   JWT_SECRET_KEY=... ENCRYPTION_KEY=... values/bri-uat-render.sh > /tmp/bri-console.yaml
#   ssh azureuser@20.205.121.242 'sudo k3s kubectl apply -f -' < /tmp/bri-console.yaml
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-synstream-bri}"
: "${JWT_SECRET_KEY:?openssl rand -base64 48}"
: "${ENCRYPTION_KEY:?exactly 32 characters}"
if [ "${#ENCRYPTION_KEY}" -ne 32 ]; then
  echo "ENCRYPTION_KEY must be exactly 32 characters (got ${#ENCRYPTION_KEY}); the auth service refuses to start otherwise" >&2
  exit 1
fi
helm template synstream-bri "$ROOT/charts/synstream-console-project" \
  --namespace "$NS" \
  -f "$ROOT/values/bri-uat.yaml" \
  --set auth.secrets.jwtSecretKey="$JWT_SECRET_KEY" \
  --set auth.secrets.encryptionKey="$ENCRYPTION_KEY" \
  "$@" \
  | sed -e "s/^  name: synstream-auth-cluster-role$/  name: synstream-auth-cluster-role-${NS}/" \
        -e "s/^  name: synstream-auth-cluster-role-binding$/  name: synstream-auth-cluster-role-binding-${NS}/"
