#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "================ Deploying TiDB clusters (v2) ================"

log_step "Create namespaces"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  kubectl --context "$ctx" create namespace tidb-cluster >/dev/null 2>&1 || true
done

log_step "Preload core images into kind"
IMAGES=( pingcap/pd:v8.5.2 pingcap/tikv:v8.5.2 pingcap/tidb:v8.5.2 )
for img in "${IMAGES[@]}"; do
  docker pull "$img" >/dev/null || true
  for n in cluster1 cluster2 cluster3; do kind load docker-image "$img" --name "$n" >/dev/null || true; done
done

apply_cluster() {
  local ctx=$1 name=$2 pdRep=$3
  kubectl --context $ctx -n tidb-cluster apply -f - >/dev/null <<YAML
apiVersion: core.pingcap.com/v1alpha1
kind: Cluster
metadata:
  name: ${name}
  namespace: tidb-cluster
spec: {}
---
apiVersion: core.pingcap.com/v1alpha1
kind: PDGroup
metadata:
  name: pd
  namespace: tidb-cluster
  labels:
    pingcap.com/cluster: ${name}
    pingcap.com/component: pd
    pingcap.com/group: pd
spec:
  cluster:
    name: ${name}
  replicas: ${pdRep}
  template:
    spec:
      version: v8.5.2
      resources:
        cpu: "200m"
        memory: 256Mi
      config: |
        [replication]
        max-replicas = 1
        enable-placement-rules = false
      volumes:
      - name: data
        mounts:
        - type: data
        storage: 1Gi
---
apiVersion: core.pingcap.com/v1alpha1
kind: TiKVGroup
metadata:
  name: tikv
  namespace: tidb-cluster
  labels:
    pingcap.com/cluster: ${name}
    pingcap.com/component: tikv
    pingcap.com/group: tikv
spec:
  cluster:
    name: ${name}
  replicas: 1
  template:
    spec:
      version: v8.5.2
      resources:
        cpu: "200m"
        memory: 2Gi
      config: |
        [storage]
        reserve-space = "0MB"
      volumes:
      - name: data
        mounts:
        - type: data
        storage: 1Gi
---
apiVersion: core.pingcap.com/v1alpha1
kind: TiDBGroup
metadata:
  name: tidb
  namespace: tidb-cluster
  labels:
    pingcap.com/cluster: ${name}
    pingcap.com/component: tidb
    pingcap.com/group: tidb
spec:
  cluster:
    name: ${name}
  replicas: 1
  template:
    spec:
      version: v8.5.2
      resources:
        cpu: "200m"
        memory: 512Mi
YAML
}

log_step "Apply clusters"
apply_cluster kind-cluster1 tc1 2
apply_cluster kind-cluster2 tc2 2
apply_cluster kind-cluster3 tc3 1

log_step "Wait for PD/TiKV/TiDB readiness"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  log_info "Waiting PD on $ctx"
  kubectl --context "$ctx" -n tidb-cluster wait --for=condition=ready pod -l pingcap.com/component=pd --timeout=8m || true
  log_info "Waiting TiKV on $ctx"
  kubectl --context "$ctx" -n tidb-cluster wait --for=condition=ready pod -l pingcap.com/component=tikv --timeout=8m || true
  log_info "Waiting TiDB on $ctx"
  kubectl --context "$ctx" -n tidb-cluster wait --for=condition=ready pod -l pingcap.com/component=tidb --timeout=8m || true
done

log_step "Export PD services for MCS"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  cat <<'YAML' | kubectl --context "$ctx" -n tidb-cluster apply -f - >/dev/null
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: pd-pd
  namespace: tidb-cluster
---
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: pd-pd-peer
  namespace: tidb-cluster
YAML
done

log_step "Show ServiceImports on cluster1"
kubectl --context kind-cluster1 -n tidb-cluster get serviceimports || true

log_step "Show cluster statuses"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  kubectl --context "$ctx" -n tidb-cluster get clusters.core.pingcap.com -o wide || true
done

echo "================ TiDB v2 CLUSTERS DEPLOYED ================"

