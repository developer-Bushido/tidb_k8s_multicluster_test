#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BUILD_DIR="$ROOT_DIR/tidb-operator-v2-build"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "================ Installing TiDB Operator v2 ================"

log_step "Prepare sources (fork/branch configurable)"

# Allow override of repo/ref via env, default to your fork + feature branch
: "${OPERATOR_REPO:=https://github.com/developer-Bushido/tidb-operator.git}"
: "${OPERATOR_REF:=feature/v2}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
log_info "Cloning repo: $OPERATOR_REPO, ref: $OPERATOR_REF"
if git clone --depth 1 --branch "$OPERATOR_REF" "$OPERATOR_REPO" "$BUILD_DIR/src" >/dev/null 2>&1; then
  log_info "Checked out $OPERATOR_REF from $OPERATOR_REPO"
else
  log_warn "Failed to clone $OPERATOR_REPO@$OPERATOR_REF; falling back to upstream release-2.0"
  git clone --depth 1 --branch release-2.0 https://github.com/pingcap/tidb-operator.git "$BUILD_DIR/src" >/dev/null
fi
cd "$BUILD_DIR/src"
git log -1 --oneline || true

log_step "Build images (operator + prestop-checker)"
ARCH=$(uname -m); PLATFORM=linux/arm64; [ "$ARCH" = "x86_64" ] && PLATFORM=linux/amd64
docker buildx ls | grep -q "\*" || docker buildx create --use >/dev/null

safe_ref=$(echo "$OPERATOR_REF" | sed 's/[^a-zA-Z0-9_.-]/-/g')
OP_IMG="tidb-operator:${safe_ref:-v2local}"
PRESTOP_IMG="pingcap/tidb-operator-prestop-checker:latest"

DOCKER_BUILDKIT=1 docker buildx build --file image/Dockerfile --platform "$PLATFORM" --target tidb-operator -t "$OP_IMG" . >/dev/null
DOCKER_BUILDKIT=1 docker buildx build --file image/Dockerfile --platform "$PLATFORM" --target prestop-checker -t "$PRESTOP_IMG" . >/dev/null

log_step "Preload images into all kind clusters"
for n in cluster1 cluster2 cluster3; do
  kind load docker-image "$OP_IMG" --name "$n" >/dev/null || true
  kind load docker-image "$PRESTOP_IMG" --name "$n" >/dev/null || true
done

log_step "Apply v2 CRDs (core.pingcap.com + br.pingcap.com)"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  kubectl --context "$ctx" apply --server-side -f manifests/crd >/dev/null
done

log_step "Install Helm chart (v2) with local image and pullPolicy=Never"
for i in 1 2 3; do
  ctx="kind-cluster$i"
  kubectl --context "$ctx" create namespace tidb-admin >/dev/null 2>&1 || true
  helm upgrade --install tidb-operator charts/tidb-operator \
    --namespace tidb-admin \
    --kube-context "$ctx" \
    --set operator.image.repository=$(echo "$OP_IMG" | cut -d: -f1) \
    --set operator.image.tag=$(echo "$OP_IMG" | cut -d: -f2) \
    --set operator.pullPolicy=Never \
    --set admissionWebhook.create=false \
    --set controllerManager.create=false \
    --wait --timeout 5m >/dev/null
  log_info "Operator v2 deployed on $ctx"
done

log_info "TiDB Operator v2 ready"
