#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$ROOT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo "================ TiDB Multicluster Setup (v2) ================"

# STEP 1: Cleanup kind resources only
log_step "1/7 Cleanup kind nodes and networks"
kind delete clusters --all >/dev/null 2>&1 || true
docker ps -a --format '{{.ID}}\t{{.Image}}\t{{.Names}}' | awk '/kindest\/node/ {print $1}' | xargs -r docker stop >/dev/null 2>&1 || true
docker ps -a --format '{{.ID}}\t{{.Image}}\t{{.Names}}' | awk '/kindest\/node/ {print $1}' | xargs -r docker rm -f >/dev/null 2>&1 || true
docker network ls --filter name=kind --format '{{.ID}}' | xargs -r docker network rm >/dev/null 2>&1 || true

# STEP 2: Create 3 kind clusters without default CNI
log_step "2/7 Create 3 kind clusters"
for i in 1 2 3; do
  log_info "Creating cluster$i"
  cat <<EOF | kind create cluster --name cluster$i --config=- >/dev/null
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
networking:
  disableDefaultCNI: true
  podSubnet: "10.${i}0.0.0/16"
  serviceSubnet: "10.${i}1.0.0/16"
EOF
done

# STEP 2.5: Tune etcd for large CRDs
log_step "2.5/7 Tune etcd max-request-bytes in kind control-planes"
ensure_etcd_large_request() {
  local cluster_name=$1
  local node_name="${cluster_name}-control-plane"
  docker exec "$node_name" sh -c "grep -q max-request-bytes /etc/kubernetes/manifests/etcd.yaml || sed -i '/- --snapshot-count=10000/a\\    - --max-request-bytes=8388608' /etc/kubernetes/manifests/etcd.yaml" >/dev/null 2>&1 || true
}
for i in 1 2 3; do ensure_etcd_large_request cluster$i; done
sleep 5

# STEP 3: Install MCS-API CRDs
log_step "3/7 Install MCS-API CRDs"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  kubectl --context $ctx apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceexports.yaml >/dev/null
  kubectl --context $ctx apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceimports.yaml >/dev/null
done

# STEP 4: Install Cilium and clustermesh
log_step "4/7 Install Cilium 1.18.2 + MCS"
for i in 1 2 3; do
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install cilium cilium/cilium \
    --version 1.18.2 \
    --namespace kube-system \
    --kube-context kind-cluster$i \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set cluster.name=cluster$i \
    --set cluster.id=$i \
    --set clustermesh.useAPIServer=true \
    --set clustermesh.enableMCSAPISupport=true \
    >/dev/null
done
sleep 60

log_step "5/7 Setup Cilium Cluster Mesh"
for i in 1 2 3; do cilium clustermesh enable --context kind-cluster$i --service-type NodePort >/dev/null 2>&1 || true; done
sleep 60
cilium clustermesh connect --context kind-cluster1 --destination-context kind-cluster2 >/dev/null 2>&1 || true
sleep 15
cilium clustermesh connect --context kind-cluster1 --destination-context kind-cluster3 >/dev/null 2>&1 || true
sleep 15
cilium clustermesh connect --context kind-cluster2 --destination-context kind-cluster3 >/dev/null 2>&1 || true
sleep 15

# STEP 6: Build and roll out CoreDNS with multicluster plugin
log_step "6/7 Build CoreDNS (multicluster)"
./scripts/01-build-coredns.sh

# STEP 7: Install Operator v2 and deploy clusters
log_step "7/7 Operator v2 + clusters"
./scripts/02-install-operator-v2.sh
./scripts/03-deploy-tidb-cluster-v2.sh

echo "================ SETUP COMPLETE (v2) ================"

