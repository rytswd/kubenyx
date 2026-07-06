# Native control-plane startup benchmark: kine + apiserver + kcm +
# scheduler as bare processes in a temp dir, timed to the millisecond.
# This is the grind loop for startup-speed work — no VM, no TCG noise.
# It measures exactly the path Kubenyx's units run; systemd adds only
# ordering on top.
{
  lib,
  writeShellApplication,
  callPackage,
  kubernetes,
  kine,
  kubectl,
  openssl,
  curl,
}:
writeShellApplication {
  name = "kubenyx-native-bench";
  runtimeInputs = [
    kubernetes
    kine
    kubectl
    openssl
    curl
    (callPackage ./kubenyx-tools.nix { })
  ];
  text = ''
    work=$(mktemp -d)
    pids=()
    cleanup() {
      for p in "''${pids[@]}"; do kill "$p" 2>/dev/null || true; done
      sleep 1
      # apiserver's graceful drain can hang without clients; be blunt.
      for p in "''${pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done
      if [ -n "''${KEEP_WORK:-}" ]; then
        echo "workdir kept: $work" >&2
      else
        rm -rf "$work"
      fi
    }
    trap cleanup EXIT INT TERM

    now_ms() { date +%s%3N; }

    # --- PKI (the real generator: Rust kubenyx-pki, one process) -------------
    t_pki0=$(now_ms)
    pki=$work/pki
    kubenyx-pki --mode server --pki-dir "$pki" --kubeconfig-dir "$work" \
      --node-name bench --node-address 127.0.0.1 \
      --api-url https://127.0.0.1:16443 --service-ip 10.96.0.1 \
      --node bench=127.0.0.1
    t_pki1=$(now_ms)
    echo "KUBENYX-METRIC pki_ms=$((t_pki1 - t_pki0))"

    curl_admin=(curl --silent --fail --max-time 2
      --cacert "$pki/ca.crt" --cert "$pki/admin.crt" --key "$pki/admin.key")

    # --- kine -----------------------------------------------------------------
    t0=$(now_ms)
    kine --endpoint "sqlite://$work/state.db?_journal=WAL&cache=shared&_busy_timeout=30000''${KINE_EXTRA_DSN:-}" \
         --listen-address "unix://$work/kine.sock" \
         --compact-interval 0 --metrics-bind-address 0 \
         --watch-progress-notify-interval 5s >"$work/kine.log" 2>&1 &
    pids+=($!)

    # --- apiserver --------------------------------------------------------------
    # shellcheck disable=SC2054 # commas are inside flag values, not separators
    api_args=(
      --secure-port=16443
      --allow-privileged=true
      --authorization-mode=Node,RBAC
      --enable-admission-plugins=NodeRestriction
      --anonymous-auth=false
      --profiling=false
      --tls-min-version=VersionTLS12
      --requestheader-client-ca-file="$pki/front-proxy-ca.crt"
      --requestheader-allowed-names=front-proxy-client
      --requestheader-username-headers=X-Remote-User
      --requestheader-group-headers=X-Remote-Group
      --requestheader-extra-headers-prefix=X-Remote-Extra-
      --proxy-client-cert-file="$pki/front-proxy-client.crt"
      --proxy-client-key-file="$pki/front-proxy-client.key"
      --client-ca-file="$pki/ca.crt"
      --tls-cert-file="$pki/apiserver.crt" --tls-private-key-file="$pki/apiserver.key"
      --kubelet-client-certificate="$pki/apiserver-kubelet-client.crt"
      --kubelet-client-key="$pki/apiserver-kubelet-client.key"
      --service-cluster-ip-range=10.96.0.0/16
      --service-account-issuer=https://kubernetes.default.svc
      --service-account-key-file="$pki/sa.pub"
      --service-account-signing-key-file="$pki/sa.key"
      --etcd-servers="unix://$work/kine.sock"
      --cert-dir="$work"
      "$@"
    )
    kube-apiserver "''${api_args[@]}" >"$work/apiserver.log" 2>&1 &
    api_pid=$!
    pids+=("$api_pid")

    until "''${curl_admin[@]}" --output /dev/null https://127.0.0.1:16443/readyz; do
      if ! kill -0 "$api_pid" 2>/dev/null; then
        echo "kubenyx-native-bench: apiserver died:" >&2
        tail -20 "$work/apiserver.log" >&2
        exit 1
      fi
      sleep 0.05
    done
    t_api=$(now_ms)
    echo "KUBENYX-METRIC apiserver_ready_ms=$((t_api - t0))"

    # --- kcm + scheduler --------------------------------------------------------
    # Kubenyx's addon applier installs these immediately after readyz; the
    # shared kcm identity and the admin group depend on them.
    KUBECONFIG=$work/bootstrap.kubeconfig kubectl create clusterrolebinding kcm-shared \
      --clusterrole=cluster-admin --user=system:kube-controller-manager >/dev/null
    KUBECONFIG=$work/bootstrap.kubeconfig kubectl create clusterrolebinding admins \
      --clusterrole=cluster-admin --group=kubenyx:cluster-admins >/dev/null

    kcm_extra=()
    if [ -n "''${KCM_EXTRA_FLAGS:-}" ]; then
      read -ra kcm_extra <<< "$KCM_EXTRA_FLAGS"
    fi
    kube-controller-manager \
      --kubeconfig="$work/controller-manager.kubeconfig" \
      --authentication-kubeconfig="$work/controller-manager.kubeconfig" \
      --authorization-kubeconfig="$work/controller-manager.kubeconfig" \
      --client-ca-file="$pki/ca.crt" --root-ca-file="$pki/ca.crt" \
      --service-account-private-key-file="$pki/sa.key" \
      --cluster-signing-cert-file="$pki/ca.crt" --cluster-signing-key-file="$pki/ca.key" \
      --use-service-account-credentials=false \
      --allocate-node-cidrs=false \
      --service-cluster-ip-range=10.96.0.0/16 \
      --controllers='*' --leader-elect=false \
      --bind-address=127.0.0.1 --secure-port=20257 --profiling=false \
      "''${kcm_extra[@]}" >"$work/kcm.log" 2>&1 &
    pids+=($!)

    cat > "$work/sched.yaml" <<EOF
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    clientConnection:
      kubeconfig: $work/scheduler.kubeconfig
    leaderElection:
      leaderElect: false
    EOF
    kube-scheduler --config="$work/sched.yaml" --bind-address=127.0.0.1 \
      --secure-port=20259 >"$work/sched.log" 2>&1 &
    pids+=($!)

    until curl --insecure --silent --fail --max-time 2 --output /dev/null https://127.0.0.1:20257/healthz; do
      sleep 0.05
    done
    t_kcm=$(now_ms)
    echo "KUBENYX-METRIC kcm_healthy_ms=$((t_kcm - t0))"

    until curl --insecure --silent --fail --max-time 2 --output /dev/null https://127.0.0.1:20259/healthz; do
      sleep 0.05
    done
    t_sched=$(now_ms)
    echo "KUBENYX-METRIC scheduler_healthy_ms=$((t_sched - t0))"

    # First real write through the full stack (admission, SA controller, kine).
    KUBECONFIG=$work/admin.kubeconfig kubectl create namespace bench >/dev/null
    until KUBECONFIG=$work/admin.kubeconfig kubectl -n bench get serviceaccount default >/dev/null 2>&1; do
      sleep 0.05
    done
    t_sa=$(now_ms)
    echo "KUBENYX-METRIC default_sa_ms=$((t_sa - t0))"
    echo "KUBENYX-METRIC control_plane_total_ms=$((t_sa - t0))"

    if [ -n "''${WARM_RESTART:-}" ]; then
      # apiserver restart against the warm datastore: the bootstrap
      # post-start hooks find their objects already present.
      kill "$api_pid"
      wait "$api_pid" 2>/dev/null || true
      tw0=$(now_ms)
      kube-apiserver "''${api_args[@]}" >"$work/apiserver2.log" 2>&1 &
      api_pid=$!
      pids+=("$api_pid")
      until "''${curl_admin[@]}" --output /dev/null https://127.0.0.1:16443/readyz; do
        kill -0 "$api_pid" 2>/dev/null || { tail -20 "$work/apiserver2.log" >&2; exit 1; }
        sleep 0.05
      done
      tw1=$(now_ms)
      echo "KUBENYX-METRIC apiserver_warm_ready_ms=$((tw1 - tw0))"
    fi
  '';
}
