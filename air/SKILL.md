---
name: air
description: Filesystem-based planning with Air. Use when working with Air documents, managing project specifications, tracking implementation progress, or when the user mentions Air, airctl, air-config.toml, or planning-first workflows.
compatibility: Requires the `airctl` CLI on PATH and an `air-config.toml` (project or user-level).
---

# Air — Planning-First, Filesystem-Native

Air is a planning tool whose database is the filesystem. Specifications live as
`.org` or `.md` files under `./air/`, organised by milestone (`v0.1/`, `v0.2/`,
…). `airctl` is the CLI; any text editor and any tool that reads files also
"just works" against an Air repo.

## Core Principles

1. **Filesystem as database** — no service, no schema; just files and directories.
2. **Planning-first** — write/refresh the Air doc *before* implementing.
3. **State-based tracking** — every doc declares a state; status is computed from metadata.
4. **Git-aware, not Git-bound** — works without Git, uses Git history when present.

## Document Lifecycle

```
draft ──► ready ──► work-in-progress ──► complete ──► archive/
  │         │              │                 
  └─────────┴──────────────┴────────────► dropped
```

| State              | Meaning                                                     |
|--------------------|-------------------------------------------------------------|
| `draft`            | Being written; requirements still being gathered.           |
| `ready`            | Spec complete and approved; OK to start implementing.       |
| `work-in-progress` | Actively being implemented. Set this *before* touching code.|
| `complete`         | Implementation finished and verified.                       |
| `dropped`          | Abandoned / deprioritised.                                  |
| `unknown`          | State header missing or unparseable — fix the metadata.     |

`archive/` is a *directory*, not a state — move completed docs there to
declutter, and use `--include-archive` to see them.

## Setup

```bash
# One-shot interactive bootstrap (config + templates + directories)
airctl init

# Granular alternatives
airctl config create                 # interactive wizard
airctl config create-for-project     # documented air-config.toml in CWD
airctl config create-for-user        # documented air-config.toml in XDG dir
airctl config show                   # current effective config + sources
airctl config validate
airctl config path

airctl directory init                # create ./air/, v0.1/, archive/, ...
airctl template init                 # pick which built-in templates are enabled
```

Project config (`./air-config.toml`) overrides user config (XDG) which overrides
defaults.

## Directory Layout

```
./air/
├── v0.1/                # current milestone
├── v0.2/                # next milestone (planning)
├── v0.1/git-integration/   # feature subdirectory grouping related docs
├── archive/             # completed work, hidden from status by default
├── templates/           # on-disk templates (override built-ins by name)
└── context/             # generated context files for AI tools
```

Use semver-ish names (`v0.1`, `v0.2`, `v0.10`) — Air sorts them version-aware.
Place `OVERVIEW.org`/`OVERVIEW.md` or `README.*` in directories to describe
contents; these are excluded from status counts.

## Document Formats

Both formats carry the same metadata: `title`, `state`, `tags`. Pick one per
project; templates default to one or the other.

### Org-mode

```org
#+title: Feature Name
#+state: draft
#+FILETAGS: :airctl:template:

* Summary
Brief overview of what this addresses.

* Motivation
Why this is needed.

** Goals
** Non-Goals

* Proposal
Detailed specification.

* Design Details
Technical implementation notes.

* History
- 2026-04-27: Initial draft.
```

### Markdown (YAML frontmatter)

```markdown
---
title: Feature Name
state: draft
tags: [airctl, template]
---

# Summary
…
# Motivation
…
## Goals
## Non-Goals
# Proposal
…
# Design Details
…
# History
- 2026-04-27: Initial draft.
```

Tag taxonomy is intentionally narrow. Before inventing a tag, run
`airctl status --by-tag` and reuse an existing one. Common tags in this repo:
`airctl`, `air_core`, `ai`, `config`, `context`, `template`, `ui`.

## Authoring New Docs

```bash
# Interactive: prompts for filename, title, template, directory, tags
airctl new

# Fully specified (skip prompts)
airctl new feature-name \
    --title "Feature Name" \
    --template air-standard \
    --directory v0.1 \
    --tags airctl,template

# Force directory creation without prompts
airctl new feature-name -d v0.2/new-area --force
```

The default template is read from `air-config.toml`. List options with
`airctl template list` (built-in: `air-minimal`, `air-standard`, `kep-based`,
`pep-based`).

New docs start in `draft`. Move to `ready` only after the spec is complete and
stakeholders have approved.

## Tracking Work

`airctl status` is the daily driver.

```bash
airctl status                              # default: group by state
airctl status -S                           # group by state (explicit)
airctl status -D                           # group by directory (progress per dir)
airctl status -T                           # group by tag

airctl status --state ready,work-in-progress
airctl status --exclude-state dropped,unknown
airctl status --since 7d                   # YYYY-MM-DD, 7d/4w/3m, or git ref
airctl status --since HEAD~10
airctl status --directory v0.1/            # scan a sub-tree
airctl status --no-recurse                 # only that directory's level
airctl status --include-draft              # show draft files (not just count)
airctl status --include-archive            # show archived docs
airctl status -a                           # show full listings for every state

airctl status --show-date --show-tag --show-title
airctl status --no-files                   # summary only

airctl status --json                       # machine-readable
```

### Inspecting one document

```bash
airctl show v0.1/feature-name.org           # via $PAGER if set
airctl show v0.1/feature-name.org --raw     # straight to stdout
airctl show v0.1/feature-name.org --json    # metadata + content as JSON
airctl edit v0.1/feature-name.org           # open in $EDITOR
```

## Updating Metadata

```bash
airctl update v0.1/feature.org --state work-in-progress
airctl update v0.1/feature.org --state complete
airctl update v0.1/feature.org --title "Better Title"

airctl update v0.1/feature.org --tags airctl,template      # replace all
airctl update v0.1/feature.org --add-tag reviewed          # additive (csv ok)
airctl update v0.1/feature.org --remove-tag reviewed

airctl update v0.1/a.org v0.1/b.org --add-tag milestone-x  # batch
airctl update v0.1/feature.org --state complete --dry-run  # preview
airctl update v0.1/feature.org --state complete --force    # no prompts
```

To relocate a document (e.g. into `archive/` or another version dir):

```bash
airctl move v0.1/feature.org archive/
airctl move v0.1/feature.org v0.2/                  # bump milestone
airctl move v0.1/a.org v0.1/b.org v0.2/             # batch; last arg is dest
airctl move v0.1/feature.org archive/ --state complete
```

## Templates

```bash
airctl template list                         # what's available (built-in + disk)
airctl template list -v                      # show section structure

airctl template init                         # toggle which built-ins are enabled
airctl template enable kep-based
airctl template disable pep-based

airctl template generate my-template                  # blank, TOML
airctl template generate my-template --from air-standard   # fork a built-in
airctl template generate my-template --yaml           # YAML format
airctl template generate --default                    # copy ALL built-ins to disk
airctl template generate my-template --force          # overwrite

airctl template remove my-template           # delete a generated template
```

Generated templates live in the configured template directory and shadow
built-ins of the same name.

## Context Generation (for AI tooling)

`airctl context generate` writes the project's living context (overview,
conventions, current status) to disk for AI assistants to load.

```bash
airctl context list                         # show known context files + status
airctl context generate                     # interactive selection
airctl context generate --all               # everything, no prompts
airctl context generate --claude            # also write CLAUDE.md
airctl context generate --codex             # also write CODEX.md
airctl context generate --gemini            # also write GEMINI.md
airctl context generate --agents            # also write AGENTS.md
airctl context generate --with-tools        # include tool-integration files in selection
airctl context generate --force             # overwrite without confirmation
```

Regenerate after meaningful spec or convention changes.

## Best Practices

### Planning
- Create the Air doc *first*; don't implement against an unwritten spec.
- Keep docs small and self-contained — see *Granularity* below.
- Promote `draft → ready` only when sections are filled in and dependencies known.
- If reality diverges from the spec mid-flight, **stop and re-plan** in the doc.

#### Granularity: small + self-contained

Each Air doc should describe *one* feature that could ship on its own.
Split a draft before promoting to `ready` if either holds:

- it has more than one *Acceptance Criteria* block that could ship independently, or
- it proposes two designs that don't share state.

**Why.** Smaller docs review faster, can be implemented in parallel by
separate workers, and let partial progress be marked `complete` instead
of leaving a half-shipped umbrella doc stalled at `work-in-progress`.

**Cluster pattern.** When several small docs share motivation, group
them in a subdirectory with an `OVERVIEW` file (`.org` or `.md` per
project) that links them:

```
v0.1/feature-cluster/
  OVERVIEW.org      # shared motivation + table of sub-docs; no AC of its own
  feature-a.org     # independently implementable
  feature-b.org     # independently implementable
```

`OVERVIEW` is a navigation aid, not a spec — it carries no Acceptance
Criteria and is excluded from `airctl status` counts.

**Splitting an existing draft.** Add a History entry to the original
noting the split and which docs replace it. If everything has moved out,
mark the original `dropped`.

### Implementing
- Set state to `work-in-progress` *before* touching code.
- Add a `Design Divergence` subsection under `History` when the build deviates
  from the spec — don't rewrite the original proposal to match.
- Never mark `complete` with failing tests. Verify by running the tool, not
  just by passing tests.

### History
After completing meaningful work, append a dated bullet to `* History`:

```
* History
- 2026-04-25: Initial draft.
- 2026-04-26: Moved to ready after review.
- 2026-04-27: Implementation complete. Remaining: edge-case X (future work).
```

Reference commits inline with `(aabbcc)` or ranges `(aabbcc..ddeeff)`.

### Git Integration
- Air docs live alongside code; commit them together.
- Add an `Air-Doc:` trailer to commits that advance a doc:
  ```
  Implement template generate --default

  Air-Doc: v0.1/air-template/template-generate.org
  ```
  `Related Air:` is also accepted. Multiple trailers per commit are fine.
- `airctl git` surfaces commits linked (explicitly via trailer or implicitly
  via touched doc files) to a given Air document.
- `airctl time-machine` lets you view docs at a past commit.

## Troubleshooting

**`unknown` state in status**
- Missing/typo'd state header. Org: `#+state: ready`. Markdown: `state: ready`
  in YAML frontmatter. Allowed values: `draft`, `ready`, `work-in-progress`,
  `complete`, `dropped`.

**Doc doesn't show up in `airctl status`**
- File extension not in configured `file-types` (default: `.org`, `.md`).
- File lives outside the configured `main-directory`.
- File is under `archive/` — pass `--include-archive`.
- File is `OVERVIEW.*` / `README.*` / `SKILL.md` — these are intentionally excluded.

**Config surprises**
- `airctl config show` prints effective values *and* their source.
- `airctl config path` shows which files are being read.
- Project config beats user config beats defaults.

**Tags exploding**
- Run `airctl status --by-tag`. If a tag has one document, fold it into a
  broader category instead of inventing more.

## Hand-Holding Mode

When the user *explicitly* wants an interactive, one-question-at-a-time
interview to draft a new Air doc (e.g. "walk me through this", "interview me",
"hand-hold me"), switch to the companion skill: **`skills/air-hand-hold/SKILL.md`**.
That mode is opt-in only; the default for `airctl new` and doc authoring lives
in this skill.
