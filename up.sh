#!/usr/bin/env bash
# Deploys the whole app in order: db -> backend (+ migration Job) -> frontend -> ingress,
# then loads the test data. Idempotent (helm upgrade --install), safe to re-run.
#
# Usage: ./up.sh [--repo] [--no-seed] [--port-forward]
#   --repo          install from the published Helm repo instead of the local ./<chart> dirs
#   --no-seed       skip loading sql/seed_pablodevops.sql
#   --port-forward  at the end, port-forward Traefik on local port 80 (Ctrl+C to stop)
#
# Env: NAMESPACE (default: default), TIMEOUT (default: 5m)
#
# Prerequisites (checked below): kubectl + helm, a k3s/k3d cluster with Traefik, and the
# Secrets db-secret + docker-registry-secret (ExternalSecrets from vault-secrets-deployment).
set -euo pipefail

REPO_NAME="pablo-charts"
REPO_URL="https://juanpa1999.github.io/helm-chart"
NAMESPACE="${NAMESPACE:-default}"
TIMEOUT="${TIMEOUT:-5m}"
REQUIRED_SECRETS=(db-secret docker-registry-secret)

USE_REPO=false
SEED=true
PORT_FORWARD=false

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         USE_REPO=true; shift ;;
    --no-seed)      SEED=false; shift ;;
    --port-forward) PORT_FORWARD=true; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

cd "$(dirname "$0")"

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

k() { kubectl -n "$NAMESPACE" "$@"; }

# Chart reference: local dir or <repo>/<chart>.
chart() { if $USE_REPO; then echo "$REPO_NAME/$1"; else echo "./$1"; fi; }

install() {
  local release="$1" chart_name="$2"; shift 2
  log "Installing $release ($(chart "$chart_name"))"
  helm upgrade --install "$release" "$(chart "$chart_name")" \
    --namespace "$NAMESPACE" --wait --timeout "$TIMEOUT" "$@"
}

# ---------------------------------------------------------------- preflight
log "Preflight checks"
command -v kubectl >/dev/null || fail "kubectl not found"
command -v helm    >/dev/null || fail "helm not found"

echo "kube context: $(kubectl config current-context)  namespace: $NAMESPACE"
kubectl cluster-info >/dev/null 2>&1 || fail "cannot reach the cluster"

kubectl -n kube-system get svc traefik >/dev/null 2>&1 ||
  fail "Traefik not found in kube-system (the ingress chart needs it)"

kubectl get storageclass local-path >/dev/null 2>&1 ||
  fail "StorageClass local-path not found (db chart: persistence.storageClass)"

missing=()
for s in "${REQUIRED_SECRETS[@]}"; do
  k get secret "$s" >/dev/null 2>&1 || missing+=("$s")
done
[[ ${#missing[@]} -eq 0 ]] ||
  fail "missing Secrets in '$NAMESPACE': ${missing[*]} — create them first with the ExternalSecrets in vault-secrets-deployment/terraform/"

# db-service became headless (clusterIP: None) and clusterIP is immutable: an old
# ClusterIP db-service (db chart 0.1.0) makes the upgrade fail. Not deleted automatically.
cip=$(k get svc db-service -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -n "$cip" && "$cip" != "None" ]]; then
  fail "db-service exists with clusterIP $cip; the db chart now needs it headless. Run 'kubectl -n $NAMESPACE delete svc db-service' and re-run."
fi

if $USE_REPO; then
  log "Adding Helm repo $REPO_NAME"
  helm repo add "$REPO_NAME" "$REPO_URL" --force-update >/dev/null
  helm repo update "$REPO_NAME"
  helm search repo "$REPO_NAME"
fi

# ---------------------------------------------------------------- deploy in order
# 1. PostgreSQL (StatefulSet + PVC). --wait covers the readiness probe (pg_isready).
install db db
k rollout status statefulset/db-statefulset --timeout "$TIMEOUT"

# 2. Backend. --wait also waits for the post-install/post-upgrade migration Job (alembic).
install backend backend

# 3. Frontend.
install frontend frontend

# 4. Ingress (Traefik routes + StripPrefix Middleware).
install ingress ingress

# ---------------------------------------------------------------- test data
if $SEED; then
  log "Loading test data (idempotent)"
  k exec -i statefulset/db-statefulset -- \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql
fi

log "Deployed"
k get statefulset,deploy,svc,pvc,ingress -l 'app in (db,back,front)' 2>/dev/null || true
helm list -n "$NAMESPACE"

cat <<EOF

Test user: pablodevops (role master; the seed only stores its bcrypt hash)
Access:    add '127.0.0.1 pablodevops.store' to /etc/hosts, then
           kubectl -n kube-system port-forward svc/traefik 80:80
           and open http://pablodevops.store
EOF

if $PORT_FORWARD; then
  log "Port-forwarding Traefik on local port 80 (Ctrl+C to stop)"
  kubectl -n kube-system port-forward svc/traefik 80:80
fi
