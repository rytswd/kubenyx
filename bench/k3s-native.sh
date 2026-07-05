#!/usr/bin/env bash
# Native k3s control-plane startup benchmark (comparison baseline for
# pkgs/native-bench.nix). Control-plane only (--disable-agent), bundled
# extras off — the same scope the kubenyx native bench measures.
set -euo pipefail
work=$(mktemp -d /tmp/k3s-bench.XXXXXX)
now_ms() { date +%s%3N; }
cleanup() {
  kill "$k3spid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

t0=$(now_ms)
k3s server \
  --data-dir "$work/data" \
  --disable-agent \
  --disable=traefik,servicelb,metrics-server,coredns,local-storage \
  --disable-cloud-controller --disable-network-policy --disable-helm-controller \
  --https-listen-port 16444 \
  --write-kubeconfig "$work/kubeconfig" \
  >"$work/k3s.log" 2>&1 &
k3spid=$!

export KUBECONFIG=$work/kubeconfig
# Wait for the kubeconfig to exist first: with no file, kubectl silently
# falls back to ambient in-cluster credentials and polls the wrong cluster.
until [ -s "$KUBECONFIG" ]; do
  kill -0 $k3spid || { echo "k3s died"; tail -30 "$work/k3s.log"; exit 1; }
  sleep 0.05
done
until kubectl get --raw /readyz >/dev/null 2>&1; do
  kill -0 $k3spid || { echo "k3s died"; tail -30 "$work/k3s.log"; exit 1; }
  sleep 0.05
done
t_api=$(now_ms)
echo "K3S-METRIC apiserver_ready_ms=$((t_api - t0))"

kubectl create namespace bench >/dev/null
until kubectl -n bench get serviceaccount default >/dev/null 2>&1; do sleep 0.05; done
t_sa=$(now_ms)
echo "K3S-METRIC default_sa_ms=$((t_sa - t0))"
echo "K3S-METRIC control_plane_total_ms=$((t_sa - t0))"
