# monorepo-full: POC for A.7 aggressive mode

This fixture is a **monorepo with three heterogeneous sub-projects**.
Its purpose is to exhibit the v0.6 planner's limitation when applied to
a real monorepo, and to serve as the briklab smoke target for the
`aggressive` mode work (A.7 of the architecture refactor).

It satisfies condition #2 of
[`monorepo-plan.md` §5](../../../docs/chantiers/20260518_refonte/analysis/monorepo-plan.md):

> POC monorepo briklab: briklab ajoute un test-project monorepo
> synthétique qui démontre la limitation actuelle (full pipeline
> déclenché sur changement d'un seul sous-projet).

## Structure

```
monorepo-full/
├── brik.yml                # Root (single-project mode in v0.6)
├── .gitlab-ci.yml          # Single dynamic pipeline include
├── Jenkinsfile             # Single Jenkins pipeline
└── apps/
    ├── web/                # node sub-project
    │   ├── brik.yml
    │   ├── package.json
    │   ├── src/index.js
    │   └── test/web.test.js
    ├── api/                # python sub-project
    │   ├── brik.yml
    │   ├── pyproject.toml
    │   ├── src/api/__init__.py
    │   └── tests/test_api.py
    └── jobs/               # java sub-project
        ├── brik.yml
        ├── pom.xml
        └── src/main/java/com/example/jobs/Main.java
```

Each sub-project ships its own `brik.yml`. In v0.6, the planner only
reads the **root** `brik.yml` (cf. monorepo-plan §4 "Single-project
resolution"); the three sub-project manifests are ignored and serve as
the contract `aggressive` mode would consume.

## The v0.6 limitation, exhibited

The root pipeline runs the standard fixed flow with `pipeline.selection.
mode=balanced` against the root workspace. Consequences:

| Commit scope | What v0.6 does | What `aggressive` would do |
|---|---|---|
| Edit `apps/web/src/index.js` only | Runs init/build/lint/test for the **node root stack** (apps/api and apps/jobs untouched but workspace-level impact filter passes them through) | Plans only `apps/web` -- skips `apps/api` and `apps/jobs` entirely |
| Edit `apps/jobs/src/main/java/...` only | Same: runs the root pipeline (root stack=node, so the java change does not even rebuild the JVM bits) | Plans only `apps/jobs` -- the JVM build runs in isolation |
| Edit `apps/api/pyproject.toml` only | Same | Plans only `apps/api` |
| Edit a shared file at root | Plans every sub-project | Plans every sub-project (no change vs v0.6 on cross-cutting edits) |

The asymmetry of the first three rows is the limitation: the **root
stack** is whatever the root `brik.yml` declares, and every other
sub-project's stack is effectively dead code in v0.6. A `python` change
gets routed through a `node` runner image; a `java` change does too.

## What this POC is NOT

- It does **not** implement `aggressive` mode. The planner still errors
  out on `--mode aggressive` (cf. `lib/planning/plan.sh`).
- It does **not** include a working build for the three stacks in the
  root pipeline. The root pipeline only exercises the root stack; the
  sub-project source files are present so the planner has realistic
  changed-file paths to filter against.
- It is **not** registered in the standard briklab E2E suite. The
  suite assumes mono-project test targets; opting this fixture in
  requires the aggressive-mode adapter work.

## Reopening the aggressive-mode chantier

This POC contributes **one** of the four conditions in
[`monorepo-plan.md` §5](../../../docs/chantiers/20260518_refonte/analysis/monorepo-plan.md).
A new chantier `docs/chantiers/YYYYMMDD_monorepo-aggressive.md` opens
when a second condition is also met (e.g. an external user documents
their monorepo need, or `chantier #2 service-contracts` decides the
multi-project semantics).

## Running the v0.6 baseline

```bash
# Local (from the briklab root):
brik run pipeline --workspace test-projects/monorepo-full --auto-select

# Inspect what the planner sees:
brik plan --workspace test-projects/monorepo-full --explain
```

The `--explain` output shows the root stack only -- the three
sub-project `brik.yml` files are inert in v0.6.
