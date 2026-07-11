# Kubenyx

**Stock Kubernetes as NixOS systemd services — built for disposable test
clusters that appear in seconds, or milliseconds.**

Kubenyx runs unmodified upstream Kubernetes (kube-apiserver, kubelet,
containerd, CoreDNS — no forks, no bundling) as plain systemd services,
declared entirely in Nix. It exists so "give me a real cluster" is
something a test harness can afford to say:

| What | Measured¹ |
|---|---|
| Fresh microVM cluster, cold boot → node Ready | **~3.4 s** |
| Recreating a cluster from a snapshot (`kubenyx-snap`) | **~28 ms** |
| 3-node mesh: launch → all-Ready / recreate all nodes | **~3.8 s / ~45 ms** |
| Full-VM node Ready vs k3s in identical airgapped VMs | **0.67–0.80×** (faster) |
| PKI: full cluster CA + 18 certs + kubeconfigs, per boot | **~6 ms** |

¹ EC2 `*.metal` (KVM), firecracker guests, in-guest monotonic clock.
Full methodology and history: [`bench/RESULTS.md`](bench/RESULTS.md).

Everything in the fast path that used to be a bottleneck was rebuilt in
Rust (`rust/`): PKI generation, readiness probing, an in-memory etcd
shim, and the snapshot tool.

---

## Requirements

- **Nix** with flakes enabled (`experimental-features = nix-command flakes`)
- **x86_64-linux**
- For the microVM paths: **`/dev/kvm`** — on EC2 that means a `*.metal`
  instance type (regular Nitro instances have no nested virt). Check
  with `ls /dev/kvm` before anything else.
- Without KVM everything still works under emulation (the `microvm-qemu`
  variant and the NixOS test matrix) — just ~6.5× slower.

## Quick start 1 — a disposable cluster in one command

Create the host-side tap once per boot (the guest is `10.100.0.2`, the
host side is `10.100.0.1`):

```console
$ sudo ip tuntap add kubenyx-tap0 mode tap
$ sudo ip addr add 10.100.0.1/24 dev kubenyx-tap0
$ sudo ip link set kubenyx-tap0 up
```

If you have ever run the mesh launcher (`nix run .#microvm-cluster`,
see the variants table below) on this boot, skip the commands above: the launcher
already created `kubenyx-tap0` enslaved to the `kubenyx-br0` bridge,
and the bridge holds `10.100.0.1/24` — adding the address to the tap
as well would put the same address on two interfaces. The single-node
variant works unchanged behind the bridge.

Boot a cluster:

```console
$ nix run github:rytswd/kubenyx#microvm-firecracker
...
KUBENYX-PHASE etcd-mem up=1.62
KUBENYX-PHASE kubelet up=2.06
KUBENYX-PHASE kube-apiserver up=2.37
KUBENYX-PHASE kubenyx-addons up=2.65
KUBENYX-CLUSTER-READY uptime=3.40s
```

That marker means: node Ready, RBAC + addons applied, CoreDNS serving.
The serial console autologs you in as root (you may need to press
Enter to redraw the prompt) and `kubectl` works immediately:

```console
[root@kubenyx:~]# kubectl get nodes
NAME      STATUS   ROLES    AGE   VERSION
kubenyx   Ready    <none>   30s   v1.36.2
```

Exit the VM with `poweroff` in the guest shell, or from another
terminal (same directory — the control socket is relative):

```console
$ nix run .#microvm-firecracker-shutdown
```

(`-cloud-hypervisor-` and `-qemu-` twins exist for the other variants.)

For **host-side** kubectl, fetch a standalone kubeconfig from the guest
(credentials are minted per boot inside the guest, so this is the
credential path — and it never touches your `~/.kube/config`):

```console
$ curl -s 10.100.0.2:10124 > kubenyx.kubeconfig
$ kubectl --kubeconfig kubenyx.kubeconfig get nodes    # full TLS verification
NAME      STATUS   ROLES    AGE   VERSION
kubenyx   Ready    <none>   16s   v1.36.2
```

(or `export KUBECONFIG=$PWD/kubenyx.kubeconfig` for the shell session).
Re-fetch after every boot — each boot mints a fresh PKI. The endpoint
is restricted to the tap gateway, so in-cluster workloads can't reach
it; any local host process can, which on a disposable volatile test
cluster is the same trust as the tap itself.

Everything is volatile by design: tmpfs root over a read-only store
image, in-memory datastore, PKI regenerated in ~6 ms per boot. Kill the
VM, run it again, get a fresh honest cluster.

Variants (all share the tap/MAC/IP — **run one at a time**):

| Command | Needs | Notes |
|---|---|---|
| `nix run .#microvm-firecracker` | KVM | fastest; snapshot/restore capable |
| `nix run .#microvm-cloud-hypervisor` | KVM | ~equal boot speed |
| `nix run .#microvm-qemu` | nothing | SLiRP user networking, works under pure emulation |

## Quick start 2 — recreation in 28 ms

Cold boot is the slow path. Snapshot a ready cluster once, then recreate
it from memory whenever a test wants one (needs the tap from Quick
start 1, and KVM):

```console
$ mkdir work && cd work    # short path — API sockets live in CWD

# One-time: boot to cluster-ready, snapshot, tear down (~9s total)
$ nix run github:rytswd/kubenyx#kubenyx-snap -- take \
    --runner "$(nix build github:rytswd/kubenyx#microvm-firecracker --print-out-paths)/bin/microvm-run" \
    --out /dev/shm/kubenyx-snap

# From now on: a live cluster in ~28ms, as many times as you like
$ nix run github:rytswd/kubenyx#kubenyx-snap -- resume --snapshot /dev/shm/kubenyx-snap
spawn_to_sock_ms=2.1 load_ms=11.9 load_to_api_ms=14.1 total_ms=26.0 pid=12345 ...
cluster:    https://10.100.0.2:6443
kubeconfig: curl -s 10.100.0.2:10124 > kubenyx.kubeconfig && kubectl --kubeconfig kubenyx.kubeconfig get nodes
stop:       kill 12345

# Benchmark the loop yourself
$ nix run github:rytswd/kubenyx#kubenyx-snap -- cycle --snapshot /dev/shm/kubenyx-snap -n 5
cycles=5 median_total_ms=28.4 min=26.0 max=31.5
```

Already have a VM running (`nix run .#microvm-firecracker` in another
terminal)? Snapshot it in place — pause → snapshot → resume, the guest
never notices (~1.3 s, run from the VM's directory):

```console
$ nix run github:rytswd/kubenyx#kubenyx-snap -- take --sock kubenyx.sock --out /dev/shm/kubenyx-snap
```

**Whole meshes recreate too**: with a `microvm-cluster` (or the 7-node
`microvm-cluster7`) running, snapshot all nodes with a consistent cut
and recreate the entire cluster in ~45 ms — every node Ready,
cross-node connections intact:

```console
$ nix run .#kubenyx-snap -- mesh-take --run-dir /tmp/kubenyx-cluster --out /dev/shm/mesh-snap
$ nix run .#kubenyx-snap -- mesh-cycle --snapshot /dev/shm/mesh-snap -n 5
mesh_cycles=5 nodes=3 median_total_ms=45.0 min=34.2 max=53.2
```

(Recreation is ~flat in node count — the 7-node `microvm-cluster7`
recreates in the same tens-of-ms band; see `bench/RESULTS.md`.)

`resume` leaves the VM running and prints its pid; kill that pid to free
the tap. One restored clone at a time (the tap identity is baked into
the snapshot). Restored guests get their wall clock stepped
automatically (host sends UDP time pokes; the in-guest
`kubenyx-clockstep` daemon applies them) and reseed their CRNG via
vmgenid, so clones are safe to treat as fresh clusters.

Keep the snapshot on tmpfs (`/dev/shm`) as shown — restores demand-page
the 3.5 GB memory image, and tmpfs makes that free.

> Snapshots are VMM-version-locked; `kubenyx-snap` from the flake ships
> the matching firecracker on PATH. Details, gotchas and design:
> [`air/v0.2/snapshot-restore.org`](air/v0.2/snapshot-restore.org).

## Quick start 3 — Kubenyx in your own NixOS configuration

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

### Multi-node

Membership is declared in Nix — no runtime discovery. The server mints
per-node credentials; you ship an agent its directory (that's the whole
join protocol):

```nix
# Server
kubenyx = {
  enable = true;
  role = "server";
  datastore.backend = "etcd";   # kine/etcd-mem are single-node by assertion
  nodes = {
    server1 = { index = 0; address = "192.168.1.10"; };
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
modes). See
[`tests/multi-node.nix`](tests/multi-node.nix) for the working
end-to-end flow.

### Embedding a cluster in your own NixOS VM tests

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

## Tests and benchmarks

```console
# The matrix (KVM is picked up automatically; green in ~40-160s each)
$ nix build .#checks.x86_64-linux.single-node.driver -o d && d/bin/nixos-test-driver
# also: single-node-etcd, multi-node

# Head-to-head vs k3s in identical airgapped VMs
$ nix build .#checks.x86_64-linux.bench-vs-k3s.driver -o b && b/bin/nixos-test-driver

# Native control-plane timings on the build host (no VM)
$ nix run .#native-bench
```

Two harness gotchas worth knowing (found the hard way, recorded in
`bench/RESULTS.md`):

- **Concurrent test drivers collide**: the NixOS test driver keys vde
  sockets and `vm-state-*` dirs off `XDG_RUNTIME_DIR` with no per-run
  namespace. Running two drivers at once hangs the loser at
  "start all VLans". Give each run its own `XDG_RUNTIME_DIR`.
- **Absolute VM timings under TCG are meaningless** — only ratios in
  identical VMs count. On this project TCG turned out to be ~6.5×
  slower than KVM, not the 12–15× folklore.

## Repository layout

| Path | What |
|---|---|
| `modules/` | The NixOS module: control plane, datastore, PKI, node runtime, DNS, addons, network |
| `guests/`, `flake.nix` | MicroVM guest profile + firecracker/cloud-hypervisor/qemu variants |
| `rust/` | The boot-path tools: `kubenyx-pki`, `kubenyx-ready`, `etcd-mem`, `kubenyx-snap`, `kubenyx-clockstep` |
| `tests/` | NixOS VM test matrix + the k3s benchmark |
| `bench/RESULTS.md` | Every measurement, newest first, including the honest corrections |
| `air/` | Design docs (planning-first workflow): architecture, per-subsystem specs, session plans |
| `templates/` | `nix flake init -t` starting point |

Design decisions live in `air/` — start with
[`air/context/architecture.md`](air/context/architecture.md) and the
per-version `OVERVIEW.org` files. The short version of the philosophy:
stock Kubernetes, Nix as the source of truth, everything measured, and
when a dependency is the bottleneck, replace it with 300 lines of Rust.

## Command reference

### `nix run` apps

| App | What it does |
|---|---|
| `.#microvm-firecracker` / `-cloud-hypervisor` / `-qemu` | Single-node disposable cluster (~7.8 s to ready; qemu = KVM-less fallback) |
| `.#microvm-firecracker-shutdown` (+ `-cloud-hypervisor-`, `-qemu-` twins) | Graceful guest shutdown; run from the VM's directory |
| `.#microvm-cluster` / `.#microvm-cluster-shutdown` | 3-node mesh (server + 2 agents), bridge + taps via sudo, ~8.1 s to all-Ready / reverse teardown |
| `.#microvm-cluster7` / `.#microvm-cluster7-shutdown` | 7-node twin (server + 6 agents), run dir `/tmp/kubenyx-cluster7`, ~9 s |
| `.#native-bench` | Control-plane timings as bare processes, no VM |

### Packages beyond the app-backing ones

| Package | Contents |
|---|---|
| `.#kubenyx-snap` | Snapshot CLI with the version-matched firecracker on PATH |
| `.#kubenyx-tools` | Guest boot-path tools: `kubenyx-pki`, `kubenyx-ready`, `etcd-mem`, `kubenyx-clockstep`, `kubenyx-snap` |
| `.#kubenyx-lb` | Client-side apiserver LB (separate package by design — it must never ride into guest closures) |
| `.#microvm-cluster-{server,agent1,agent2}`, `.#microvm-cluster7-{server,agent1..6}` | Per-node mesh runners |
| `.#pause-image`, `.#test-image` | Airgap seed images |

### Checks

`nix build .#checks.x86_64-linux.<name>.driver -o d && d/bin/nixos-test-driver`
— give each **concurrent** run its own `XDG_RUNTIME_DIR` (the driver keys
vde sockets and vm-state off it with no per-run namespace).

| Check | Proves | Wall (KVM) |
|---|---|---|
| `single-node` / `single-node-etcd` | Happy path on kine / real etcd | 37 s / 153 s |
| `harness` | `lib.harness` dogfood: server+agent stood up exclusively through the exported helper | 39 s |
| `multi-node` / `multi-node-mem` | Server + agent on etcd / on etcd-mem | 38 s / 22 s |
| `multi-server` | 3-server etcd quorum + LB agent + CA custody | 50 s |
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

### `kubenyx-snap`

| Subcommand | Option | Default | Meaning |
|---|---|---|---|
| `take` (boot-fresh) | `--runner PATH` | *(selects this mode)* | microvm-run to spawn, snapshot, tear down |
| | `--out DIR` | `snapshot` | Where `snap.vmstate` + `snap.mem` land |
| | `--marker STR` | `KUBENYX-CLUSTER-READY` | Console marker to wait for |
| | `--wait-secs N` / `--settle-ms N` | 120 / 2000 | Marker timeout / post-ready settle |
| `take` (attach) | `--sock PATH` | `kubenyx.sock` | Snapshot a *running* VM: pause → create → resume in place |
| `resume` | `--snapshot DIR` | `snapshot` | Restore into a fresh VMM, leave it running |
| | `--firecracker BIN` | from PATH | Must match the snapshot's VMM version |
| | `--api-sock NAME` | `kubenyx-resume.sock` | Keep it relative (SUN_LEN) |
| | `--probe ADDR` / `--poke ADDR` | `10.100.0.2:6443` / `:10123` | API liveness probe / clock-poke target |
| | `--no-pci` | off | Only for snapshots taken without `--enable-pci` |
| `cycle` | resume's flags + `-n N` | 5 | Recreation benchmark: resume → verify → kill, ×N |
| `mesh-take` | `--run-dir DIR` | `/tmp/kubenyx-cluster` | Pause ALL nodes, snapshot in parallel, free the taps |
| | `--out DIR` | `mesh-snapshot` | Per-node subdirs + manifest |
| | `--node name=ip` (repeat) | auto-discovered | Only needed off-convention (`server`=.2, `agentN`=.2+N) |
| `mesh-resume` | `--snapshot DIR` | `mesh-snapshot` | Concurrent restore of every node from the manifest |
| `mesh-cycle` | mesh-resume's flags + `-n N` | 5 | Mesh recreation benchmark |

### The other CLIs

Mostly systemd-invoked; `kubenyx-pki mint-ca` is the operator-facing one.

| Tool | Key flags |
|---|---|
| `kubenyx-pki mint-ca` | `--out DIR` — offline CA custody bundle (6 files: both CAs + the SA keypair) for durable servers |
| `kubenyx-pki server\|agent` | `--pki-dir`, `--kubeconfig-dir`, `--node-name`, `--node-address`, `--service-ip`, `--cluster-domain`, `--etcd`, `--etcd-san`, `--extra-san`, `--leaf-days`, `--renew-days`, `--require-shipped-ca` |
| `kubenyx-lb` | `--listen`, `--backend addr` (repeat), `--probe-interval-ms`, `--fail-threshold`, `--dial-timeout-ms`, `--drain-timeout-ms`, `--probe-cert`/`--probe-key` (pair), `--probe-http` |
| `kubenyx-clockstep` | `--listen` (`0.0.0.0:10123`), `--allow-from IP`, `--min-step-ms` (500) |
| `kubenyx-ready` | `--url`, `--cacert`/`--cert`/`--key` or `--insecure`, then `-- <command>` to wrap |

## Firecracker snapshot fine print

Encoded in the flake so you normally never see them, but if you drive
firecracker yourself:

- On AMX hosts (Granite Rapids+) a restored guest kernel-panics in
  `XRSTORS` unless the snapshot was taken with
  `clearcpuid=amx_tile,amx_int8,amx_bf16 noxsaves` (already in the
  firecracker variant's kernel params).
- `--enable-pci` must match between snapshot and restore VMM.
- API socket paths must stay under 108 chars (`SUN_LEN`) — use relative
  paths from a short working directory.
- Firecracker's API server ignores `Connection: close`; read responses
  by `Content-Length` or every call stalls to your socket timeout.
