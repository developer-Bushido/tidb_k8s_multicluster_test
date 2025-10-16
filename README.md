TiDB Multicluster (kind) – Operator v2 + Cilium MCS

What this repo provides
- One‑command bootstrap of 3 kind clusters on a single machine
- Cilium CNI + Cluster Mesh with MCS API enabled
- CoreDNS built with the multicluster plugin
- TiDB Operator v2 (core.pingcap.com) built locally and installed on all clusters
- Three TiDB clusters (tc1/tc2/tc3) via Operator v2 CRDs
- Multicluster DNS for PD services (ClusterSetIP + headless per‑pod)

Prerequisites
- Docker Desktop with buildx (or Docker Engine) and at least 8 GB RAM free
- kind v0.25+
- kubectl v1.30+
- helm v3.12+
- cilium CLI v0.14+ (for clustermesh commands)
- Go 1.20+ (only for building CoreDNS in host; optional if you pre‑build elsewhere)

Quick start
1) Clone this repo and cd into it

2) Run the full setup
   # optionally select your fork + branch for Operator v2
   export OPERATOR_REPO=https://github.com/developer-Bushido/tidb-operator.git
   export OPERATOR_REF=feature/v2   # change to your branch with the new feature
   ./scripts/00-full-setup.sh

This will:
- Delete old kind clusters named cluster1..3 (only those)
- Create cluster1/2/3
- Install and connect Cilium clustermesh (+MCS API)
- Build CoreDNS with multicluster plugin and roll it out to all clusters
- Build TiDB Operator v2 image locally, preload into kind nodes, install helm chart v2
- Deploy tc1/tc2/tc3 with small footprints suitable for kind
- Export PD services and verify ServiceImports

Verify
- Operator v2 cluster status
  kubectl --context kind-cluster1 -n tidb-cluster get clusters.core.pingcap.com -o wide
  kubectl --context kind-cluster2 -n tidb-cluster get clusters.core.pingcap.com -o wide
  kubectl --context kind-cluster3 -n tidb-cluster get clusters.core.pingcap.com -o wide

- DNS (from cluster1):
  kubectl --context kind-cluster1 run dns --image=busybox:1.28 --rm -i --restart=Never -- nslookup pd-pd.tidb-cluster.svc.clusterset.local

  # Headless per‑pod (example)
  POD=$(kubectl --context kind-cluster1 -n tidb-cluster get pods -l pingcap.com/component=pd -o jsonpath='{.items[0].metadata.name}')
  kubectl --context kind-cluster1 run dns2 --image=busybox:1.28 --rm -i --restart=Never -- \
    nslookup ${POD}.cluster1.pd-pd-peer.tidb-cluster.svc.clusterset.local

- TiDB SQL (cluster1)
  kubectl --context kind-cluster1 -n tidb-cluster port-forward svc/tidb-tidb 4000:4000
  mysql -h 127.0.0.1 -P 4000 -u root -e 'SHOW DATABASES;'

Operator v2 branch/repo selection
- By default the installer tries OPERATOR_REPO=https://github.com/developer-Bushido/tidb-operator.git and OPERATOR_REF=feature/v2.
- If that clone fails, it falls back to upstream release-2.0.
- You can override:
  export OPERATOR_REPO=https://github.com/<your-org>/tidb-operator.git
  export OPERATOR_REF=<your-branch>

Design notes
- No external registry: images are built locally and preloaded into kind nodes; pullPolicy=Never where applicable to avoid network pulls.
- Dev‐friendly resource profiles:
  - PD: 2/2/1 replicas (clusters 1/2/3)
  - TiKV: 1 replica per cluster, memory 2Gi, storage.reserve-space=0MB
  - TiDB: 1 replica per cluster
  - PD replication.max-replicas=1, placement rules disabled (to avoid replica churn on single‑TiKV dev topologies)

Cleanup
  kind delete clusters --all
