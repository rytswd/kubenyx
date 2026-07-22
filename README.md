# Kubenyx

[![CI](https://github.com/rytswd/kubenyx/actions/workflows/ci.yml/badge.svg)](https://github.com/rytswd/kubenyx/actions/workflows/ci.yml)

**Stock Kubernetes as NixOS systemd services — real clusters in
seconds, recreated in milliseconds.**

## 🌄 Overview

Kubenyx runs unmodified upstream Kubernetes (kube-apiserver, kubelet,
containerd, CoreDNS — no forks, no bundling) as plain systemd services,
declared entirely in Nix. It exists so "give me a real cluster" is
something a test harness can afford to say.

Two things set it apart:

**⚡ Recreation, not just fast boots.** Snapshot a cluster-ready
microVM once, then restore it in **~28 ms** — a live, node-Ready
Kubernetes cluster cheaper than a process fork, as many times as you
like. Image-bundling distributions structurally can't offer this:
their airgap payload *is* the node. Kubenyx's node is a Nix closure,
so the whole running machine — datastore, PKI, kubelet connections —
is just state to snapshot. Clones step their clocks and reseed their
CRNG automatically, so every restore is safe to treat as a fresh
cluster.

**🌐 Multi-node is one command.** `nix run .#cp1w2` boots a
3-node cluster (server + 2 agents) to all-Ready in **~3.8 s** —
membership, credentials, pod routing all derived from one declared
attrset, no join tokens, no discovery. And meshes recreate too:
snapshot all nodes with a consistent cut, restore the entire cluster
in **~45 ms** with cross-node connections intact. A 7-node variant
ships alongside; recreation stays ~flat in node count.

| What | Measured¹ |
|---|---|
| Fresh microVM cluster, cold boot → node Ready | **~3.4 s** |
| Recreating a cluster from a snapshot (`kubenyx snap`) | **~28 ms** |
| 3-node mesh: launch → all-Ready / recreate all nodes | **~3.8 s / ~45 ms** |
| Full-VM node Ready vs k3s in identical airgapped VMs | **0.67–0.80×** (faster) |
| PKI: full cluster CA + 18 certs + kubeconfigs, per boot | **~6 ms** |

¹ EC2 `*.metal` (KVM), firecracker guests, in-guest monotonic clock.
Full methodology and history: [`bench/RESULTS.md`](bench/RESULTS.md).

Everything in the fast path that used to be a bottleneck was rebuilt in
Rust (`rust/`): PKI generation, readiness probing, an in-memory etcd
shim, and the snapshot tool.

## 📖 How to Use

Everything from a 3-second throwaway cluster to a durable HA
deployment. Start at *Getting Started*, then pick a topology under
*Run Strategies*.

### Requirements

- **Nix** with flakes enabled (`experimental-features = nix-command flakes`)
- **x86_64-linux**
- For the microVM paths: **`/dev/kvm`** — on EC2 that means a `*.metal`
  instance type (regular Nitro instances have no nested virt). Check
  with `ls /dev/kvm` before anything else.
- Without KVM everything still works under emulation (`cp1` falls back
  to qemu automatically, and the NixOS test matrix never needs KVM) —
  just ~6.5× slower.

### Getting Started

The shortest path to a real cluster you can `kubectl` against:

```console
$ sudo ip tuntap add kubenyx-tap0 mode tap && \
  sudo ip addr add 10.100.0.1/24 dev kubenyx-tap0 && \
  sudo ip link set kubenyx-tap0 up          # host tap, once per boot

$ nix run github:rytswd/kubenyx > console.log 2>&1 &
$ curl -s 10.100.0.2:10124 > kubenyx.kubeconfig    # after ~3.4s
$ kubectl --kubeconfig kubenyx.kubeconfig get nodes
NAME      STATUS   ROLES    AGE   VERSION
kubenyx   Ready    <none>   16s   v1.36.2
```

That's it — a fresh, honest, fully volatile cluster. Everything else
lives in the sections below.

### Installation

Nothing to install for the quick paths — every command in this README
works via `nix run github:rytswd/kubenyx#…` and fetches what it needs.
When you want the `kubenyx` CLI (snapshots, PKI custody, probes)
around for longer:

**In a shell, for the session** — on PATH now, gone with the shell:

```console
$ nix shell github:rytswd/kubenyx#kubenyx
$ kubenyx --help
```

**Declaratively, on NixOS or home-manager** — add the flake input and
the package:

```nix
# flake.nix
inputs.kubenyx.url = "github:rytswd/kubenyx";

# NixOS
environment.systemPackages = [ inputs.kubenyx.packages.${pkgs.stdenv.hostPlatform.system}.kubenyx ];

# …or home-manager
home.packages = [ inputs.kubenyx.packages.${pkgs.stdenv.hostPlatform.system}.kubenyx ];
```

**Without Nix** — the CLI is a single static binary (musl, ~4.2 MB,
zero dependencies): download `kubenyx`, `chmod +x`, done. The CLI
verbs work standalone today; the self-contained microVM guest bundles
it will launch are planned work.

The *cluster module* and the *libraries* (`lib.harness`,
`lib.microvm`) live in your own flake instead of on a PATH:
`nix flake init -t github:rytswd/kubenyx` scaffolds it, or add the
input by hand — see [Beyond microVMs](#beyond-microvms).

### Run Strategies

The microVM variants below are the disposable fast path (the mesh is
all-firecracker; single-node picks its hypervisor at run time, see
*Hypervisors* below). The same module also runs on **any NixOS host** — that
is where the durable features live (HA quorum, CA custody, hitless
scale-out; see *In your own NixOS configuration*) — and embeds in
**NixOS VM tests** via `lib.harness` (standard test-driver VMs, not
microVMs).

Every topology supports both start modes — pick your cell:

| | Cold start | Snapshot recreation |
|---|---|---|
| **Single node** | `nix run .#cp1` — **~3.4 s** | `kubenyx snap resume` — **~28 ms** |
| **Multi-node mesh** | `nix run .#cp1w2` — **~3.8 s** | `kubenyx snap mesh-resume` — **~45 ms** |
| **Multi-CP quorum** | `nix run .#cp3` — **~6.5 s** | `kubenyx snap mesh-resume` — **~48 ms** |

Target names spell the composition: `cp<N>w<M>` = *N* control-plane
nodes + *M* workers (`cp1` alone = single node, also the bare
`nix run github:rytswd/kubenyx` default). Every target has a `-down`
twin for teardown.

<details>
<summary>🖥️⚡ <b>Single node — cold start</b> · <b>~3.4 s</b> · console, host-side kubectl, hypervisors, shutdown</summary>

##### Boot

If you ran the mesh launcher (`nix run .#cp1w2`, below) on
this host boot, skip the tap commands from Getting Started: the
launcher already created `kubenyx-tap0` enslaved to the `kubenyx-br0`
bridge, and the bridge holds `10.100.0.1/24` — adding the address to
the tap as well would put the same address on two interfaces. The
single-node variant works unchanged behind the bridge.

```console
$ nix run github:rytswd/kubenyx
...
KUBENYX-PHASE etcd-mem up=1.62
KUBENYX-PHASE kubelet up=2.06
KUBENYX-PHASE kube-apiserver up=2.37
KUBENYX-PHASE kubenyx-addons up=2.65
KUBENYX-CLUSTER-READY uptime=3.40s
```

That marker means: node Ready, RBAC + addons applied. The serial
console autologs you in as root (press Enter if the prompt needs a
redraw) and `kubectl` works immediately in the guest.

##### The console is the VM's stdio

`exit` just re-logs you in (autologin), and there is no detach escape —
park this terminal and do everything from a second one (host-side
kubectl below), or background the VM from the start:
`nix run .#cp1 > console.log 2>&1 &`.
Do NOT Ctrl-Z the console — that suspends the VMM and freezes the
guest's vCPUs, not just the terminal.

##### Host-side kubectl

Credentials are minted per boot inside the guest, so this is the
credential path — and it never touches your `~/.kube/config`:

```console
$ curl -s 10.100.0.2:10124 > kubenyx.kubeconfig
$ export KUBECONFIG=$PWD/kubenyx.kubeconfig
$ kubectl get nodes    # full TLS verification
```

Re-fetch after every boot — each boot mints a fresh PKI. The endpoint
is restricted to the tap gateway, so in-cluster workloads can't reach
it; any local host process can, which on a disposable volatile test
cluster is the same trust as the tap itself.

##### Shutdown

`poweroff` in the guest shell, or from another terminal (same
directory — the control socket is relative):

```console
$ nix run .#cp1-down
```

Bounded graceful attempt, then SIGTERM, then SIGKILL — firecracker
guests have no i8042, so Ctrl-Alt-Del alone would hang forever; the
ladder guarantees a fast exit either way.

##### Hypervisors

`cp1` picks the hypervisor at run time: **firecracker** when `/dev/kvm`
is usable, otherwise a loud fallback to **qemu** — the only variant
that runs without KVM. Override with `KUBENYX_HV`:

| `KUBENYX_HV=` | Needs | Notes |
|---|---|---|
| `firecracker` (default) | KVM | fastest; snapshot/restore capable |
| `qemu` | nothing | SLiRP user networking, works under pure emulation (~6.5× slower) |
| `cloud-hypervisor` | KVM | ~equal boot speed; kept as an A/B reference |

All variants share the tap/MAC/IP — **run one at a time**.

Everything is volatile by design: tmpfs root over a read-only store
image, in-memory datastore, PKI regenerated in ~6 ms per boot. Kill the
VM, run it again, get a fresh honest cluster.

</details>

<details>
<summary>🖥️📸 <b>Single node — snapshot recreation</b> · <b>~28 ms</b> · take once, resume fresh forever</summary>

Cold boot is the slow path. Snapshot a ready cluster once, then
recreate it from memory whenever a test wants one (needs the tap and
KVM):

```console
$ mkdir work && cd work    # short path — API sockets live in CWD

# One-time: boot to cluster-ready, snapshot, tear down (~9s total)
$ nix run github:rytswd/kubenyx#kubenyx -- snap take \
    --runner "$(nix build github:rytswd/kubenyx#microvm-firecracker --print-out-paths)/bin/microvm-run" \
    --out /dev/shm/kubenyx-snap

# From now on: a live cluster in ~28ms, as many times as you like
$ nix run github:rytswd/kubenyx#kubenyx -- snap resume --snapshot /dev/shm/kubenyx-snap
spawn_to_sock_ms=2.1 load_ms=11.9 load_to_api_ms=14.1 total_ms=26.0 pid=12345 ...
cluster:    https://10.100.0.2:6443
kubeconfig: curl -s 10.100.0.2:10124 > kubenyx.kubeconfig && kubectl --kubeconfig kubenyx.kubeconfig get nodes
stop:       kill 12345

# Benchmark the loop yourself
$ nix run github:rytswd/kubenyx#kubenyx -- snap cycle --snapshot /dev/shm/kubenyx-snap -n 5
cycles=5 median_total_ms=28.4 min=26.0 max=31.5
```

Already have a VM running (`nix run .#cp1` in another
terminal)? Snapshot it in place — pause → snapshot → resume, the guest
never notices (~1.3 s, run from the VM's directory):

```console
$ nix run github:rytswd/kubenyx#kubenyx -- snap take --sock kubenyx.sock --out /dev/shm/kubenyx-snap
```

`resume` leaves the VM running and prints its pid; kill that pid to free
the tap. One restored clone at a time (the tap identity is baked into
the snapshot). Restored guests get their wall clock stepped
automatically (host sends UDP time pokes; the in-guest
`kubenyx-clockstep` daemon applies them) and reseed their CRNG via
vmgenid, so clones are safe to treat as fresh clusters.

Keep the snapshot on tmpfs (`/dev/shm`) as shown — restores demand-page
the 3.5 GB memory image, and tmpfs makes that free.

> Snapshots are VMM-version-locked; the `kubenyx` CLI from the flake ships
> the matching firecracker on PATH. They are also host-locked artifacts,
> and the manifest enforces it: `take` records the node closure hash,
> VMM store path and host CPU fingerprint, and `resume`/`mesh-resume`
> refuse any mismatch loudly before a VMM is spawned (a snapshot
> silently assumes the minting host's CPU feature set — moving one to a
> different host has a measured history of guest kernel panics).
> Mint-per-host is the policy; a firecracker CPU template (see the
> firecracker fine print below) keys the identity to the template
> instead. Details, gotchas and design:
> [`air/v0.1/snapshot/snapshot-restore.org`](air/v0.1/snapshot/snapshot-restore.org).

</details>

<details>
<summary>🌐⚡ <b>Multi-node mesh — cold start</b> · <b>~3.8 s</b> · 3 or 7 nodes, one command; any size via <code>lib.microvm</code></summary>

```console
$ nix run github:rytswd/kubenyx#cp1w2
cp1w2: configuring host bridge kubenyx-br0 + taps (sudo)
[server] ...
[agent1] ...
[agent2] ...
KUBENYX-MESH-READY nodes=3 wall=3844ms
KUBENYX-KUBECONFIG curl -s 10.100.0.2:10124 > kubenyx.kubeconfig
```

One command: per-node taps on a host bridge, server first, agents in
parallel, per-node consoles merged with name prefixes. Membership,
addresses, credential handoff ports — everything derives from one
declared attrset. The 7-node twin is `nix run .#cp1w6`
(own run dir, so snapshots of both sizes coexist). Teardown:
`nix run .#cp1w2-down` (agents drain first, server last).

Any other size is two lines in your own flake — the presets above are
just calls into `lib.microvm.mkCluster`:

```nix
kubenyx.lib.microvm.mkCluster {
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  agents = 9;                     # 1 control plane + 9 workers
  name = "cp1w9";                 # launcher binary + console prefix
  runDir = "/tmp/kubenyx-cp1w9";  # per-size run dir; snapshots coexist
  # subnet = "10.101.0.0/24";     # non-default subnet = own bridge + taps
}
# => { members, bootOrder, nodes, runners, launcher, shutdown }
```

**Concurrent meshes.** The default subnet (`10.100.0.0/24`) is a
singleton — one mesh at a time, and the presets all use it. Give a
second mesh its own `subnet` and every derived name changes with it
(bridge `kubenyx-br-<hash>`, taps `kx-<hash>-t<N>`, MACs, addresses),
so two meshes on one host cannot collide by construction. A default
`cp1w2` and a `10.101.0.0/24` mesh have run side by side, both Ready,
with scoped teardown. One caveat, honestly: the published timing
numbers come from a solo host — concurrent meshes contend for the same
cores, so don't benchmark two at once.

`launcher`/`shutdown` are the same bridge-and-boot / escalation-ladder
scripts the presets ship (single-control-plane; for a volatile
multi-control-plane mesh see *Multi-CP quorum mesh* below, and for
durable HA the quorum posture under *In your own NixOS configuration*).

</details>

<details>
<summary>🌐📸 <b>Multi-node mesh — snapshot recreation</b> · <b>~45 ms</b> · consistent cut, connections intact</summary>

With a mesh running (previous section), snapshot all nodes with a
consistent cut — every node is paused before any is snapshotted, so
monotonic clocks freeze together and cross-node TCP survives the
restore:

```console
$ nix run .#kubenyx -- snap mesh-take --run-dir /tmp/kubenyx-cluster --out /dev/shm/mesh-snap
$ nix run .#kubenyx -- snap mesh-cycle --snapshot /dev/shm/mesh-snap -n 5
mesh_cycles=5 nodes=3 median_total_ms=45.0 min=34.2 max=53.2
```

After every restore, `kubectl get nodes` shows all nodes Ready with the
original kubelet connections intact. Recreation is ~flat in node
count — the 7-node mesh recreates in the same tens-of-ms band
(see [`bench/RESULTS.md`](bench/RESULTS.md)).

</details>

<details>
<summary>🏛️ <b>Multi-CP quorum mesh</b> · <b>~6.5 s / ~48 ms</b> · real etcd quorum, per-run CA, failover</summary>

```console
$ nix run github:rytswd/kubenyx#cp3
cp3: configuring host bridge kubenyx-br0 + taps (sudo)
[server1] ...
[server2] ...
[server3] ...
KUBENYX-MESH-READY nodes=3 wall=6545ms
```

Three control-plane microVMs forming a genuine 3-member etcd quorum —
still the disposable volatile posture (tmpfs state, per-boot PKI), p50
**~6.5 s** to all-Ready over 5 pinned boots, 1.72× the single-CP
`cp1w2` mesh. `nix run .#cp3w2` adds two workers riding
`kubenyx-lb`: agents dial `https://127.0.0.1:6444` with client-side
failover across all three apiservers, 5 nodes all-Ready in ~9.4 s (the
extra wall is the workers gating on the LB's first healthy backend, not
the quorum). Teardown: `.#cp3-down` / `.#cp3w2-down`.

**The CA handoff.** A quorum needs one trust root, and three volatile
servers would each mint their own — etcd peer TLS would then reject
every raft connection and no quorum would ever form. So the launcher
mints a per-run CA (~8 ms) and serves the bundle once per server over
the host bridge before any VM launches; a `kubenyx-ca-fetch` oneshot in
each server lands the custody files before the PKI unit runs, and a
failed fetch is a loud boot error — never a silent self-mint that
splits the mesh into three trust roots. The bundle dies with the run;
it never becomes operator custody.

**Kubeconfig per server.** Every server serves its own admin kubeconfig
on `:10124` — curl any of `10.100.0.2/.3/.4`; on server loss, re-curl a
survivor.

**Failover, measured**: kill a server VM outright and the surviving
quorum serves reads within ~0.3 s and writes within ~0.4 s; the
workers' `kubenyx-lb` evicts the dead backend after ~2.7 s (500 ms
probes × 3 failures) and running pods never notice.

**What cp3 is and is not.** All cp3 members hang off one host bridge on
one physical host: the quorum protects against *VM/process* failure,
never host failure — host loss kills all three tmpfs members exactly
like it kills etcd-mem. What cp3 buys over cp1: apiserver/etcd process
failover, rolling control-plane restarts, and testing HA behaviors
(leader elections, LB failover) against a real quorum. What it costs:
the measured quorum tax (~120 ms formation p50 — the feared 1–2 s
bootstrap tail turned out to be a host-bench artifact, see
`bench/RESULTS.md`), `backend=etcd` instead of etcd-mem, and a bigger
memory/tmpfs footprint.

**Snapshot recreation** works on the quorum too: the same
`kubenyx snap mesh-take` / `mesh-cycle` verbs bring all three control
planes back in **~48 ms** (5-cycle median), and on multi-server meshes
each round prints two probes — the first apiserver TLS answer (~18 ms)
and the first *committed* etcd write (~97 ms; a 401 can fake TLS, only
a quorum can commit). Raft never notices the freeze: the term stays
pinned across cycles, aged resumes (81 s / 630 s) show zero node flaps,
and a deliberately 2 s-skewed resume costs exactly one pre-vote
election with writes back at ~0.45 s. Volatile-only, enforced:
`mesh-take` refuses a durable-posture mesh loudly — firecracker
snapshots exclude disk contents, so only cp3's tmpfs state (riding
inside `snap.mem`) resumes consistently. Numbers and gates:
[`bench/RESULTS.md`](bench/RESULTS.md).

</details>

### Beyond microVMs

The same module and libraries run outside the disposable microVM path —
on real NixOS hosts (where the durable features live) and inside the
standard NixOS test driver.

<details>
<summary>🏠 <b>In your own NixOS configuration</b> · flake template, options, declared multi-node, durable HA</summary>

##### Single node

```console
$ nix flake init -t github:rytswd/kubenyx
```

or add it by hand:

```nix
{
  inputs.kubenyx.url = "github:rytswd/kubenyx";

  outputs = { nixpkgs, kubenyx, ... }: {
    nixosConfigurations.my-cluster = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        kubenyx.nixosModules.default
        {
          kubenyx.enable = true;   # that's it — single-node test cluster
        }
      ];
    };
  };
}
```

`kubectl` is preconfigured for root. The options you'll actually reach
for:

```nix
kubenyx = {
  enable = true;

  # "testing" (default) moves defaults toward disposable speed;
  # "balanced" keeps durable defaults. Every option stays overridable.
  profile = "testing";

  # kine-sqlite (default, persistent) | etcd | etcd-mem (in-memory,
  # volatile single-node only — the microVM guests use this)
  datastore.backend = "kine-sqlite";
  datastore.volatile = true;        # tmpfs state: fastest, disposable

  # Bring your own CNI (NetworkPolicy, encryption, kube-proxy
  # replacement): kubenyx steps aside entirely — no conflist, no
  # routes, no NAT. Pair with network.kubeProxy.enable = false when
  # the CNI replaces the service plane too.
  network.cni = "external";         # default: "bridge" (zero-daemon)

  # PVC-shaped workloads without a provisioner daemon: declared local
  # PVs + a no-provisioner default StorageClass.
  storage.localVolumes = { count = 4; size = "10Gi"; };

  # Declarative addons: every manifest here is applied at boot.
  addons.manifests.my-namespace = {
    apiVersion = "v1";
    kind = "Namespace";
    metadata.name = "my-app";
  };
};
```

IPv6 single-stack works through the same options — declare v6
addresses and CIDRs and everything (SANs, routes, service VIPs, DNS)
follows; family mixing is an eval-time error.

##### Multi-node

Membership is declared in Nix — no runtime discovery, no join tokens.
The server mints per-node credentials; you ship an agent its directory
(that's the whole join protocol):

```nix
# Server
kubenyx = {
  enable = true;
  role = "server";
  datastore.backend = "etcd";   # kine/etcd-mem are single-node by assertion
  nodes = {
    server1 = { index = 0; address = "192.168.1.10"; role = "server"; };
    agent1  = { index = 1; address = "192.168.1.11"; };
  };
};

# Agent
kubenyx = {
  enable = true;
  role = "agent";
  controlPlaneEndpoint = "192.168.1.10";
  nodes = { /* same attrset */ };
};
```

Then copy the contents of `/var/lib/kubenyx/pki/nodes/agent1/` from the
server into the agent's `/var/lib/kubenyx/pki/` (any secure channel; a
path unit picks it up and renders the kubeconfigs — the module enforces
key permissions itself, so the transport doesn't need to preserve
modes). See [`tests/multi-node.nix`](tests/multi-node.nix) for the
working end-to-end flow.

Beyond that, declared membership scales in both directions:

- **Compute scale-out is hitless**: add a node to the attrset, rebuild,
  ship, boot — zero control-plane restarts, running pods untouched
  (proven by the `agent-add` check).
- **HA control plane**: declare 3 servers and you get an etcd quorum,
  client-side failover LB on agents, and operator-custody CA — and the
  control plane *grows* declaratively too (1→3 via etcd learners,
  `server-add` check).

</details>

<details>
<summary>🧪 <b>Embedding in NixOS VM tests</b> · <code>lib.harness.mkCluster</code>, snapshot verbs between subtests</summary>

`lib.harness.mkCluster` turns one members attrset into the node modules
*and* the driver Python a `runNixOSTest` needs — addresses resolved from
the driver's own assignment (v4 or v6), the credential ship, every
readiness gate, and a kubectl wrapper:

```nix
let
  cluster = kubenyx.lib.harness.mkCluster {
    members = {
      server = { index = 0; role = "server"; };
      agent  = { index = 1; };            # role defaults to "agent"
    };
    defaults = { datastore.backend = "etcd"; node.seedImages = [ myImage ]; };
    # externalCni = true;                 # your CNI owns the dataplane
    # cniReplacesServicePlane = true;     # ...and the service plane
  };
in {
  nodes = cluster.nodes;                  # merge peripheral VMs alongside
  testScript = ''
    start_all()
    ${cluster.waitReady}
    kubenyx_kubectl(server, "get nodes")
  '';
}
```

Works without flakes too: `import <kubenyx>/lib/harness.nix { inherit lib; }`
(the generated modules already import the kubenyx module tree by path —
don't import it a second time on the same node). The
[`harness`](tests/harness.nix) check is exactly this consumer, kept
minimal on purpose. Generated `waitReady` covers single-server clusters;
multi-server bring-up needs the CA custody ceremony from
[`tests/multi-server.nix`](tests/multi-server.nix).

##### Rewinding the cluster between subtests

`mkCluster { snapshotable = true; }` adds in-driver snapshot verbs to
the generated Python: `kubenyx_snapshot_all()` freezes every node with
a consistent cut (stop-all, `savevm` each, cont-all — same discipline
as the firecracker mesh snapshots) and `kubenyx_restore_all()` rewinds
the whole cluster to that point, fixing each guest's wall clock on the
way back. Snapshot once after `waitReady`, then every subtest — or
every retry of a flaky one — starts from genuinely pristine state
instead of trusting cleanup:

```nix
testScript = ''
  start_all()
  ${cluster.waitReady}
  kubenyx_snapshot_all()        # once, after generic bring-up
  # ... mutate, assert ...
  kubenyx_restore_all()         # byte-honest rewind; repeatable
'';
```

Honest cost label: this verb is **seconds-class**, not milliseconds —
`loadvm` loads guest RAM eagerly (~7–13 s per restore at 4 G; the
per-node walls run in parallel, so the cut tracks the slowest node,
not the sum). It amortizes a ~28 s bring-up across N subtests; if your
subtests are cheaper than the restore, don't use it. Subtest style
matters too: wait-for-condition gates survive a resume, "assert event
observed" style does not. The
[`harness-snapshot`](tests/harness-snapshot.nix) check is the dogfood
(rewind-twice proven).

##### Which verb at which layer

| Layer | Verb | Cost | What it buys |
|---|---|---|---|
| Cold boot (microVM) | `nix run .#cp1` / `.#cp3` | ~3.4 s / ~6.5 s | A fresh cluster from nothing; mints the snapshots below |
| Recreation (microVM, per host) | `kubenyx snap resume` / `mesh-resume` | ~28–48 ms | A live cluster per test *run*, cheaper than a fork |
| Rewind (NixOS test driver) | `kubenyx_restore_all()` | seconds | Pristine state per *subtest* inside one driver run |

</details>

## 🔬 Tests & Benchmarks

```console
# The matrix (KVM is picked up automatically)
$ nix build .#checks.x86_64-linux.single-node.driver -o d && d/bin/nixos-test-driver

# Head-to-head vs k3s in identical airgapped VMs
$ nix build .#checks.x86_64-linux.bench-vs-k3s.driver -o b && b/bin/nixos-test-driver

# Native control-plane timings on the build host (no VM)
$ nix run .#native-bench
```

### Why not kind / k3d / minikube?

Measured head-to-head on the same quiet 384-core KVM host
(2026-07-21; rootless podman 5.8.2, one warm-up then medians of ≥3
timed runs, image caches warm — full method, raws, and tool versions
in [`bench/RESULTS.md`](bench/RESULTS.md)):

| | create → node Ready | fresh cluster again | milliseconds path |
|---|---|---|---|
| **kubenyx** `cp1` | **~3.4 s** (cold boot) | cold-boot again, ~3.4 s | snapshot recreation **~28–33 ms** |
| kind v0.31.0 | 31.3 s | delete + create, 42.6 s | — |
| minikube v1.38.1 | 33.8 s | delete + create, 42.9 s | — |
| k3d v5.8.3 | not benchable on that host¹ | — | — |

Honest caveat, stated plainly: kind/minikube/k3d run **containers
sharing the host kernel** — no hardware isolation — while kubenyx
boots **hardware-isolated microVMs**, so kubenyx is doing strictly
more work per cluster and still reaches node-Ready ~9× sooner. Their
API-usable milestone (first `kubectl` success) is ~15–16 s. The gap
that matters most for test harnesses is the second column: their only
fresh-cluster-again story is delete + create at ~43 s; kubenyx
restores a snapshot in tens of milliseconds (~1000×).

¹ k3s hard-requires the cpuset cgroup-v2 controller, which rootless
podman user slices don't delegate by default; k3d itself likely works
rootful or under docker.

Two harness gotchas worth knowing (found the hard way, recorded in
`bench/RESULTS.md`):

- **Concurrent test drivers collide**: the NixOS test driver keys vde
  sockets and `vm-state-*` dirs off `XDG_RUNTIME_DIR` with no per-run
  namespace. Running two drivers at once hangs the loser at
  "start all VLans". Give each run its own `XDG_RUNTIME_DIR`.
- **Absolute VM timings under TCG are meaningless** — only ratios in
  identical VMs count. On this project TCG turned out to be ~6.5×
  slower than KVM, not the 12–15× folklore.

## 📚 Reference

A few directories whose purpose isn't obvious from the file view:

- `air/` — the planning docs, written with [Air](https://github.com/withre/air):
  the *why* behind every phase, organized by area — start at
  [`air/v0.1/OVERVIEW.org`](air/v0.1/OVERVIEW.org)
- `rust/` — all the tools as one multicall `kubenyx` binary; per-tool
  crates are libraries behind the dispatcher
- `guests/` — the shared microVM guest profile (fast-boot units,
  credential handoff, phase markers)
- `bench/` — measurement methodology and the running results log
  ([`bench/RESULTS.md`](bench/RESULTS.md))

<details>
<summary><b><code>nix run</code> apps & packages</b></summary>

### Apps

| App | What it does |
|---|---|
| `.#cp1` (= bare `nix run github:rytswd/kubenyx`) | Single-node disposable cluster (~3.4 s to ready); hypervisor via `KUBENYX_HV`, auto-falls back to qemu without KVM |
| `.#cp1-down` | Guest shutdown with escalation ladder; run from the VM's directory |
| `.#cp1w2` / `.#cp1w2-down` | 3-node mesh (1 control plane + 2 workers), bridge + taps via sudo, ~3.8 s to all-Ready / reverse teardown |
| `.#cp1w6` / `.#cp1w6-down` | 7-node twin (1 control plane + 6 workers), run dir `/tmp/kubenyx-cluster7`, ~4.2 s |
| `.#cp3` / `.#cp3-down` | 3-control-plane quorum mesh (real 3-member etcd, launcher-minted per-run CA), ~6.5 s to all-Ready |
| `.#cp3w2` / `.#cp3w2-down` | Quorum mesh + 2 workers on `kubenyx-lb` (client-side apiserver failover), ~9.4 s |
| `.#microvm-<hypervisor>[-shutdown]` | Direct per-hypervisor entry points (`firecracker`, `cloud-hypervisor`, `qemu`) — what `cp1` dispatches to |
| `.#microvm-cluster*` | Deprecated aliases of the `cp1w2`/`cp1w6` targets |
| `.#native-bench` | Control-plane timings as bare processes, no VM |

### Packages beyond the app-backing ones

| Package | Contents |
|---|---|
| `.#kubenyx` | **The CLI** — one multicall binary, every tool a verb (`snap`, `pki`, `ready`, `clockstep`, `lb`, `etcd-mem`), wrapped with the version-matched firecracker on PATH: `nix run .#kubenyx -- snap take …` |
| `.#kubenyx-snap` | Alias of the same binary for the `snap` verb (kept for muscle memory; `kubenyx-snap take` ≡ `kubenyx snap take`) |
| `.#kubenyx-tools` | The multicall binary as guests ship it, plus legacy-name symlinks (`kubenyx-pki`, `kubenyx-ready`, `etcd-mem`, `kubenyx-clockstep`, `kubenyx-snap`) — argv0 dispatch, so every unit and script path resolves unchanged |
| `.#kubenyx-lb` | Thin symlink package over the same binary (`bin/kubenyx-lb`). Its old keep-out-of-guest-closures rationale was retired by measurement: folding lb into the multicall costs 52 KB — the weight was the TLS stack the other verbs already share |
| `.#microvm-cluster-{server,agent1,agent2}`, `.#microvm-cluster7-{server,agent1..6}` | Per-node mesh runners |
| `.#pause-image`, `.#test-image` | Airgap seed images |

</details>

<details>
<summary><b>Checks matrix</b> — 23 legs, all green</summary>

`nix build .#checks.x86_64-linux.<name>.driver -o d && d/bin/nixos-test-driver`
— give each **concurrent** run its own `XDG_RUNTIME_DIR` (the driver keys
vde sockets and vm-state off it with no per-run namespace).

| Check | Proves | Wall (KVM) |
|---|---|---|
| `single-node` / `single-node-etcd` | Happy path on kine / real etcd | 37 s / 153 s |
| `harness` | `lib.harness` dogfood: server+agent stood up exclusively through the exported helper | 39 s |
| `harness-snapshot` | In-driver snapshot verbs: consistent savevm cut after Ready, mutate, loadvm rewind-twice; per-node walls parallel | 62 s (testScript) |
| `snapshot-mint` | A snapshot as a *derivation output*: boot to Ready, parallel savevm cut, per-node qcow2 + identity manifest into `$out` | 26 s |
| `snapshot-restore` | Consumes the mint drv as a real input: identity gate, paused spawn, parallel loadvm, pre-mint mutation gone, fresh write lands | 19 s |
| `multi-node` / `multi-node-mem` | Server + agent on etcd / on etcd-mem | 38 s / 22 s |
| `multi-server` | 3-server etcd quorum + LB agent + CA custody | 50 s |
| `quorum-volatile` | The cp3 posture: pre-seeded CA custody, quorum on tmpfs, join-probe fast-exit, cross-server write/read; require-shipped-ca refuses before the ship | 34 s |
| `failover` | Server crash + etcd kill -9; API rides through the LB | 59 s |
| `agent-add` | Hitless compute scale-out (zero restarts anywhere) | 95 s |
| `server-add` | Declarative 1→3 control-plane growth via etcd learners; shrink refused | 156 s |
| `server-reboot` | Full VM reboot of a quorum member; state survives | 98 s |
| `ca-custody` | Durable CA gate refuses, then boots shipped | 30 s |
| `external-cni` | BYO-dataplane mode: kubenyx writes nothing, the test's conflist wins | 47 s |
| `local-storage` | Declared local PVs + default StorageClass; data survives pod recreate | 95 s |
| `ipv6` / `ipv6-multi` | All-v6 single-stack, single + cross-node over `ip -6` routes | 44 s / 54 s |
| `lib-tests` | 29 eval-level CIDR/hostPort cases — no VM | ~1 s |
| `prebake` / `prebake-bench` | Build-time containerd stores; ≥90% import-cost contract | 45 s / 66 s |
| `bench-vs-k3s` | Head-to-head ratio in identical airgapped VMs | 50 s |

Plus `nixosModules.default`, `templates.default` (`nix flake init -t`),
and the per-variant `nixosConfigurations`.

</details>

<details>
<summary><b>The <code>kubenyx</code> CLI</b> — one binary, every tool a verb</summary>

All the tools live in **one multicall binary** with subcommands:

```console
$ nix run .#kubenyx -- --help
kubenyx <verb> …   verbs: snap | pki | ready | clockstep | lb | etcd-mem
```

Two equivalent surfaces, by design: `kubenyx snap take …` and the
legacy name `kubenyx-snap take …` dispatch to the same code (argv0
symlinks) — so scripts, systemd units, and muscle memory written
against the per-tool names keep working verbatim, while the
single-binary form is what a future no-Nix distribution ships
(the whole toolset is one **4.2 MB static musl binary**).

### `kubenyx snap` — snapshot verbs

| Subcommand | Option | Default | Meaning |
|---|---|---|---|
| `take` (boot-fresh) | `--runner PATH` | *(selects this mode)* | microvm-run to spawn, snapshot, tear down |
| | `--out DIR` | `snapshot` | Where `snap.vmstate` + `snap.mem` land |
| | `--marker STR` | `KUBENYX-CLUSTER-READY` | Console marker to wait for |
| | `--wait-secs N` / `--settle-ms N` | 120 / 2000 | Marker timeout / post-ready settle |
| `take` (attach) | `--sock PATH` | `kubenyx.sock` | Snapshot a *running* VM: pause → create → resume in place |
| `resume` | `--snapshot DIR` | `snapshot` | Restore into a fresh VMM, leave it running |
| | `--firecracker BIN` | from PATH | Must match the snapshot's VMM version |
| | `--cpu-template PATH\|literal` | *(none)* | Required for template-keyed snapshots; exact-string match against the manifest, no subset logic |
| | `--allow-identity-mismatch` | off | Override the identity refusal (closure/VMM/CPU triple) — loudly |
| | `--api-sock NAME` | `kubenyx-resume.sock` | Keep it relative (SUN_LEN) |
| | `--probe ADDR` / `--poke ADDR` | `10.100.0.2:6443` / `:10123` | API liveness probe / clock-poke target |
| | `--no-pci` | off | Only for snapshots taken without `--enable-pci` |
| `cycle` | resume's flags + `-n N` | 5 | Recreation benchmark: resume → verify → kill, ×N |
| `mesh-take` | `--run-dir DIR` | `/tmp/kubenyx-cluster` | Pause ALL nodes, snapshot in parallel, free the taps |
| | `--out DIR` | `mesh-snapshot` | Per-node subdirs + manifest |
| | `--node name=ip` (repeat) | auto-discovered | Only needed off-convention (launcher manifest, else `server`/`server1`=.2, `serverN`=.1+N, agents after the servers) |
| `mesh-resume` | `--snapshot DIR` | `mesh-snapshot` | Concurrent restore of every node from the manifest (takes `--cpu-template` / `--allow-identity-mismatch` too) |
| `mesh-cycle` | mesh-resume's flags + `-n N` | 5 | Mesh recreation benchmark |

</details>

<details>
<summary><b>Other CLIs & firecracker fine print</b></summary>

### The other verbs

Mostly systemd-invoked inside guests; `kubenyx pki mint-ca` and
`kubenyx pki serve` are the operator-facing ones. Every verb also
answers to its legacy standalone name (`kubenyx-pki …` ≡
`kubenyx pki …`).

| Verb | Key flags |
|---|---|
| `kubenyx pki mint-ca` | `--out DIR` — offline CA custody bundle (6 files: both CAs + the SA keypair) for durable servers; also what the mesh launchers mint per run |
| `kubenyx pki serve` | `--dir DIR --listen ADDR:PORT [--count N]` — bounded tar-over-HTTP custody handoff (exits after N transfers); the mesh launchers' CA channel |
| `kubenyx pki --mode server\|agent` | the guest-unit form (systemd-invoked, not a subcommand): `--pki-dir`, `--kubeconfig-dir`, `--node-name`, `--node-address`, `--node name=addr` (per member), `--api-url`, `--service-ip`, `--cluster-domain`, `--etcd`, `--etcd-san`, `--extra-san`, `--leaf-days`, `--renew-days`, `--require-shipped-ca` |
| `kubenyx lb` | `--listen`, `--backend addr` (repeat), `--probe-interval-ms`, `--fail-threshold`, `--dial-timeout-ms`, `--drain-timeout-ms`, `--probe-cert`/`--probe-key` (pair), `--probe-http` |
| `kubenyx clockstep` | `--listen` (`0.0.0.0:10123`), `--allow-from IP`, `--min-step-ms` (500) |
| `kubenyx ready` | `--url`, `--cacert`/`--cert`/`--key` or `--insecure`, then `-- <command>` to wrap; `--wait` gates a unit start on its own first API request |
| `kubenyx etcd-mem` | the in-memory etcd shim (guest-internal; unix socket, single member by design) |

### Firecracker snapshot fine print

Encoded in the flake so you normally never see them, but if you drive
firecracker yourself:

- On AMX hosts (Granite Rapids+) a restored guest kernel-panics in
  `XRSTORS` unless the snapshot was taken with
  `clearcpuid=amx_tile,amx_int8,amx_bf16 noxsaves` (already in the
  firecracker variant's kernel params).
- A custom **CPU template** masks the same hazard at the KVM level
  instead of the guest kernel: the repo ships
  [`lib/cpu-templates/amx-mask.json`](lib/cpu-templates/amx-mask.json)
  (authored from `cpu-template-helper` dumps, sha256 committed
  alongside), threaded via
  `mkCluster { cpuTemplate = kubenyx.lib.microvm.cpuTemplates.amx-mask; }`.
  Snapshots minted under a template get a *template-keyed* identity —
  resume needs the matching `--cpu-template`, and the host CPU
  fingerprint demotes to a warning. Measured cost is inside noise
  (+1.8 % cold, +1.4 ms resume, 3-run A/B). Honesty note: same-host
  proofs are green (mask survives restore, mismatches refuse), but
  cross-host restore is unvalidated until a heterogeneous CPU pair
  exists — mint-per-host remains the policy
  ([`air/v0.1/snapshot/portable-snapshots.org`](air/v0.1/snapshot/portable-snapshots.org)).
- `--enable-pci` must match between snapshot and restore VMM.
- API socket paths must stay under 108 chars (`SUN_LEN`) — use relative
  paths from a short working directory.
- Firecracker's API server ignores `Connection: close`; read responses
  by `Content-Length` or every call stalls to your socket timeout.

</details>
