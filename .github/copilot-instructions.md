# Copilot Instructions — PwrCortex

## Conventional Commits (required)

This repository uses **release-please** to auto-generate changelogs and version bumps.
All PR titles and commit messages **must** follow
[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <short description>
```

### Allowed types

| Type | Use for | Version bump |
|---|---|---|
| `feat` | New feature / cmdlet / parameter | minor |
| `fix` | Bug fix | patch |
| `docs` | Documentation only | none |
| `chore` | CI, deps, tooling, formatting | none |
| `refactor` | Code restructuring, no behavior change | none |
| `test` | Adding or updating tests | none |
| `ci` | GitHub Actions workflow changes | none |
| `perf` | Performance improvement | patch |

Append `!` after the type for **breaking changes**: `feat!: rename Invoke-LLM`.

### Rules

- Imperative mood: "add", "fix", "remove" — not "added", "fixes", "removed".
- First line ≤ 72 characters.
- No generic messages ("update files", "misc changes").
- One logical change per PR.

### Examples

```
feat: add -Timeout parameter to Invoke-LLMAgent
fix: restore box-drawing glyphs lost to double-encoding
docs: expand README with swarm orchestration details
chore: add release-please and PSGallery publish workflows
```

## Repository overview

- **`PwrCortex.psm1`** — Module script (all cmdlet implementations).
- **`PwrCortex.psd1`** — Module manifest (PS 7.0+). The `ModuleVersion` line has an
  `x-release-please-version` annotation — release-please updates it automatically.
- **`CLAUDE.md`** — Module directive file for LLM agents (discovered by
  `Get-LLMModuleDirectives`). Contains cmdlet reference, conventions, and pipeline
  patterns.
- **`README.md`** — User-facing documentation.

## Coding conventions

- PowerShell 7.0+ only.
- Wrap function calls used as .NET method arguments in parentheses:
  `[Math]::Min((script:Get-Width), 100)`.
- All files must be UTF-8 (no BOM).
- Keep exported functions listed in `PwrCortex.psd1` `FunctionsToExport`.
