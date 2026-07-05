# Air Conventions

How Air documents are structured, tagged, and organized.

## Document States
Air uses six predefined states for document lifecycle management:

- **draft**: Initial planning phase - document is being written and refined
- **ready**: Specification complete, ready for implementation
- **work-in-progress**: Currently being implemented or actively worked on
- **complete**: Implementation finished and documented
- **dropped**: No longer needed or abandoned
- **unknown**: State cannot be determined from document metadata

## Document Structure
Recommended structure for Air documents:

### For Org-mode (.org files):
```
#+title: Document Title
#+state: draft|ready|work-in-progress|complete|dropped
#+FILETAGS: :tag1:tag2:tag3:

* Summary
Brief overview of what this document addresses.

* Motivation  
Why this work is needed and what problems it solves.

** Goals
What we want to achieve.

** Non-Goals
What is explicitly out of scope.

* Proposal
Detailed specification of the solution.

* Design Details
Technical implementation details.

* History
- YYYY-MM-DD: Description of work completed
```

### For Markdown (.md files):
```markdown
---
title: Document Title
state: draft|ready|work-in-progress|complete|dropped
tags: [tag1, tag2, tag3]
---

# Summary
Brief overview of what this document addresses.

# Motivation
Why this work is needed and what problems it solves.

## Goals
What we want to achieve.

## Non-Goals
What is explicitly out of scope.

# Proposal
Detailed specification of the solution.

# Design Details
Technical implementation details.

# History
- YYYY-MM-DD: Description of work completed
```

## Optional Sections
Consider adding these sections as needed:
- **Test Plan**: How to validate the implementation
- **Drawbacks**: Known downsides of this approach
- **Alternatives**: Other approaches considered
- **Infrastructure Needed**: External dependencies

## Tags

Tags should be broad categories. Avoid single-use niche tags — if a tag only applies to one document, it's too specific.

### Tag Hygiene
- Before creating a new tag, check existing tags with `airctl status --by-tag`
- Every document with a state must have tags
- When a tag applies to only one document, consider merging it into a broader category

### Tag Format
- **Org-mode**: `#+FILETAGS: :tag1:tag2:tag3:`
- **Markdown**: `tags: [tag1, tag2, tag3]` in front matter

## File Naming Patterns

- Use lowercase with hyphens: `air-config.org`, `status-command.org`
- Include component prefix when relevant: `airctl-show.org`, `airctl-update.org`
- Use descriptive names that match the document title
- Avoid abbreviations unless widely understood

## Directory Structure and Organization

### Main Directory Structure
```
./air/
├── v0.1/                # Milestone specifications
│   ├── feature-a.org
│   └── git-integration/ # Subdirectory for related docs
│       ├── git-dates.org
│       └── git-hooks.org
├── v0.2/                # Another milestone
├── archive/             # Completed or obsolete documents
├── templates/           # Document templates
└── context/             # Generated context files
```

### Feature Subdirectories
Group related documents in subdirectories within version directories. Each document should be independently implementable — if a spec covers multiple features, split it into separate docs before implementation.

### Version-Aware Organization
- Use semantic versioning for directory names: `v0.1`, `v0.2`, `v0.10`
- Directories sort correctly with version-aware comparison
- Move completed work to `archive/` when no longer actively referenced
- Use milestone-based organization rather than date-based

### Excluded Files
These files are not tracked as work items:
- `OVERVIEW.org` / `OVERVIEW.md` — directory-level documentation
- `README.org` / `README.md` — directory-level documentation
- `SKILL.md` — tool configuration

## File Type Preferences
Default supported formats from air-config.toml:
- **Primary**: `.org` files (Org-mode format)
- **Secondary**: `.md` files (Markdown format)
- Extensible system allows adding new formats

## Metadata Conventions

### State Updates
- Always update `#+state:` property when work status changes
- Add entry to History section with date and description
- Use ISO date format (YYYY-MM-DD) for consistency

### Git Integration
- Air is Git-aware but doesn't require Git
- Document dates can be extracted from Git history when available
- Filesystem timestamps used as fallback

### History Notes
When marking complete with known remaining items, note them explicitly in the final history entry:
```
- 2025-08-30: Marked complete. Remaining: section editing (future work)
```

Reference commits inline when needed: `(aabbcc)` or `(aabbcc..ddeeff)`.

### Design Divergence
Implementation often diverges from the original spec — this is expected. When it happens, add a "Design Divergence" subsection under History documenting what actually shipped vs what was planned. Don't rewrite the original spec — the contrast is valuable for learning.

## Archive Management
- Move documents to `archive/` when implementation is complete and stable
- Keep documents in main directories while still being referenced
- Archive inclusion controlled by `include-archive` config option
- Archived documents excluded from status counts by default