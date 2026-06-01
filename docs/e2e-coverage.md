# Brik E2E Coverage Map

> Non-regression safety net for the `briklab/scripts/` consolidation.
> This document maps every brik pipeline stage and cross-cutting feature to
> **where it is validated**: in the `brik` repo's spec suites (L0-L2 + local
> adapter) or in a **live** briklab scenario (real GitLab / Jenkins orchestrator
> and real external infrastructure).
>
> **Rule**: nothing is deleted from `briklab/scripts/` or `briklab/test-projects/`
> until this map shows the behaviour is covered elsewhere. A row with coverage
> ONLY in a live scenario must keep that scenario.

Last built: 2026-06-01 (Phase 1 of the briklab/scripts consolidation).

## Coverage model

| Layer | Where | What it proves |
|---|---|---|
| L0-L2 unit/contract | `brik/spec/{unit,contracts}` (209 specs) | Stage/stack/deploy/package-manager/transverse/registry/planning logic in isolation |
| Integration | `brik/spec/integration` (22 specs) | Cross-module behaviour + **adapter parity** (GitLab/Jenkins materialisation derived from the same SoT) |
| Local adapter e2e | `brik/spec/pipeline-e2e/plan_l3_local_spec.sh` + `shared-libs/local/spec` | The plan executes end-to-end through the **local** wrapper |
| Live orchestrator | `briklab` GitLab/Jenkins scenarios | The real CI engine runs the plan: needs/sequence, per-job containers, dotenv forwarding, gates |
| Live infrastructure | `briklab` deploy/gitops scenarios | Real ArgoCD sync, real GitOps rollback, real Nexus publish, real registry, real SSH |

The design intent (already reflected in the suite headers): **per-stage, per-stack,
planner and findings behaviour is owned by `brik/spec`**. Live scenarios exist only
for what specs cannot prove: the real orchestrator executing the plan, and genuinely
external infrastructure.

## Per-stage coverage

| Stage | brik/spec (authoritative) | Live briklab scenario | Live-only? | Notes |
|---|---|---|---|---|
| init | `unit/stages/init*_spec.sh`, `unit/cli/init_spec.sh` | node-full (GL+J), all | no | dotenv emit covered by `integration/adapter-parity/gitlab_dotenv_parity_spec.sh` |
| release | `unit/stages/release*_spec.sh`, `transverse/release_spec.sh`, `transverse/changelog_spec.sh` | node-full, node-complete | no | release gating in `release_gating_spec.sh` |
| build | `unit/stages/build_spec.sh`, `integration/stages-x-stack/stage_build_spec.sh`, `unit/stacks/*` | node-full | no | per-stack build owned by spec |
| lint | `unit/stages/lint*_spec.sh`, `unit/stages/verify/lint_*_spec.sh` (3-tier) | node-full (verify) | no | |
| sast | `unit/stages/sast_spec.sh`, `unit/stages/verify/scan/sast_spec.sh` | node-full (verify) | no | |
| scan | `unit/stages/scan_spec.sh`, `unit/stages/verify/scan/{deps,license,secret,iac,scan}_spec.sh` | node-full (verify) | no | |
| test | `unit/stages/test_spec.sh`, `transverse/junit_spec.sh`, findings converters | node-full | no | |
| package | `unit/stages/*`, `unit/package-managers/*`, `integration/stages-x-package-manager/package_spec.sh` | node-complete (Nexus publish), node-full | **partial** | Real Nexus publish only proven live via node-complete (J). Add a GitLab Nexus-publish assertion or keep node-complete on Jenkins. |
| container-scan | `unit/stages/container_scan_spec.sh`, `unit/stages/verify/scan/container_spec.sh` | (none) | n/a | **GAP** -- no live scenario scans a real registry image. node-full-cve / node-complete-cve test-projects exist but are not run. |
| promote | `unit/stages/promote_spec.sh` | (none) | n/a | **GAP** -- retag candidate->release on a tagged commit against the real registry is never exercised live. |
| deploy | `unit/stages/deploy*_spec.sh`, `unit/deployments/*`, `integration/stages-x-deployments/deploy_dispatch_spec.sh` | node-deploy-gitops (real ArgoCD), node-full (compose) | **yes (gitops/argocd/ssh)** | k8s/helm/ssh/compose deploy *logic* is spec-covered; real ArgoCD sync is live-only. |
| notify | `unit/stages/notify*_spec.sh`, `unit/pipeline/report*_spec.sh` | node-full (aggregate report) | no | aggregate/report rendering owned by spec |

## Cross-cutting feature coverage

| Feature | brik/spec | Live briklab scenario | Live-only? |
|---|---|---|---|
| Planner (safe/balanced/docs/tag/invalid) | `unit/planning/*`, `unit/cli/plan*_spec.sh`, `integration/planning-x-stages/*` (cold-start, reproducibility, gate) | (none -- node-plan-* projects unused) | no |
| Plan adapter parity | `integration/adapter-parity/plan_adapter_parity_spec.sh` | node-full-stub (GL+J) approximates | no |
| Findings management | `transverse/findings*_spec.sh`, `contracts/findings_contract_spec.sh`, `integration/findings-x-verify-stages` | node-full (verify) | no |
| Runner-class resolution / image map | `unit/registry/runner_class_resolution_spec.sh`, `unit/pipeline/runner_images_spec.sh` | node-full-stub (stub image map) | no |
| GitLab needs/dotenv parity | `integration/adapter-parity/gitlab_{needs,dotenv}_parity_spec.sh` | node-full (GL) | no |
| Jenkins stage iteration parity | `integration/adapter-parity/adapter_coverage_spec.sh` (registry stages) | node-full (J) | no |
| Workflow filter (push+MR anti-dup) | `shared-libs/gitlab/spec/gitlab_pipeline_template_spec.sh` | (none -- node-workflow-trunk unused) | **review** -- confirm template spec asserts the `workflow:` rules before dropping the live angle |
| GitOps sync | `unit/deployments/gitops_spec.sh`, `unit/deployments/argocd_spec.sh` | node-deploy-gitops | **yes** |
| GitOps rollback | `unit/deployments/*`, `unit/rollout/*` | node-deploy-rollback (depends on gitops) | **yes** |
| Stub mode (all stages on one image) | `unit/registry/*` (runner_classes resolution) | node-full-stub (GL+J) | **yes** -- live proof the full workflow runs on the stub image |

## Flagged gaps (resolution)

Resolved 2026-06-01 by restoring 3 live scenarios (decision: keep the 3 gap
projects + add live coverage). Live rows live in `gitlab-suite.sh`.

1. **promote -- RESOLVED.** Live: `node-plan-tag` (tagged commit `v0.1.0`) runs
   the planner inline + the full pipeline and asserts `brik-promote: success` --
   live proof the promote stage runs on a release tag. (The old `brik-downstream`
   job is gone: the v0.6 planner runs inline, not as a downstream child.) Unit:
   `unit/stages/promote_spec.sh`. Follow-up: a real candidate->release retag would
   need promote configured in the project + a registry-tag assertion.
2. **container-scan / scan-CVE -- RESOLVED.** Live: `node-full-cve` (expect-fail
   on `brik-scan`, error pattern `GHSA`) proves CVE-driven scan gating on the real
   orchestrator. Unit: `unit/stages/{container_scan,verify/scan/*}_spec.sh`.
3. **package (real Nexus publish) -- ACCEPTED single path.** Still proven only by
   `node-complete` on Jenkins; node-complete is in the irreducible keep set, so the
   live Nexus-publish assertion is preserved. Revisit only if node-complete is cut.
4. **Workflow filter -- RESOLVED (partial).** Live: `workflow-trunk-main` (default
   branch creates a pipeline) + `workflow-trunk-tag` (a tag creates a pipeline). A
   bare feature-branch push is intentionally SUPPRESSED by the anti-duplicate
   push+MR rule (no pipeline) -- correct behaviour, but the framework cannot assert
   the absence of a pipeline, so there is no live feature scenario. The rule set is
   unit-tested in `shared-libs/gitlab/spec/gitlab_pipeline_template_spec.sh`.

## Orphaned test-projects -- DELETED 2026-06-01 (28 of 35)

28 spec-covered orphans were deleted (dirs + `casc.yaml` jobs + `reset.sh` list +
docs). The 3 KEEP-pending projects were retained and now back a live scenario.

| Test project | Covered by | Disposition |
|---|---|---|
| node-minimal | `unit/stacks/node_spec.sh` + verify specs | DELETED |
| node-no-deploy, node-no-package | stage gate specs | DELETED |
| python-minimal/full/complete | `unit/stacks/python*_spec.sh` | DELETED |
| java-minimal/full/complete | `unit/stacks/java_spec.sh` | DELETED |
| rust-minimal/complete | `unit/stacks/rust_spec.sh` | DELETED |
| dotnet-minimal/complete | `unit/stacks/dotnet_spec.sh` | DELETED |
| monorepo-full | stack detect specs | DELETED |
| node-security | sast/scan verify specs | DELETED |
| node-error-build, node-error-test, node-deploy-failure | `unit/pipeline/error_spec.sh`, gating | DELETED |
| invalid-config, node-plan-invalid | `unit/cli/validate_spec.sh`, planner invalid | DELETED |
| node-plan-safe/balanced/docs | `unit/planning/*`, `integration/planning-x-stages/*` | DELETED |
| node-deploy, node-deploy-k8s/helm/ssh | `unit/deployments/*`, `integration/stages-x-deployments` | DELETED |
| node-complete-cve | `unit/stages/container_scan_spec.sh` | DELETED (node-full-cve kept instead) |
| node-workflow-trunk | live `workflow-trunk-*` chain | KEPT (gap 4 resolved) |
| node-full-cve | live `node-full-cve` scenario | KEPT (gap 2 resolved) |
| node-plan-tag | live `node-plan-tag` scenario | KEPT (gap 1 resolved) |

## Live scenarios that must stay (the irreducible set)

| Scenario | Platform | Unique justification |
|---|---|---|
| node-full | GitLab + Jenkins | Real orchestrator runs the full plan end-to-end (needs/sequence, per-job containers, dotenv) |
| node-complete | Jenkins | Only live proof of real Nexus publish (gap 3) |
| node-deploy-gitops | GitLab | Real ArgoCD sync |
| node-deploy-rollback | GitLab | Real GitOps rollback (depends on gitops) |
| node-plan-tag | GitLab | Tagged commit runs planner inline + asserts brik-promote -- gap 1 |
| node-full-cve | GitLab | CVE must fail brik-scan (live scan gating) -- gap 2 |
| workflow-trunk-{main,tag} | GitLab | `workflow:` filter: default branch + tag each create a pipeline -- gap 4 |
| any scenario `--stub` | GitLab + Jenkins | Full workflow on the single stub image (replaces the old node-full-stub row) |
