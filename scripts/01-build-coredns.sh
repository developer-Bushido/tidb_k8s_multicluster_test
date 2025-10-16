#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BUILD_DIR="$ROOT_DIR/coredns-build"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo "================ Building CoreDNS with multicluster plugin ================"

log_step "Clone CoreDNS v1.11.4"
rm -rf "$BUILD_DIR"
git clone --depth 1 --branch v1.11.4 https://github.com/coredns/coredns.git "$BUILD_DIR" >/dev/null
cd "$BUILD_DIR"

log_step "Enable multicluster plugin"
awk '/^kubernetes:kubernetes$/{print; print "multicluster:github.com/coredns/multicluster"; next}1' plugin.cfg > plugin.new && mv plugin.new plugin.cfg

log_step "Fetch deps"
go get github.com/coredns/multicluster >/dev/null 2>&1 || true
go mod tidy >/dev/null 2>&1

log_step "Build CoreDNS binary"
ARCH=$(uname -m); GOARCH=arm64; [ "$ARCH" = "x86_64" ] && GOARCH=amd64
CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -ldflags="-s -w" -o coredns . >/dev/null

log_step "Build Docker image"
cat > Dockerfile << 'EOF'
FROM alpine:3.18
RUN apk add --no-cache ca-certificates libcap
COPY coredns /coredns
RUN chmod +x /coredns && setcap cap_net_bind_service=+ep /coredns
EXPOSE 53 53/udp
ENTRYPOINT ["/coredns"]
EOF
docker build -t coredns-multicluster:mcs . >/dev/null

log_step "Load image into kind"
for n in cluster1 cluster2 cluster3; do kind load docker-image coredns-multicluster:mcs --name $n >/dev/null; done

log_step "Roll out CoreDNS to clusters"
for ctx in kind-cluster1 kind-cluster2 kind-cluster3; do
  # ConfigMap Corefile
  kubectl --context $ctx apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    clusterset.local:53 {
        errors
        log
        multicluster
    }
    cluster.local:53 {
        errors
        cache 30
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
    }
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
YAML
  # RBAC
  kubectl --context $ctx patch clusterrole system:coredns --type=json \
    -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["multicluster.x-k8s.io"],"resources":["serviceimports"],"verbs":["list","watch"]}}]' >/dev/null || true
  # Use local image and Never pull
  kubectl --context $ctx -n kube-system set image deployment/coredns coredns=coredns-multicluster:mcs >/dev/null
  kubectl --context $ctx -n kube-system patch deployment coredns --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' >/dev/null
  kubectl --context $ctx -n kube-system delete pods -l k8s-app=kube-dns >/dev/null 2>&1 || true
done

log_info "CoreDNS ready"

