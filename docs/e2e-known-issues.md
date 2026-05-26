# E2E Known Issues (GitLab + Jenkins + Local)

This document tracks E2E test infrastructure issues surfaced during ongoing
validation on briklab. None of these are Brik core code bugs - they are
test fixtures, briklab infrastructure, or runner-image gaps. They are
recorded here so future fixes can address them without re-investigation.

Last validated: **2026-04-22** (R3.1 run, timestamp `20260422T224208`).
Prior baselines: `20260422T172517` (R2), `20260422T140016` (initial),
`2026-04-20` (Phase 3 reference).

## Run Snapshot - 2026-04-22

Three batches were executed sequentially today. Local first, then GitLab
(`--all --parallel-groups`), then Jenkins (`--all --parallel-groups`).
Briklab Jenkins was recreated between batches to apply CasC + mount
changes.

| Platform | Total | Passed | Failed | Run timestamp                                  |
|----------|------:|-------:|-------:|------------------------------------------------|
| Local    |     3 |      3 | 0      | `local-20260422T224208.log`                    |
| GitLab   |    28 |     19 | 2 + 7 cascade | `gitlab-20260422T224208.log`            |
| Jenkins  |    28 |     16 | 5 + 7 cascade | `jenkins-20260422T224208.log`           |

Detailed batch summaries:
- `e2e-results/summary-20260422T140016.md` (initial baseline before fixes)
- `e2e-results/summary-20260422T172517.md` (R3 - first verification round)

### Local (3/3 PASS)

`brik run stage init / build / test` against `examples/minimal-node/`.
Restored `package.json`, `src/index.js`, `test/index.test.js` plus
`test.framework: npm` in `brik.yml` (commit `e037886` in brik). All
three stages pass.

### GitLab batch (19/28 PASS, 2 real fail + 7 cascade-skip)

Real failures:
- `node-deploy-gitops` - ArgoCD unreachable (infra).
- `java-complete` - intermittent `brik-package: skipped` (flake; passed in
  R3, fails in R3.1). See java-complete entry below.

Notable wins:
- `node-deploy` PASS (port-3000 collision with `brik-gitea` resolved by
  bumping host port to 13000 in compose fixture).
- `node-deploy-helm` PASS (was missing `.gitlab-ci.yml`; added).
- `node-deploy-dryrun` PASS.
- `rust-complete` PASS (cargo crate cleanup runs before scenario).
- `workflow-trunk-main` PASS (`wait_pipeline_by_sha` stdout fix - prior
  failure was a stdout-capture bug, the pipeline itself succeeded).

Cascade-skipped: `node-deploy-rollback`, `workflow-trunk-{tag,feature}`,
`error-{build,test,config,deploy}` (depend on the failing scenarios).

### Jenkins batch (16/28 PASS, 5 real fail + 7 cascade-skip)

Real failures:
- `node-deploy-gitops` - same ArgoCD infra issue as GitLab.
- `workflow-trunk-main` - seed job now exists, but no Gitea webhook /
  no SCM-polling trigger means git push lands but no build is triggered.
- `rust-complete` - cargo auth resolved; new failure mode: dirty working
  tree.
- `java-minimal` and `java-complete` - osv-scanner deps scan failed
  (CVE-database flake; both passed earlier in the day).

Notable wins (compared to R2 baseline):
- `node-deploy` PASS (port bump).
- `node-deploy-dryrun` PASS (`BRIK_DRY_RUN` declared as `booleanParam`).
- `node-deploy-ssh` PASS (deploy container runs `-u 0:0`, SSH key
  mounted, `SSH_PRIVATE_KEY` propagated through the env-grep).
- `node-deploy-helm` PASS (CasC seed job added).

Cascade-skipped: same set as GitLab.

## Status Overview - Remaining Issues (2026-05-12)

Validation pass post master pipeline-behavior-model chantier
(`docs/chantiers/20260511_pipeline-behavior-model.md` SC1-21,
landed on `feat/business-sh-module`). E2E re-runs `gitlab --all` and
`jenkins --all` against the SC1-21 code revealed 13-21 failures per
platform; the structural causes are catalogued below.

### Run baseline

| Run                                       | Platform | PASS | FAIL | cascade-SKIP | Note                                                          |
|-------------------------------------------|----------|-----:|-----:|-------------:|----------------------------------------------------------------|
| `gitlab-all-2026-05-12T20`                | GitLab   |    8 |   13 |            7 | Baseline -- no DSI policy loaded, no eslint on deploy projects |
| `jenkins-all-2026-05-12T22`               | Jenkins  |    7 |   21 |            7 | Same baseline; bundled Verify amplifies failures               |
| `gitlab-all-2026-05-12T23` (with policy)  | GitLab   |   12 |    9 |            7 | After `brik-policy.yml` path-allowlist landed                  |

The diff between run 1 (8 PASS) and run 2 (12 PASS) on GitLab is purely
DSI-policy-driven: `node-full`, `java-full`, `node-complete`,
`java-complete` all moved PASS once the `brik-policy.yml` path
allowlist suppressed environmental CVEs in the runner base images.

### Open issue OI-1: Bug G structural fix missing in `lib/stages/verify/lint.sh`

**Where**: `brik/lib/stages/verify/lint.sh:54-63`.

**Symptom**: when the project's `package.json` doesnt declare `eslint`
as a devDep, the lint stage hard-fails with rc=10 and the error
`eslint binary not found in node_modules or PATH`. The failure
propagates as a GitLab job failure (`brik-lint: failed`) which
cascades into `brik-package: skipped`, `brik-container-scan: skipped`,
`brik-deploy: skipped`, `brik-notify: failed`.

**Chantier-promised resolution** (master `20260511_pipeline-behavior-model.md`
Bug G entry, line 953): *"Résolu en cascade : `tool_resolver` (SC15)
détecte `provenance=missing`, `_stage._finalize_fragment` (SC16)
produit `tech.kind=missing-tool` + `fix_classification=has_fix`,
matrice business émet `business.status=warning` en snapshot, `error`
en release."*

**Current state**: SC15 ships `lib/transverse/tool_resolver.sh` and SC16
extends `business.evaluate`, but neither sub-chantier wires
`tool_resolver.resolve` *into* `lib/stages/verify/lint.sh`. The lint
stage still uses the legacy `[[ -x ... ]] || command -v ... || error`
chain at lines 54-63 (and similar at lines 93-220 for the other
linters / formatters). Result: the "missing-tool surfaces as a SARIF
finding" cascade does not actually run for lint/format/test stages
today.

**Workaround applied 2026-05-12**: each affected briklab test-project
(7: `node-security`, `node-deploy`, `node-deploy-k8s`, `node-deploy-ssh`,
`node-deploy-helm`, `node-deploy-gitops`, `node-deploy-gitops-rollback`,
plus `node-workflow-trunk`) now declares `eslint@^10.1.0` as a devDep
and ships a flat `eslint.config.js` mirroring `node-full`. This unblocks
the test-project pipelines but leaves the structural gap in brik open.

**Resolution owed**: open a new chantier (call it SC22 in the master
postmortem) to wire `tool_resolver` into `lib/stages/verify/lint.sh`,
`format.sh`, and `test.sh`. When `provenance=missing`, the stage
should:
1. emit a SARIF result with `ruleId=brik-missing-tool`, `level=error`,
   `properties.tool=<name>`, `properties.brikFixClassification=has_fix`;
2. annotate `tech.kind=missing-tool` on the stage fragment;
3. return rc=0 so `business.evaluate` (not the stage code) decides
   snapshot/release.

This closes Bug G structurally and makes the eslint-devDep workaround
no longer required.

### Open issue OI-2: Jenkins bundled Verify stage amplifies sast failures

**Where**: `brik/shared-libs/jenkins/vars/brikPipeline.groovy`.

**Symptom**: on Jenkins, the four verify checks (lint, sast, scan,
test) run inside a single `Verify` Pipeline stage. Any one of them
failing (e.g. a semgrep finding in `python-minimal/src/`) marks the
whole Verify stage `FAILURE`, which bubbles up as the Pipeline result
even though the offending tool is not in the harness `required_jobs`.

On GitLab the same project passes: `brik-sast` is a separate job and
`python-minimal` doesnt list it in `required_jobs`, so its failure
is tolerated at the harness level.

**Current state**: `python-minimal` PASS on GitLab, FAIL on Jenkins.
Same brik code, same test-project, different platform wrapper.

**Resolution**: two options, neither yet decided.

(A) Mirror GitLab's per-tool job split in
    `shared-libs/jenkins/vars/brikPipeline.groovy`: emit four parallel
    Pipeline stages instead of one bundled `Verify`. This aligns the
    semantic across platforms.

(B) Update the Jenkins harness in
    `scripts/lib/e2e/jenkins-suite.sh` to read per-tool exit codes
    from the stage report and apply the same `required_jobs` filter
    as the GitLab harness. Avoids touching the brik shared lib.

(B) is the lighter touch and stays in briklab; (A) makes the platform
behaviour symmetric and is the longer-term direction.

### Open issue OI-3: Cascade-skip chain in the harness suite

**Where**: `scripts/lib/e2e/gitlab-suite.sh:51-` and
`scripts/lib/e2e/jenkins-suite.sh:51-`.

**Symptom**: 7 scenarios (`node-deploy-rollback`,
`workflow-trunk-tag`, `workflow-trunk-feature`, `error-build`,
`error-test`, `error-config`, `error-deploy`) cascade-SKIP when their
upstream dependency scenario fails. The cascade is correct (running
`error-build` makes no sense if `node-error-build` never even
triggered), but the suite tally counts these as "failures" rather
than skipped/blocked.

**Resolution**: distinguish `cascade-skip` in the summary table
(orange / yellow status) versus real `FAIL` (red) so the operator can
see at-a-glance which failures are root-causes vs derived. Cosmetic;
not blocking the chantier closure.

### Open issue OI-4: `brik-policy.yml` `expires` rotation owed

**Where**: `policy/brik-policy.yml`.

**Symptom**: the four path-allowlist entries added 2026-05-12 all
carry `expires: 2026-08-09` (90 days, the chantier-recommended
default for environmental CVEs in base images). When the date arrives,
the entries will be silently ignored at runtime and the suppressed
CVEs will re-enter the failing set unless either (a) the runner
images have been rebuilt with patched bases, or (b) the entries are
refreshed with new `expires` dates.

**Resolution**: the chantier-prescribed cadence applies here.
- **Quarterly** (next: 2026-08-09): walk `policy/brik-policy.yml`,
  check whether each entry is still load-bearing.
- **Before each runner-image rebuild in `brik-images/`**: drop the
  entries whose bases have been bumped.

The brik runtime's init stage automatically lists "expiring soon"
entries when within `BRIK_FINDINGS_EXPIRING_SOON_DAYS` (default 30)
of the date, surfaced in the aggregate-report. No CI work needed;
just keep nightly aggregate-reports under review.

### Open issue OI-5: `BRIK_POLICY_URL` not set in GitLab CI variables

**Where**: `data/gitlab-runner/config.toml` `[[runners]] environment`
field (now fixed: previously absent).

**Symptom**: on run 1 of the 2026-05-12 batch, no DSI policy was
loaded by any GitLab pipeline; the init stage silently skipped the
`org_policy.load` call because `BRIK_POLICY_URL` was not in the job
environment. The volume mount existed but the env var did not.

**Resolution applied 2026-05-12**:
- Added `environment = ["BRIK_POLICY_URL=file:///etc/brik/policy/brik-policy.yml"]`
  to `[[runners]]` (not `[runners.docker]` -- TOML scope matters).
- Added `/Users/jeanjerome/Projets/Getbrik/briklab/policy:/etc/brik/policy:ro`
  to the runner's `volumes` list so the file is reachable inside
  spawned job containers.
- `docker restart brik-runner` to reload the config.

Jenkins is unchanged: the file mount and `BRIK_POLICY_URL` were
already wired via `config/jenkins/casc.yaml:51-52` and continue to
work after the brik-side SC1-21 changes.

**Verification**: `node-full` on `v0.1.0` tag PASSes after the fix,
with `findings.sarif` entries tagged
`brikSource=policy.org.path-allowlist` (vs `policy.built-in.below-severity`
before).

### Verified-resolved on 2026-05-12 (pending full --all re-run)

These were observed failing on the 2026-05-12 baseline run and have
fixes landed but not yet validated by a complete `--all` re-run:

| Scenario              | Root cause                                | Fix applied                                                          |
|-----------------------|-------------------------------------------|----------------------------------------------------------------------|
| `node-full`           | npm bundled deps + Alpine apk env CVEs    | `brik-policy.yml` path-allowlist (verified PASS)                     |
| `python-full`         | CPython interpreter CVE env               | `brik-policy.yml` path-allowlist (pending re-run)                    |
| `java-full`           | OpenJDK runtime CVEs + Alpine apk env     | `brik-policy.yml` path-allowlist (verified PASS via solo run)        |
| `node-complete`       | npm bundled deps + Alpine apk env CVEs    | `brik-policy.yml` path-allowlist (verified PASS)                     |
| `java-complete`       | OpenJDK runtime CVEs + Alpine apk env     | `brik-policy.yml` path-allowlist + openjdk glob (verified PASS)      |
| `node-security`       | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `node-deploy`         | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `node-deploy-dryrun`  | Bug G (eslint not installed)              | devDep on `node-deploy/` (shared dir; pending re-run)                |
| `node-deploy-k8s`     | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `node-deploy-ssh`     | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `node-deploy-helm`    | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `node-deploy-gitops`  | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |
| `workflow-trunk-main` | Bug G (eslint not installed)              | devDep + `eslint.config.js` (pending re-run)                         |

The next `briklab.sh test --gitlab --all` should report 21+/28 PASS
(13 here + the previously-passing minimals/completes/full). The
remaining failures will all fall into OI-1, OI-2 or OI-3 above and
need targeted attention as described.

## Recently Fixed (2026-05-25)

### Local git `tag.gpgsign` trap (E-18 of 20260525 campaign)

**Symptom**: `node-deploy-rollback` aborted silently mid-execution
after `[INFO]  Pushing v0.2.0 to GitLab...`, with no verdict emitted
and the suite jumping to the next scenario. Reproduced on both
`gitlab-rollback.sh` and `jenkins-rollback.sh`.

**Root cause**: with `tag.gpgsign=true` (or
`tag.forceSignAnnotated=true`) in the operator's global
`~/.gitconfig`, a bare `git tag X` is upgraded to an annotated signed
tag -- which requires a message. Without `-m`, git exits 128 with
`fatal: pas de message pour l'étiquette ?` (or its English
equivalent). The rollback scripts run under `set -euo pipefail`, so
the subshell containing the `git tag` exits non-zero, the `set -e`
parent terminates the entire script without surfacing the error, and
no log lines appear between "Pushing v0.2.0..." and the next
scenario.

**Why the harness operator triggers this**: a Brik maintainer who
signs every tag in their day-to-day repos sets `tag.gpgsign=true`
globally. The lab scripts shared the same shell environment.

**Fix**: every `git tag` call in the lab harness now passes
`-c tag.gpgsign=false -c tag.forceSignAnnotated=false` explicitly, so
the harness produces lightweight unsigned tags regardless of the
operator's global config. Five sites updated:

- `briklab/scripts/lib/e2e/lib/git.sh:e2e.git.tag` (public helper, defence in depth)
- `briklab/scripts/lib/e2e/gitlab-rollback.sh` (v0.1.0 + v0.2.0 in `_rollback_push_v020`)
- `briklab/scripts/lib/e2e/jenkins-rollback.sh` (v0.1.0 + v0.2.0 in `_rollback_push_v020`)

The pre-existing fix at `lib/git.sh:66` (`e2e.git.push.with_init`)
documented the trap with a comment but did not propagate the pattern
to the other call sites; this campaign closed the gap.

**Operator note**: the lab is now self-defending. No change required
on contributor machines. If a future helper introduces another
`git tag` site, prefer `e2e.git.tag` (defence in depth) over a raw
`git tag` to inherit the override automatically.

---

## Recently Fixed (2026-05-21)

- **GitLab adapter: dynamic child pipeline -> classic plan-aware pipeline**
  -- The GitLab adapter no longer ships `dynamic-pipeline.yml`. It is now a
  single classic pipeline: a `brik-plan` job computes `plan.json`, and every
  stage job consults it via `brik plan gate <stage>` (sourced from
  `/tmp/brik-plan-gate.sh`), exiting 0 with a not-applicable fragment when
  the plan marks the stage skip. Every job stays visible in the GitLab UI in
  its natural stage -- GitLab now uses the same `brik plan gate` mechanism as
  Jenkins. All 33 test-project `.gitlab-ci.yml` includes were switched from
  `dynamic-pipeline.yml` to `pipeline.yml`.

- **node-plan-docs: skipped job seeds cache markers** -- A plan-skipped stage
  job exits before `brik.gitlab.run_stage`, so the `.brik-keep`
  cache/artefact markers were never created and a skipped `brik-build` (cache
  policy `pull-push`) logged `WARNING: No files to cache`, which the suite's
  `false-positive-patterns.conf` flags. Fixed by `brik.gitlab.mark_skipped`,
  called from the gate helper's skip path. node-plan-docs back to 15/15 green.

GitLab full-suite scorecard 2026-05-21: **32/35 PASS**. The 3 fails are all
non-migration: `rust-minimal` (INFRA-1, stale runner git lock),
`dotnet-complete` (INFRA-2) -- both pass on Jenkins -- and
`workflow-trunk-feature` (the `workflow:` filter suppresses a feature-branch
push without an MR; the scenario predates the v0.6.0 workflow filter and
needs reconciling, either triggering via an MR or accepting no pipeline).

## Recently Fixed (2026-05-08)

- **python-complete environmental CVEs (no-fix in python:3.13 base)** --
  Resolved by the Findings Management Framework chantier (#10) -- the
  built-in `pragmatic` preset auto-tags any finding with empty fix
  metadata as `policy.built-in.no-upstream-fix` and any below-floor
  finding as `policy.built-in.below-severity`. Grype on
  `python:3.13.13` previously surfaced 3 high/critical CVEs without
  upstream fixes that flipped python-complete to red on every run; the
  preset now ignores them transparently. python-complete is back to
  11/11 stages green with **zero project-side configuration added**
  (pipeline 1276 on briklab GitLab, 2026-05-08). `brik-artifacts/`
  also gains the new pipeline-level layer:
  `aggregate.sarif` (multi-runs SARIF combining every stage) and
  `gl-sast-report.json` (GitLab non-Ultimate vulnerability report).
  See `brik/docs/policy.md` for DSI distribution of allowlists.
  Replaces the chantier #9 stand-alone fix; #9 archived 2026-05-08.

## Recently Fixed (2026-05-10)

- **business-gatekeeper-e2e** -- The runtime now expresses stage outcome
  through `business.{status, reason}` (success/warning/error) computed
  from a fixed matrix; `pipeline.business.status` is the worst-of and
  drives both `pipeline.run` rc and `stages.notify` exit code. The
  legacy SKIP_WITH_WARNING (exit 99) plumbing is removed end-to-end:
  `BRIK_EXIT_SKIP_WITH_WARNING`, `stage.skip_with_warning`,
  `summary.warnings`, GitLab `allow_failure: { exit_codes: [99] }` on
  lint/sast/scan/container-scan, and the Jenkins `unstable()` branch
  on rc=99 are all gone. The E2E harness follows: the
  `E2E_OPTIONAL_JOBS` convention is dropped from `gitlab-test.sh` and
  `gitlab-suite.sh`; lint/sast/scan jobs that were previously listed
  optional are promoted to required (the policy work in the previous
  chantier made them green by default). New helpers in
  `lib/e2e/lib/assert.sh`: `assert.passed`, `assert.failed`,
  `assert.warned`, `assert.skipped`, all reading `business.status`
  from `aggregate-report.json`.

  UI implication on GitLab/Jenkins: a stage in `business.warning`
  (e.g. findings ignored by policy) no longer paints "yellow"
  (allow_failure / unstable); the GitLab job stays green and the
  signal is in `aggregate-report.{md,json,html}` only. A real stage
  failure still paints red as before.

## Recently Fixed (2026-05-05)

- **platform-gate-parity (SC1)** -- Cross-platform alignment of stage gates
  with skip-with-warning visualization. Every gate-able stage is always
  instantiated on both GitLab and Jenkins; the Bash code decides between
  `run normal`, `run mandatory` (release), `skip silent` (not applicable),
  or `skip with warning` (user-disabled outside release). New
  `stage.skip_with_warning` helper records `summary.warnings[]` in the
  aggregate. GitLab signals via `allow_failure: { exit_codes: [99] }`,
  Jenkins maps exit 99 to `unstable()`. Container-scan now reads
  `package.tech.image_built` and skips silently when no image was
  produced (e.g. python-minimal). Release / package / deploy gates
  aligned: GitLab no longer needs `rules.if: '$CI_COMMIT_TAG'` on package
  (non-tag GitLab builds now include package -- documented in 0.4.0
  CHANGELOG breaking section). Released in v0.4.0. **Superseded
  2026-05-10 by business-gatekeeper-e2e (entry above) -- the
  skip-with-warning code path is gone.**

## Recently Fixed (2026-05-04)

- **pipeline-report-l4-sarif-cyclonedx** -- The lint, sast, and scan
  stages now aggregate SARIF / CycloneDX outputs into business.* under
  `aggregate-report.json`. Lint reads `brik-artifacts/lint/<check>.sarif` (one per
  configured check) and reports `business.violations.{total,
  by_severity, by_check}` plus `business.report` and
  `business.fix_applied`. Sast reads `brik-artifacts/sast/sast.sarif` and reports
  `business.findings.{total, by_severity, cwe}` plus `business.report`.
  Scan reads `brik-artifacts/scan/deps.sarif`, `brik-artifacts/scan/secret.sarif`, and
  `brik-artifacts/scan/sbom.cdx.json` and reports `business.deps.{vulnerabilities,
  affected_packages, sbom_path}`, `business.secret.{findings_count,
  report}`, and a top-level `business.report` rollup pointing at the
  deps SARIF. Schema additions are additive (v1.0 unchanged):
  `security.sast.{output_format, output_path}`,
  `security.deps.{output_path, sbom.{enabled, format, output_path}}`,
  `security.secrets.output_path`. New transverse helpers
  `lib/transverse/sarif.sh` and `lib/transverse/sbom.sh` ship the
  parsers and converters (`sarif.from_prettier`, `sarif.from_tsc`,
  `sarif.from_dotnet_format`). Scanner runner image now bundles
  `cyclonedx-cli v0.27.2` for SBOM merge; the brik repo bundles the
  official SARIF 2.1.0 + CycloneDX 1.5 schemas under
  `schemas/external/`. New e2e helpers
  `assert.artifact_is_valid_sarif` and `assert.artifact_is_valid_cyclonedx`
  validate runner outputs against those schemas via `jv`. Each business
  block is independently no-op when its source artifact is absent, so
  stacks that don't yet emit SARIF are not regressed. Test suite went
  from 2523 to 2619 ShellSpec examples (+96), 0 failures across all
  phases.

## Recently Fixed (2026-05-03)

- **jenkins-platform-parity** -- Jenkins now runs every Brik stage inside
  its dedicated brik-runner image, matching GitLab. Init and Notify run
  in `brik-runner-base` (not on the Jenkins agent), build/lint/test in
  `brik-runner-<stack>`, sast in `brik-runner-analysis`, scan and
  container-scan in `brik-runner-scanner`, deploy in `brik-runner-deploy`.
  The Jenkins agent only handles SCM checkout, stash/unstash,
  archiveArtifacts and the Notify finally orchestration. Implemented in
  `shared-libs/jenkins/vars/` via six small variables: `brikPipeline`
  (orchestrator), `brikStage` (sh wrapper), `brikRunStage` (Docker
  dispatcher), `brikResolveHome` (`@libs` discovery), `brikDockerArgs`
  (args + env-file builder), `brikReadDotenv` (parse `brik-init.env`).
  brikPipeline.call() shrank from 268 to 196 lines.
- **briklab-jenkins-image-strip** -- briklab/images/jenkins/Dockerfile
  drops Node.js, Maven, Python, Rust, .NET, gcc, libc6-dev, libicu-dev
  and the jv-builder stage. The master keeps only what it needs to drive
  Docker and serve Notify housekeeping (git, docker-cli, jq, yq, curl,
  gosu, plugins, entrypoint). Image size **4.67 GB -> 1.13 GB (-76%)**,
  build time on M-series Mac drops from ~12 min to ~3 min. Validated on
  Jenkins `--complete` 5/5 PASS (node, python, java, rust, dotnet).
- **runner-image-accuracy** -- `config.export_runner_vars` no longer
  unconditionally overwrites `BRIK_RUNNER_IMAGE` with the project's stack
  default; it early-returns when the wrapper has already injected an
  image (Jenkins via `-e BRIK_RUNNER_IMAGE=` in `docker.image().inside`,
  GitLab via `CI_JOB_IMAGE` mapping). Each stage's report fragment now
  records its actual execution image: init/notify in `brik-runner-base`,
  release/build/test in `brik-runner-<stack>`, sast in `brik-runner-analysis`,
  scan in `brik-runner-scanner`, deploy in `brik-runner-deploy`.

## Recently Fixed (2026-05-02)

- **pipeline-report-followups L1** -- aggregate now carries true
  millisecond `duration_ms` (bash 5+ `EPOCHREALTIME` via
  `_helpers.epoch_ms`, no more multiples of 1000) and the full set of
  optional pipeline metadata (`pipeline.url`, `pipeline.commit.{sha,
  short_sha, ref, branch, tag}`, `pipeline.triggered_by`).
  `_pipeline.detect_metadata` reads `CI_*`/`BUILD_*`/`GIT_*` and exports
  normalized `BRIK_*` (pre-set wins). GitLab and Jenkins `--complete`
  E2E suites assert the aggregate shape via `assert.aggregate_v1`
  (schema_version, platform, status, commit.sha, ISO-8601 timestamp,
  stage count) by downloading `brik-artifacts/aggregate-report.json`
  from the notify job.
- **pipeline-report-ci-aggregation** -- multi-container CI mode now
  produces the same aggregated `aggregate-report.{md,json}` as local mode.
  Each stage emits `brik-artifacts/<stage>.json` (Phase 0.1 schema,
  `schemas/report/v1/fragment.schema.json`, `schema_version: "1.0"`).
  GitLab job templates declare `artifacts.paths: [brik-artifacts/]`
  (1 week) and `notify.yml` keeps the aggregate for 1 month. Jenkins
  `brikPipeline.groovy` stashes per stage and unstashes in the Notify
  block. `stages.notify` detects "CI aggregation mode" by fragment
  presence and calls `report.aggregate_fragments` to merge them into
  the canonical report. Schema-version mismatch (`v2.0+` fragments) is
  warn-and-skipped for forward-compat. _ShellSpec coverage: 88 spec
  examples added (Phase 0+1+2+3.1)._

## Recently Fixed (2026-04-28)

- **jsonschema-validation** -- `jv` (santhosh-tekuri) installed in
  `brik-runner-base` via a multi-stage Go builder.
  `config.validate_schema` wired into `stages.init` and `brik validate`,
  with `config.validate_coherence` reused alongside. The pre-existing
  `error-config` E2E scenario (test-project `invalid-config`,
  `version: 99`) now fails fast at `brik-init` with the expected
  `validat|invalid|schema` log pattern. _Validated end-to-end on
  GitLab (`error-config` 1/1, `--complete` 5/5) and Jenkins
  (`error-config` 1/1, `--complete` 5/5)._

## Recently Fixed (2026-04-25 -> 2026-04-27)

Eight chantiers landed in this window; full plans archived under
[`docs/archives/chantiers/`](../../docs/archives/chantiers/) in the
parent repo:

- **P1 faux-positifs** -- noms de jobs fantômes `brik-quality`/`brik-security`,
  `brik-artifacts/` non peuplé par notify, warnings cache stack par job,
  artefacts test inexistants, SAST findings bloquants ignorés. _All five
  remediated._
- **release-stage-hardening** -- propagation des exit codes, identité git
  lue depuis `brik.yml` puis appliquée par `transverse.git.config_identity`,
  idempotence `git.tag` sur même SHA. _Débloque `node-full` GitLab._
- **lint-contract** -- migration test-projects vers ESLint 10 + flat
  config, Tier 2 strict, `_deps.sh` propage les exit codes, statuts
  `disabled / not-applicable / skipped / passed / failed` distincts.
  _Débloque `node-complete` GitLab._
- **jenkins-hardening** -- try/catch par stage dans `brikPipeline.groovy`,
  cleanup `.ssh`/`.kube` post-deploy, `reset.sh` alias `jenkins -> gitea`.
  _Débloque `dotnet-complete`, `node-deploy-ssh`, `node-deploy-rollback`
  Jenkins._
- **init-source-unique** -- `stages.init` seul lecteur de `brik.yml`,
  dotenv complet avec defaults, suppression de `build.<stack>_version`,
  `config.validate_coherence` étendu.
- **docker-buildx** -- migration `docker build` -> `docker buildx build`,
  helper `transverse.tools.docker.ensure_buildx`. Prépare le digest
  canonique pour le release promotion model.
- **security-scans-sharp** -- `osv-scanner` actionnable, `gitleaks`
  pleinement compatible avec `BRIK_PLATFORM`, monitoring de version
  des outils dans `aggregate-report.json`.
- **test-reports opt-in** -- contrat `quality.test.reports.{enabled,
  coverage,junit}` câblé sur les 5 stacks. Cobertura partout, jacoco
  pour Java via override projet. Validé end-to-end sur Jenkins (5/5)
  et GitLab (5/5).

## Procedure When a New Flake Appears

1. Apply the skill `e2e-triage-after-bulk-refactor`
   (`~/.claude/skills/learned/`) to classify the failure.
2. If pre-existing / infra / fixture: add an entry to this file with
   scenario name, platform, pipeline or build reference, exact error
   excerpt, and proposed fix.
3. Only block the current commit on real Brik regressions (path moved,
   module renamed, loader broken). Everything else goes here for
   later cleanup.

## Recently Fixed (2026-04-22)

For audit trail. Each line names the fixed scenario, the resolving
commit, and the briklab/brik repo it landed in.

- `node-deploy` (GitLab + Jenkins) - port collision with `brik-gitea`
  on host port 3000. Fixed by bumping `node-deploy/docker-compose.yml`
  host mapping to `13000:3000`. briklab `71bf6b6`.
- `node-deploy-helm` (GitLab) - missing `.gitlab-ci.yml`. Added in
  briklab `71bf6b6`.
- `node-deploy-helm` (Jenkins) - missing CasC seed job. Added in
  briklab `3f5a161`.
- `node-deploy-dryrun` (Jenkins) - `BRIK_DRY_RUN` parameter not
  declared. Added `properties([parameters([booleanParam(...)])])` to
  `brikPipeline.groovy`. brik `236591b`.
- `node-deploy-ssh` (Jenkins) - "No user exists for uid 1000" inside
  brik-runner-deploy. Run the deploy container as `-u 0:0` plus mount
  the briklab ssh key into `/opt/brik/ssh/deploy_key` and propagate
  `SSH_PRIVATE_KEY` through the env-grep. brik `236591b` + briklab
  `3f5a161`.
- `rust-complete` (GitLab) - "crate already exists on brik-cargo".
  Added `e2e.nexus.delete_cargo_crate` pre-cleanup before the
  scenario. briklab `facca85`.
- `rust-complete` (Jenkins) - "token rejected for brik-cargo" / 401.
  Two-part fix: add `CARGO_` to the env-grep in `brikPipeline.groovy`
  and propagate `NEXUS_CARGO_TOKEN` through the briklab compose env.
  brik `236591b` + briklab `9e9bc20`.
- `workflow-trunk-main` (GitLab) - silent failure when pipeline
  succeeded. Root cause was `wait_pipeline_by_sha` writing log_info
  to stdout, contaminating the captured `pipeline_id status` value
  with ANSI text. Redirected log_info / log_error to stderr.
  briklab `facca85`.
- `workflow-trunk-main` (Jenkins) - missing CasC seed job. Added in
  briklab `9e9bc20`. (Triggering still open - see above.)
- E2E harness "Logs clean: brik-deploy" false positive on a failed
  job - skip `assert.job_logs_clean` when the job/build status is
  already `failed`. Race-prone secondary checks must not mask
  primary-status assertions. briklab `facca85`.
- E2E harness pre-cleanup helpers: new
  `e2e.compose.teardown_stack <project>` and
  `e2e.nexus.delete_cargo_crate <name> <version>`, wired as per-scenario
  pre-hooks in both `gitlab-suite.sh` and `jenkins-suite.sh`. briklab
  `facca85`.
- `examples/minimal-node` local build - missing `package.json`,
  `src/`, `test/`. Restored. brik `e037886`.

## Recently Fixed (2026-04-23)

- `workflow-trunk-main` (Jenkins) - seed job existed but nothing was
  wiring Jenkins to Gitea on push, so the E2E push timed out waiting
  for a build. Installed the Gitea plugin and converted the seed to a
  `multibranchPipelineJob` backed by `giteaSCMSource` with
  `manageHooks: true` in SYSTEM mode, so Jenkins auto-registers the
  webhook at first scan. Side-patches in the E2E harness: multibranch
  URL resolver (`job/<name>/job/<branch>`), `curl -g` in `api_get` so
  `tree=builds[...]` queries don't get globbed, `>&2` on the log lines
  inside `wait_build_by_sha` / `wait_build` / `trigger_build` so the
  captured build-number isn't contaminated. Credential scope on the
  Jenkins side is GLOBAL (not SYSTEM) so the GiteaNotifier can look it
  up from the project context when pushing commit statuses back to
  Gitea. Verified E2E: build #12 PASS, "Notified" in Jenkins log
  instead of 401. briklab `6d46930`.

- `rust-complete` (Jenkins) - `cargo publish` refused to run against a
  dirty workspace (Jenkins reuses its workspace across stages; build and
  test artefacts remained in the tree). Always pass `--allow-dirty` in
  `pkg.cargo.publish`. Verified end-to-end: GitLab rust-minimal #551 +
  rust-complete #554 PASS, Jenkins rust-minimal #5 + rust-complete #8
  PASS. brik `431f51c`.

- `java-minimal` / `java-complete` (GitLab + Jenkins) - previously
  labelled "CVE flake" and "brik-package skipped flake" but both were
  the same root cause. osv-scanner's transitive Maven resolver makes an
  RPC call to `deps.dev` to resolve transitive deps from `pom.xml`; when
  that service is unreachable or flaky, osv-scanner prints
  `Error during extraction: (extracting as transitivedependency/pomxml)
  failed resolving ...: rpc error: code = Unavailable desc = service
  unavailable` and exits non-zero while still reporting `Total 0 packages
  affected by 0 known vulnerabilities`. Brik treated the non-zero exit
  as "vulnerabilities found" without surfacing the scanner's own output,
  which hid the real cause. Two-part fix: (a) `verify.scan.deps.run`
  prints the scanner output on the failure branch so CVEs (or extraction
  errors) are visible, and treats "Total 0 packages affected by 0 known
  vulnerabilities" in the output as a pass even when exit code is
  non-zero (warn-only). (b) `e2e.jenkins.trigger_build` auto-detects
  parameterized jobs and routes to `buildWithParameters` instead of
  `build`, fixing an HTTP 400 trigger failure introduced by the
  `BRIK_DRY_RUN` parameter now present on all brik jobs. Verified:
  java-minimal + java-complete PASS on both GitLab and Jenkins.
  brik `c165d35`, briklab `7b68502`.

- `workflow-trunk-main` (Jenkins) - `deploy.environments.*.when` used
  `ref: main` / `ref: tag`, which are not valid brik condition
  expressions (`conditions.eval` expects `subject <op> '<value>'`, e.g.
  `branch == 'main'`). Pipelines succeeded because the deploy stage
  skipped silently, but emitted `[ERROR] [deploy] invalid condition
  expression: ref: main` in logs. Fixed the fixture to use
  `branch == 'main'` (staging) and `tag =~ 'v*'` (production). Verified
  build #13 PASS on Jenkins, all 8 stages green, zero `invalid
  condition` hits in console. briklab `67ee1df`.

- `node-deploy-gitops` (GitLab + Jenkins) - the ArgoCD port-forward is
  started by `scripts/lib/auth/argocd-portfwd.sh` during briklab setup
  as a host-side `kubectl port-forward` background process. It dies
  silently when the setup shell exits, the laptop sleeps, or the k3d
  network hiccups, and nothing respawns it. The next E2E run then fails
  with `Failed to establish connection to host.docker.internal:9080`.
  Added `e2e.argocd.ensure_port_forward` as a per-scenario pre-cleanup
  hook in both gitlab-suite.sh and jenkins-suite.sh (gated on kubectl +
  an active kubeconfig + the argocd namespace). It delegates to the
  canonical `ensure_argocd_port_forward` which probes `:9080` and
  relaunches the port-forward if dead. Verified: killed the
  port-forward, then re-ran node-deploy-gitops on both platforms;
  preflight logged "port-forward not active, (re)starting" then "ready
  on :9080 (attempt 1/10)", scenarios passed end-to-end. Non-ArgoCD
  scenarios (e.g. node-minimal) unaffected. briklab `e7e070f`.
