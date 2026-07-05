# Interface Design — Kubenyx Option Surface

Kubenyx's "interface" is its NixOS option tree. Rules:

## Shape

- Everything lives under `kubenyx.*`. Target: under 40 user-facing
  options. The long tail goes through per-component escape hatches
  (`extraFlags` lists, `settings` attrsets), never new dedicated options.
- `kubenyx.enable = true` + defaults must be a complete single-node
  cluster. Options exist to *change* something, not to be required.
- `profile` moves defaults only; no behavior is reachable exclusively
  through a profile.
- `role` ("server"/"agent") selects which module groups activate; it
  force-enables nothing else (the nixpkgs `roles` coupling is the
  anti-pattern).
- Internal wiring is `kubenyx.internal.*` (read-only, `internal = true`);
  modules may read each other's internal options, never their
  implementation.

## Option Conventions

- CIDR/IP options are strings validated at eval time via `lib/`
  assertions; derived addresses (apiserver ClusterIP, DNS IP, node pod
  CIDRs) are computed, exposed read-only, never asked of the user twice.
- Every performance default documents the stock upstream value and links
  the research file justifying the deviation.
- Package options: one per external binary (`kubenyx.packages.*`), so a
  locally-built component can be swapped in for development.
- Dangerous options (`datastore.volatile`, `etcd.unsafeNoFsync`) carry a
  warning in the description and never default to on outside explicit
  user opt-in.

## Documentation

- All options have `description`; `nixosOptionsDoc` rendering is part of
  flake checks.
- The flake `templates.default` is the canonical "getting started"
  artifact — it must always compile against the current option surface.
