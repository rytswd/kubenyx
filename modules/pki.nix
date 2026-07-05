# Declarative offline PKI (air/v0.1/pki.org): one idempotent oneshot
# generates CA, leaves, SA keypair and kubeconfigs with plain openssl.
# No CA daemon, no network issuance — Nix is the trust channel.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  pki = cfg.internal.pkiDir;
  kcDir = cfg.internal.kubeconfigDir;

  thisNode = cfg.nodes.${cfg.nodeName};

  pkiScript = pkgs.writeShellApplication {
    name = "kubenyx-pki";
    runtimeInputs = [
      pkgs.openssl
      pkgs.iproute2
      pkgs.gnused
    ];
    text = ''
      umask 077   # every key/cert/kubeconfig is created 0600 from birth
      node_name=${lib.escapeShellArg cfg.nodeName}
      pki=${lib.escapeShellArg pki}
      kc=${lib.escapeShellArg kcDir}
      leaf_days=${toString cfg.pki.leafValidityDays}
      renew_secs=$(( ${toString cfg.pki.renewBeforeDays} * 86400 ))
      mkdir -p "$pki" "$kc"
      chmod 0700 "$pki" "$kc"

      node_ip=${lib.escapeShellArg (if thisNode.address == null then "" else thisNode.address)}
      if [ -z "$node_ip" ]; then
        node_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1) || true
      fi
      if [ -z "$node_ip" ]; then
        # No default route (isolated test VMs): first global IPv4 address.
        node_ip=$(ip -4 -o addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1) || true
      fi
      if [ -z "$node_ip" ]; then
        node_ip=127.0.0.1
      fi
      echo "$node_ip" > /run/kubenyx/node-ip

      gen_key() { openssl ecparam -name prime256v1 -genkey -noout -out "$1"; }

      if [ ! -s "$pki/ca.key" ] || [ ! -s "$pki/ca.crt" ]; then
        gen_key "$pki/ca.key"
        openssl req -x509 -new -key "$pki/ca.key" -days 3650 \
          -subj "/CN=kubenyx-ca" -out "$pki/ca.crt"
      fi

      # ensure_cert NAME SUBJECT EKU SAN — regenerates when missing, when the
      # recorded generation parameters changed, or within the renewal window.
      ensure_cert() {
        local name=$1 subject=$2 eku=$3 san=$4 ca=''${5:-ca}
        local dir crt key fp want
        dir=$(dirname "$pki/$name")
        mkdir -p "$dir"
        crt="$pki/$name.crt" key="$pki/$name.key" fp="$pki/.fp.$(echo "$name" | tr / _)"
        want="$subject|$eku|$san|$ca"
        if [ -s "$crt" ] && [ -s "$key" ] && [ -f "$fp" ] \
           && [ "$(cat "$fp")" = "$want" ] \
           && openssl x509 -checkend "$renew_secs" -noout -in "$crt" >/dev/null 2>&1; then
          return 0
        fi
        echo "kubenyx-pki: issuing $name"
        gen_key "$key.tmp"
        openssl req -new -key "$key.tmp" -subj "$subject" -out "$crt.csr"
        {
          echo "keyUsage=critical,digitalSignature,keyEncipherment"
          echo "extendedKeyUsage=$eku"
          echo "basicConstraints=CA:FALSE"
          if [ -n "$san" ]; then echo "subjectAltName=$san"; fi
        } > "$crt.ext"
        # Random serial instead of -CAcreateserial: no shared .srl file, so
        # issuance can run in parallel.
        openssl x509 -req -in "$crt.csr" -CA "$pki/$ca.crt" -CAkey "$pki/$ca.key" \
          -set_serial "0x$(openssl rand -hex 16)" \
          -days "$leaf_days" -extfile "$crt.ext" -out "$crt.tmp" 2>/dev/null
        mv "$key.tmp" "$key"
        mv "$crt.tmp" "$crt"
        rm -f "$crt.csr" "$crt.ext"
        echo "$want" > "$fp"
      }

      # Service-account signing keypair (ECDSA -> ES256 tokens).
      if [ ! -s "$pki/sa.key" ]; then
        gen_key "$pki/sa.key"
        openssl ec -in "$pki/sa.key" -pubout -out "$pki/sa.pub" 2>/dev/null
      fi

      api_san="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc"
      api_san="$api_san,DNS:kubernetes.default.svc.${cfg.network.clusterDomain}"
      api_san="$api_san,DNS:$node_name,DNS:localhost"
      api_san="$api_san,IP:127.0.0.1,IP:${cfg.internal.apiserverServiceIp},IP:$node_ip"
      extra_sans=(${lib.escapeShellArgs cfg.pki.extraApiserverSANs})
      for extra_san in "''${extra_sans[@]}"; do
        api_san="$api_san,$extra_san"
      done

      # Leaf issuance runs in parallel (independent files, random serials);
      # cert_wait collects failures before anything consumes the results.
      cert_pids=()
      par() { "$@" & cert_pids+=($!); }
      cert_wait() {
        local p
        for p in "''${cert_pids[@]}"; do wait "$p"; done
        cert_pids=()
      }

      par ensure_cert apiserver "/CN=kube-apiserver" serverAuth "$api_san"
      par ensure_cert apiserver-kubelet-client "/CN=kube-apiserver-kubelet-client" clientAuth ""

      # Distinct front-proxy CA (must never be the client CA — spoofing
      # risk) — enables the aggregation layer and completes the
      # extension-apiserver-authentication ConfigMap kcm watches.
      if [ ! -s "$pki/front-proxy-ca.key" ]; then
        gen_key "$pki/front-proxy-ca.key"
        openssl req -x509 -new -key "$pki/front-proxy-ca.key" -days 3650 \
          -subj "/CN=kubenyx-front-proxy-ca" -out "$pki/front-proxy-ca.crt"
      fi
      par ensure_cert front-proxy-client "/CN=front-proxy-client" clientAuth "" front-proxy-ca
      par ensure_cert admin "/O=kubenyx:cluster-admins/CN=kubenyx-admin" clientAuth ""
      # Bootstrap identity for the addon applier: the one deliberate
      # system:masters cert, needed to install the RBAC that gives the
      # revocable admin group its rights (kubeadm's super-admin analog).
      par ensure_cert bootstrap "/O=system:masters/CN=kubenyx-bootstrap" clientAuth ""
      ${lib.optionalString (cfg.datastore.backend == "etcd") ''
        par ensure_cert etcd-server "/CN=kube-etcd" serverAuth,clientAuth "DNS:localhost,IP:127.0.0.1"
        par ensure_cert apiserver-etcd-client "/CN=kube-apiserver-etcd-client" clientAuth ""
      ''}
      par ensure_cert controller-manager "/CN=system:kube-controller-manager" clientAuth ""
      par ensure_cert scheduler "/CN=system:kube-scheduler" clientAuth ""
      par ensure_cert kube-proxy "/CN=system:kube-proxy" clientAuth ""
      par ensure_cert coredns "/CN=system:coredns" clientAuth ""
      # Authenticated-but-unprivileged identity for health probes: /readyz
      # is authorization-always-allowed once authenticated, so the probe
      # must never ride the system:masters bootstrap credential.
      par ensure_cert healthz "/CN=kubenyx-healthz" clientAuth ""

      # Kubelet material for every declared node (workers consume their
      # pki/nodes/<name>/ subtree via the operator's secret channel).
      node_cert() {
        local name=$1 addr=$2
        local san="DNS:$name,IP:127.0.0.1"
        if [ -n "$addr" ]; then
          san="$san,IP:$addr"
        elif [ "$name" = "$node_name" ]; then
          san="$san,IP:$node_ip"
        fi
        ensure_cert "nodes/$name/kubelet" "/O=system:nodes/CN=system:node:$name" clientAuth ""
        ensure_cert "nodes/$name/kubelet-server" "/CN=system:node:$name" serverAuth "$san"
      }
      ${lib.concatMapStringsSep "\n" (
        n:
        "par node_cert ${lib.escapeShellArg n} ${lib.escapeShellArg (
          if cfg.nodes.${n}.address == null then "" else cfg.nodes.${n}.address
        )}"
      ) (lib.attrNames cfg.nodes)}

      cert_wait

      # Kubeconfigs — regenerated only when the underlying cert or the
      # embedded server URL changed. Rendered with a heredoc, not kubectl:
      # forking a 50MB Go binary 4x per kubeconfig is measurable boot time.
      write_kubeconfig() {
        local out=$1 user=$2 crt=$3 key=$4
        if [ -s "$out" ] && [ "$out" -nt "$crt" ] && [ "$out" -nt "$pki/ca.crt" ] \
           && grep -q "server: ${cfg.internal.apiserverUrl}$" "$out"; then
          return 0
        fi
        local ca64 crt64 key64
        ca64=$(openssl base64 -A < "$pki/ca.crt")
        crt64=$(openssl base64 -A < "$crt")
        key64=$(openssl base64 -A < "$key")
        cat > "$out.tmp" <<EOF
      apiVersion: v1
      kind: Config
      clusters:
      - name: kubenyx
        cluster:
          certificate-authority-data: $ca64
          server: ${cfg.internal.apiserverUrl}
      users:
      - name: $user
        user:
          client-certificate-data: $crt64
          client-key-data: $key64
      contexts:
      - name: default
        context:
          cluster: kubenyx
          user: $user
      current-context: default
      EOF
        chmod 0600 "$out.tmp"
        mv "$out.tmp" "$out"
      }

      par write_kubeconfig "$kc/admin.kubeconfig" kubenyx-admin "$pki/admin.crt" "$pki/admin.key"
      par write_kubeconfig "$kc/bootstrap.kubeconfig" kubenyx-bootstrap "$pki/bootstrap.crt" "$pki/bootstrap.key"
      par write_kubeconfig "$kc/controller-manager.kubeconfig" system:kube-controller-manager \
        "$pki/controller-manager.crt" "$pki/controller-manager.key"
      par write_kubeconfig "$kc/scheduler.kubeconfig" system:kube-scheduler \
        "$pki/scheduler.crt" "$pki/scheduler.key"
      par write_kubeconfig "$kc/kube-proxy.kubeconfig" system:kube-proxy \
        "$pki/kube-proxy.crt" "$pki/kube-proxy.key"
      par write_kubeconfig "$kc/coredns.kubeconfig" system:coredns \
        "$pki/coredns.crt" "$pki/coredns.key"
      par write_kubeconfig "$kc/kubelet.kubeconfig" "system:node:$node_name" \
        "$pki/nodes/$node_name/kubelet.crt" \
        "$pki/nodes/$node_name/kubelet.key"
      cert_wait
    '';
  };
in
{
  options.kubenyx.pki = {
    leafValidityDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Validity of leaf certificates.";
    };
    renewBeforeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Regenerate leaves that expire within this window (checked every activation).";
    };
    extraApiserverSANs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "DNS:k8s.example.com"
        "IP:192.0.2.10"
      ];
      description = "Additional subjectAltName entries for the apiserver serving certificate.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.role == "server") {
    systemd.services.kubenyx-pki = {
      description = "Kubenyx PKI generation";
      wantedBy = [ "kubenyx.target" ];
      # network-online: node-IP autodetection must see the real address on
      # the very first boot, or the apiserver/kubelet SANs are wrong and the
      # next activation regenerates them (breaking no-op idempotency).
      after = [
        "local-fs.target"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe pkiScript;
      };
    };
  };
}
