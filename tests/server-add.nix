# Control-plane scale-out (air/v0.5/cp-growth.org): a running 1-server +
# 1-agent durable cluster (operator-custody CA, persistent etcd) GROWS to 3
# servers declaratively. Activate the 3-server declaration on the running
# nodes (switch-to-configuration on pre-built specialisations, exactly like
# agent-add.nix), ship custody bundles, boot server2 and server3: the
# kubenyx-etcd-reconcile on the running servers adds each as a LEARNER (the
# correctness mechanism — a plain member-add of an unstarted member counts
# toward quorum and wedges 1->2 growth), promotes it once in sync, and the
# joining server's probe starts etcd with --initial-cluster-state existing
# narrowed to the runtime member set.
#
# Asserted through the growth window: a write loop never fails beyond one
# retry, the workload pod on agent1 never restarts, both joiners take the
# learner path and end as voting members, the pre-growth object is readable
# from every server, the agent's kubenyx-lb appears with the grown backend
# set, and every server's member-set guard file records the grown set.
# Then the shrink refusal: declaring 2 of 3 makes the reconcile refuse with
# the runbook warning (nothing removed) and the guard hard-error etcd on
# the shrunk declaration — the superset rule is one-directional — and
# restoring the 3-server declaration heals cleanly.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  kubenyxTools = pkgs.callPackage ../pkgs/kubenyx-tools.nix { };
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  common = {
    imports = [ kubenyx.nixosModules.default ];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
    };
    networking.firewall.enable = true;
  };

  # The test driver assigns VLAN addresses by *alphabetical* node order:
  # agent1 -> 192.168.1.1, server1..3 -> 192.168.1.2..4. The declared
  # addresses must match or the nodes dial the wrong peers.
  members = {
    server1 = {
      index = 0;
      address = "192.168.1.2";
      role = "server";
    };
    agent1 = {
      index = 1;
      address = "192.168.1.1";
      role = "agent";
    };
  };
  # The declared growth: two servers appended with fresh indices (indices
  # are append-only, durable-ha.org §6 discipline).
  newServers = {
    server2 = {
      index = 2;
      address = "192.168.1.3";
      role = "server";
    };
    server3 = {
      index = 3;
      address = "192.168.1.4";
      role = "server";
    };
  };

  serverBase = lib.recursiveUpdate common {
    kubenyx = {
      enable = true;
      # balanced + persistent etcd = durable posture: operator-custody CA,
      # fsync on — the only posture where growing a quorum makes sense.
      profile = "balanced";
      datastore.backend = "etcd";
      dns.upstream = [ ];
    };
  };

  # The write loop that runs THROUGH the growth window. One retry is the
  # budget (the acceptance contract): the declared activation restarts the
  # only apiserver once, so a write racing that restart may fail exactly
  # once and must land on the retry. AlreadyExists after a timed-out first
  # attempt is a success (the write committed; the response was lost).
  # Absolute binary paths: the transient systemd-run unit gets systemd's
  # default (empty-on-NixOS) PATH.
  writeLoop =
    let
      kubectl = lib.getExe' pkgs.kubectl "kubectl";
      sleep = "${pkgs.coreutils}/bin/sleep";
    in
    pkgs.writeShellScript "growth-write-loop" ''
      i=0
      while [ ! -e /root/stop-writes ]; do
        i=$((i+1))
        out=$(${kubectl} create configmap growth-w$i --from-literal=n=$i --request-timeout=5s 2>&1) \
          && { echo "ok $i" >> /root/writes.log; ${sleep} 1; continue; }
        case "$out" in
          *AlreadyExists* | *"already exists"*) echo "ok $i (dup)" >> /root/writes.log; ${sleep} 1; continue ;;
        esac
        # The single retry's backoff must cover the one legitimate outage:
        # the activation's post-reload apiserver restart — bounded to 10s
        # of stop (TimeoutStopSec) + the etcd restart it is ordered after
        # + a few seconds to /readyz (control-plane.nix records the
        # measured 60s watch-drain hang these bounds exist for). Anything
        # the retry still misses is a real failure.
        ${sleep} 30
        out2=$(${kubectl} create configmap growth-w$i --from-literal=n=$i --request-timeout=5s 2>&1) \
          && { echo "retry-ok $i" >> /root/writes.log; ${sleep} 1; continue; }
        case "$out2" in
          *AlreadyExists* | *"already exists"*) echo "retry-ok $i (dup)" >> /root/writes.log; ${sleep} 1; continue ;;
        esac
        printf 'FAIL %s: %s | retry: %s\n' "$i" "$out" "$out2" >> /root/writes.log
        ${sleep} 1
      done
      echo "done total=$i" >> /root/writes.log
    '';
in
{
  name = "kubenyx-server-add";

  nodes = {
    server1 = lib.recursiveUpdate serverBase {
      # Both the growth and the shrink attempt are PRE-BUILT
      # specialisations of the running node: "activate the declaration" is
      # switch-to-configuration on a live machine, no rebuild in the VM.
      specialisation = {
        add-servers.configuration = {
          kubenyx.nodes = newServers;
        };
        # Declares 2 of the 3 runtime servers (server3 dropped): the
        # reconcile must refuse with the runbook warning and the guard
        # must hard-error — shrink is a runbook, not machinery.
        shrink-attempt.configuration = {
          kubenyx.nodes = {
            inherit (newServers) server2;
          };
        };
      };
      kubenyx.nodes = members;
    };

    agent1 = lib.recursiveUpdate common {
      specialisation.add-servers.configuration = {
        kubenyx.nodes = newServers;
        # The single-server endpoint gives way to kubenyx-lb (its enable
        # default needs endpoint == null): the activation swaps the
        # agent's control-plane wiring to the grown backend set.
        kubenyx.controlPlaneEndpoint = lib.mkForce null;
      };
      kubenyx = {
        enable = true;
        role = "agent";
        controlPlaneEndpoint = "192.168.1.2";
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members;
      };
    };

    # The new servers are born knowing the full grown membership — they
    # never existed under the old declaration. NOT started until the
    # running cluster has activated the grown configuration.
    server2 = lib.recursiveUpdate serverBase {
      kubenyx.nodes = members // newServers;
    };
    server3 = lib.recursiveUpdate serverBase {
      kubenyx.nodes = members // newServers;
    };
  };

  testScript = ''
    import base64
    import os
    import subprocess

    # Deliberately NOT start_all(): server2/3 stay down until the running
    # cluster has activated the grown declaration.
    server1.start()
    agent1.start()

    # --- Offline CA mint (durable-ha.org §3): the driver host is the
    # operator's workstation; the trust roots exist off-cluster first.
    bundle = os.path.join(os.environ.get("TMPDIR", "/tmp"), "kubenyx-ca-bundle")
    subprocess.run(
        ["${lib.getExe' kubenyxTools "kubenyx-pki"}", "mint-ca", "--out", bundle],
        check=True,
    )
    custody = ["ca.crt", "ca.key", "front-proxy-ca.crt", "front-proxy-ca.key", "sa.key", "sa.pub"]

    def ship_custody(machine):
        machine.wait_until_succeeds(
            "journalctl -u kubenyx-pki.service | grep -q 'requires an operator-shipped CA bundle'",
            timeout=600,
        )
        machine.fail("test -e /var/lib/kubenyx/pki/ca.key")
        machine.succeed("mkdir -p /var/lib/kubenyx/pki")
        for f in custody:
            with open(os.path.join(bundle, f), "rb") as fh:
                blob = base64.b64encode(fh.read()).decode()
            machine.succeed(f"echo '{blob}' | base64 -d > /var/lib/kubenyx/pki/{f}")
        machine.succeed("systemctl restart kubenyx-pki.service")
        machine.succeed("stat -c %a /var/lib/kubenyx/pki/ca.key | grep -q 600")
        machine.succeed("systemctl reset-failed")
        machine.succeed(
            "systemctl restart --no-block etcd.service kube-apiserver.service"
            " kube-controller-manager.service kube-scheduler.service"
            " kube-proxy.service kubelet.service kubenyx-addons.service"
        )

    # --- The 1-server durable cluster comes up (custody flow as in
    # multi-server.nix, on a single server).
    ship_custody(server1)
    server1.wait_until_succeeds("systemctl is-active kube-apiserver.service", timeout=900)

    pki_blob = server1.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent1 | base64 -w0"
    ).strip()
    agent1.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && chmod 644 /tmp/agent1/*"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent1/* /var/lib/kubenyx/pki/"
    )
    agent1.succeed("systemctl start kubenyx-pki.service")
    agent1.wait_until_succeeds(
        "test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600
    )
    agent1.succeed("systemctl reset-failed")
    agent1.succeed("systemctl restart --no-block kubelet.service kube-proxy.service")

    for n in ("server1", "agent1"):
        server1.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # No LB and no reconcile exist on the 1-server cluster (fast-path
    # gating: the units appear only at serverCount > 1).
    agent1.fail("systemctl cat kubenyx-lb.service")
    server1.fail("systemctl cat kubenyx-etcd-reconcile.service")

    # --- Workload that must ride through the growth untouched: pinned to
    # agent1 (disruption test, not a scheduling test).
    server1.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    server1.succeed(
        "kubectl run steady --image=kubenyx.local/test:1 --restart=Never"
        " --overrides='{\"spec\":{\"nodeName\":\"agent1\"}}'"
    )
    server1.wait_until_succeeds(
        "kubectl get pod steady -o jsonpath='{.status.phase}' | grep -q Running",
        timeout=900,
    )

    def pod_fingerprint():
        fp = server1.succeed(
            "kubectl get pod steady -o jsonpath="
            "'{.metadata.uid}|{.status.containerStatuses[0].containerID}"
            "|{.status.containerStatuses[0].restartCount}'"
        ).strip()
        uid, cid, restarts = fp.split("|", 2)
        assert uid and cid, f"incomplete pod fingerprint: {fp!r}"
        assert restarts == "0", f"workload pod restarted: restartCount={restarts}"
        return fp

    # --- Pre-growth object + the write loop that spans the whole window.
    server1.succeed("kubectl create configmap pre-growth --from-literal=phase=before")
    steady_fp = pod_fingerprint()
    server1.succeed(
        "systemd-run --unit=growth-writer"
        " --setenv=KUBECONFIG=/var/lib/kubenyx/kubeconfigs/admin.kubeconfig"
        " ${writeLoop}"
    )
    server1.wait_until_succeeds("test -s /root/writes.log", timeout=60)

    # kubelet is deliberately absent: gaining kubenyx-lb rewires its unit
    # ordering (lb.nix: kubelet After/Wants the LB), so the LB-gaining
    # activation restarts kubelet exactly once — which never touches
    # running pods (kubelet re-attaches); the pod fingerprint below is the
    # workload-disruption contract.
    NODE_UNITS = ["containerd.service", "kube-proxy.service"]
    agent1_ids = {
        u: agent1.succeed(f"systemctl show -p InvocationID --value {u}").strip()
        for u in NODE_UNITS
    }

    etcdctl = (
        "${lib.getExe' pkgs.etcd_3_6 "etcdctl"}"
        " --endpoints=https://127.0.0.1:2379"
        " --cacert=/var/lib/kubenyx/pki/ca.crt"
        " --cert=/var/lib/kubenyx/pki/apiserver-etcd-client.crt"
        " --key=/var/lib/kubenyx/pki/apiserver-etcd-client.key"
    )
    grown = "server1=https://192.168.1.2:2380,server2=https://192.168.1.3:2380,server3=https://192.168.1.4:2380"

    # switch-to-configuration test repoints /run/current-system, so the
    # BASE system paths (which hold the specialisations) are captured now.
    server1_base = server1.succeed("readlink -f /run/current-system").strip()
    agent1_base = agent1.succeed("readlink -f /run/current-system").strip()

    # --- Activate the 3-server declaration on the RUNNING nodes. Server
    # first: its PKI rerun re-mints the etcd cert with the grown SAN set
    # and its reconcile starts converging (legacy loopback peer URL moves
    # to the declared address, server2 gets its learner slot).
    server1.succeed(f"{server1_base}/specialisation/add-servers/bin/switch-to-configuration test")
    server1.wait_until_succeeds("systemctl is-active etcd.service", timeout=300)
    server1.wait_until_succeeds(
        f"{etcdctl} member list | grep -q 'https://192.168.1.2:2380'", timeout=300
    )
    server1.wait_until_succeeds(
        f"{etcdctl} member list | grep -q 'https://192.168.1.3:2380'", timeout=300
    )
    server1.succeed(
        "journalctl -u kubenyx-etcd-reconcile.service | grep -q 'added server2 as learner'"
    )

    agent1.succeed(f"{agent1_base}/specialisation/add-servers/bin/switch-to-configuration test")
    # The agent's activation grew its control-plane wiring: kubenyx-lb now
    # exists, probes with the shipped kubelet identity, and carries the
    # full grown backend set.
    agent1.wait_until_succeeds("systemctl is-active kubenyx-lb.service", timeout=300)
    agent1.wait_until_succeeds(
        "journalctl -u kubenyx-lb.service | grep -q KUBENYX-LB-READY", timeout=300
    )
    # -o | wc -l, not -c: the rendered ExecStart is a single line carrying
    # every --backend occurrence.
    agent1.succeed(
        "test \"$(systemctl cat kubenyx-lb.service | grep -o -- --backend | wc -l)\" = 3"
    )

    # --- Boot server2: custody ship, then the join path — its probe sees
    # the healthy cluster, waits for the learner slot the reconcile
    # already added, and starts etcd with initial-cluster-state existing.
    # etcd goes active only once PROMOTED (a learner fails the
    # linearizable /readyz check, so the notify wrapper holds the unit in
    # activating until the running servers' reconcile promotes it).
    server2.start()
    ship_custody(server2)
    server2.wait_until_succeeds("systemctl is-active etcd.service", timeout=900)
    server2.succeed(
        "journalctl -u etcd.service | grep -q 'joining the existing cluster as a learner'"
    )
    server1.wait_until_succeeds(
        f"test \"$({etcdctl} member list | grep -c ', started, ')\" = 2", timeout=300
    )
    server1.wait_until_succeeds(
        f"test \"$({etcdctl} member list | grep -c ', false$')\" = 2", timeout=300
    )

    # server3's learner slot opens only after server2's promotion (etcd
    # enforces one learner at a time): the reconciles sequence it.
    server1.wait_until_succeeds(
        f"{etcdctl} member list | grep -q 'https://192.168.1.4:2380'", timeout=600
    )

    server3.start()
    ship_custody(server3)
    server3.wait_until_succeeds("systemctl is-active etcd.service", timeout=900)
    server3.succeed(
        "journalctl -u etcd.service | grep -q 'joining the existing cluster as a learner'"
    )

    # --- Grown quorum: 3 started VOTING members (learners all promoted).
    server1.wait_until_succeeds(
        f"test \"$({etcdctl} member list | grep -c ', started, ')\" = 3", timeout=600
    )
    server1.wait_until_succeeds(
        f"test \"$({etcdctl} member list | grep -c ', false$')\" = 3", timeout=300
    )
    server1.wait_until_succeeds(f"{etcdctl} endpoint health --cluster", timeout=300)

    # Learner evidence for BOTH joiners, from whichever reconcile won the
    # race (they run concurrently on every server by design).
    def reconcile_journal_somewhere(pat):
        for m in (server1, server2, server3):
            if m.execute(f"journalctl -u kubenyx-etcd-reconcile.service | grep -q '{pat}'")[0] == 0:
                return True
        return False

    for pat in (
        "added server2 as learner",
        "added server3 as learner",
        "promoted learner",
    ):
        assert reconcile_journal_somewhere(pat), f"no reconcile journal shows: {pat}"

    # --- Guard files on all three servers record the grown set (server1's
    # is written by its reconcile only after runtime matched declaration).
    for m in (server1, server2, server3):
        m.wait_until_succeeds(
            f"grep -qxF '{grown}' /var/lib/etcd/.kubenyx-member-set", timeout=600
        )

    # --- The pre-growth object is readable from EVERY server (each
    # apiserver reads through its own local etcd member).
    for m in (server1, server2, server3):
        m.wait_until_succeeds(
            "kubectl get configmap pre-growth -o jsonpath='{.data.phase}' | grep -q before",
            timeout=900,
        )

    # --- Stop the write loop: zero writes failed beyond one retry.
    server1.succeed("touch /root/stop-writes")
    server1.wait_until_succeeds("grep -q '^done ' /root/writes.log", timeout=60)
    server1.fail("grep -q '^FAIL' /root/writes.log")
    total = int(server1.succeed("grep -c '^ok\\|^retry-ok' /root/writes.log").strip())
    retried = int(server1.succeed("grep -c '^retry-ok' /root/writes.log || true").strip() or "0")
    assert total >= 30, f"write loop too short to prove anything: {total} writes"
    print(f"growth write loop: {total} writes, {retried} needed the single retry")

    # --- Zero workload disruption: same pod, same container, no restarts;
    # the agent's node plane never bounced.
    assert pod_fingerprint() == steady_fp, "workload pod changed across the growth"
    for u in NODE_UNITS:
        now = agent1.succeed(f"systemctl show -p InvocationID --value {u}").strip()
        assert now == agent1_ids[u], f"agent1: {u} restarted during the growth"

    # --- Everyone Ready, including the new servers' kubelets.
    for n in ("server1", "agent1", "server2", "server3"):
        server1.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # --- Shrink attempt (declare 2 of 3): the reconcile refuses with the
    # runbook warning and removes nothing; the guard hard-errors etcd on
    # the shrunk bootstrap flags (the superset rule is one-directional).
    server1.execute(
        f"{server1_base}/specialisation/shrink-attempt/bin/switch-to-configuration test"
    )
    server1.wait_until_succeeds(
        "journalctl -u etcd.service | grep -q 'member set changed'", timeout=120
    )
    server1.wait_until_succeeds(
        "journalctl -u kubenyx-etcd-reconcile.service | grep -q 'NOT in the declared server set'",
        timeout=300,
    )
    # Nothing was removed and the record still holds the grown set.
    server2_etcdctl = etcdctl.replace("127.0.0.1:2379", "192.168.1.3:2379")
    server2.succeed(f"test \"$({server2_etcdctl} member list | grep -c ', started, ')\" = 3")
    server1.succeed(f"grep -qxF '{grown}' /var/lib/etcd/.kubenyx-member-set")

    # --- Restore the 3-server declaration: the guard passes again and the
    # member rejoins the (still whole) quorum.
    server1.succeed("systemctl reset-failed")
    server1.succeed(f"{server1_base}/specialisation/add-servers/bin/switch-to-configuration test")
    server1.wait_until_succeeds("systemctl is-active etcd.service", timeout=300)
    server1.wait_until_succeeds(f"{etcdctl} endpoint health --cluster", timeout=300)
    server1.succeed("kubectl get configmap pre-growth -o jsonpath='{.data.phase}' | grep -q before")
    assert pod_fingerprint() == steady_fp, "workload pod changed across the shrink refusal"
  '';
}
