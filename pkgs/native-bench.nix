# Native control-plane startup benchmark: kine + apiserver + kcm +
# scheduler as bare processes in a temp dir, timed to the millisecond.
# This is the grind loop for startup-speed work — no VM, no TCG noise.
# It measures exactly the path Kubenyx's units run; systemd adds only
# ordering on top.
{
  lib,
  writeShellApplication,
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

    # --- PKI (same shapes as modules/pki.nix) --------------------------------
    t_pki0=$(now_ms)
    pki=$work/pki && mkdir -p "$pki"
    genkey() { openssl ecparam -name prime256v1 -genkey -noout -out "$1"; }
    genkey "$pki/ca.key"
    openssl req -x509 -new -key "$pki/ca.key" -days 3650 -subj "/CN=kubenyx-ca" -out "$pki/ca.crt"
    cert() {
      local name=$1 subj=$2 eku=$3 san=$4
      genkey "$pki/$name.key"
      openssl req -new -key "$pki/$name.key" -subj "$subj" -out "$pki/$name.csr"
      {
        echo "keyUsage=critical,digitalSignature,keyEncipherment"
        echo "extendedKeyUsage=$eku"
        [ -n "$san" ] && echo "subjectAltName=$san"
      } > "$pki/$name.ext"
      openssl x509 -req -in "$pki/$name.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" \
        -CAcreateserial -days 365 -extfile "$pki/$name.ext" -out "$pki/$name.crt" 2>/dev/null
    }
    cert apiserver "/CN=kube-apiserver" serverAuth "DNS:localhost,DNS:kubernetes,IP:127.0.0.1,IP:10.96.0.1"
    # Front-proxy CA + client, matching modules/pki.nix (the real boot pays
    # for these, so the bench must too).
    genkey "$pki/front-proxy-ca.key"
    openssl req -x509 -new -key "$pki/front-proxy-ca.key" -days 3650 -subj "/CN=fp-ca" -out "$pki/front-proxy-ca.crt"
    genkey "$pki/front-proxy-client.key"
    openssl req -new -key "$pki/front-proxy-client.key" -subj "/CN=front-proxy-client" -out "$pki/fpc.csr"
    printf 'extendedKeyUsage=clientAuth\n' > "$pki/fpc.ext"
    openssl x509 -req -in "$pki/fpc.csr" -CA "$pki/front-proxy-ca.crt" -CAkey "$pki/front-proxy-ca.key" \
      -set_serial 0x1 -days 365 -extfile "$pki/fpc.ext" -out "$pki/front-proxy-client.crt" 2>/dev/null
    cert admin "/O=system:masters/CN=bench-admin" clientAuth ""
    cert kcm "/CN=system:kube-controller-manager" clientAuth ""
    cert sched "/CN=system:kube-scheduler" clientAuth ""
    cert kubelet-client "/CN=kube-apiserver-kubelet-client" clientAuth ""
    genkey "$pki/sa.key"
    openssl ec -in "$pki/sa.key" -pubout -out "$pki/sa.pub" 2>/dev/null

    kcfg() {
      local out=$1 user=$2 crt=$3 key=$4
      KUBECONFIG=$out kubectl config set-cluster b --server=https://127.0.0.1:16443 \
        --certificate-authority="$pki/ca.crt" --embed-certs=true >/dev/null
      KUBECONFIG=$out kubectl config set-credentials "$user" \
        --client-certificate="$crt" --client-key="$key" --embed-certs=true >/dev/null
      KUBECONFIG=$out kubectl config set-context d --cluster=b --user="$user" >/dev/null
      KUBECONFIG=$out kubectl config use-context d >/dev/null
    }
    kcfg "$work/admin.kubeconfig" admin "$pki/admin.crt" "$pki/admin.key"
    kcfg "$work/kcm.kubeconfig" kcm "$pki/kcm.crt" "$pki/kcm.key"
    kcfg "$work/sched.kubeconfig" sched "$pki/sched.crt" "$pki/sched.key"
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
      --kubelet-client-certificate="$pki/kubelet-client.crt"
      --kubelet-client-key="$pki/kubelet-client.key"
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
    kcm_extra=()
    if [ -n "''${KCM_EXTRA_FLAGS:-}" ]; then
      read -ra kcm_extra <<< "$KCM_EXTRA_FLAGS"
    fi
    kube-controller-manager \
      --kubeconfig="$work/kcm.kubeconfig" \
      --authentication-kubeconfig="$work/kcm.kubeconfig" \
      --authorization-kubeconfig="$work/kcm.kubeconfig" \
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
      kubeconfig: $work/sched.kubeconfig
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
