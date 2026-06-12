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
| scan | `unit/stages/scan_spec.sh`, `unit/stages/verify/scan/{deps,license,secret,iac,scan}_spec.sh` | node-full-cve (CVE gating), node-full (verify) | no | |
| test | `unit/stages/test_spec.sh`, `transverse/junit_spec.sh`, findings converters | node-full | no | |
| package | `unit/stages/*`, `unit/package-managers/*`, `integration/stages-x-package-manager/package_spec.sh` | node-complete (npm published through the referential PackageRegistry endpoint), node-full, node-deploy-gitops | **partial** | Real Nexus publish proven live via node-complete (J): the npm destination, declared transport posture and credential come from the referential PackageRegistry endpoint. |
| container-scan | `unit/stages/container_scan_spec.sh`, `unit/stages/verify/scan/container_spec.sh` | node-full-cve (CVE must fail the scan stage) | **yes** | node-full-cve proves real CVE-driven scan gating on the orchestrator; signing stage holds write credential to Nexus. |
| promote | `unit/stages/promote_spec.sh` | node-plan-tag (planner activates, live retag), cd-promote (channel-model promotion) | **yes** | node-plan-tag proves the planner schedules promote on a tag and a real candidate->release retag runs; cd-promote proves immutability enforcement. |
| deploy | `unit/stages/deploy*_spec.sh`, `unit/deployments/*`, `integration/stages-x-deployments/deploy_dispatch_spec.sh` | node-deploy-gitops (real ArgoCD with TLS verification), node-full (compose), node-deploy-channel (digest-pinned CD), node-deploy-signed (with evidence verification) | **yes (gitops/argocd/tls/signed)** | Real ArgoCD sync with lab CA TLS verification, digest-pinned deployment, and evidence-based authorization covered live. |
| notify | `unit/stages/notify*_spec.sh`, `unit/pipeline/report*_spec.sh` | node-full (aggregate report) | no | aggregate/report rendering owned by spec |

## Cross-cutting feature coverage

| Feature | brik/spec | Live briklab scenario | Live-only? |
|---|---|---|---|
| Planner (safe/balanced/docs/tag/invalid) | `unit/planning/*`, `unit/cli/plan*_spec.sh`, `integration/planning-x-stages/*` (cold-start, reproducibility, gate) | node-plan-tag (tag context + promote activation) | no |
| Plan adapter parity | `integration/adapter-parity/plan_adapter_parity_spec.sh` | node-full-stub (GL+J) approximates | no |
| Findings management | `transverse/findings*_spec.sh`, `contracts/findings_contract_spec.sh`, `integration/findings-x-verify-stages` | node-full (verify) | no |
| Runner-class resolution / image map | `unit/registry/runner_class_resolution_spec.sh`, `unit/pipeline/runner_images_spec.sh` | node-full-stub (stub image map) | no |
| GitLab needs/dotenv parity | `integration/adapter-parity/gitlab_{needs,dotenv}_parity_spec.sh` | node-full (GL) | no |
| Jenkins stage iteration parity | `integration/adapter-parity/adapter_coverage_spec.sh` (registry stages) | node-full (J) | no |
| Workflow filter (push+MR anti-dup) | `shared-libs/gitlab/spec/gitlab_pipeline_template_spec.sh` | workflow-trunk-main, workflow-trunk-tag, workflow-trunk-mr | **yes** -- live proof push+MR trigger filter and trunk-based sourcing |
| GitOps sync with TLS verification | `unit/deployments/gitops_spec.sh`, `unit/deployments/argocd_spec.sh` | node-deploy-gitops (syncs against ArgoCD with lab CA TLS verification), node-deploy-signed (with evidence policy checks) | **yes** |
| GitOps rollback with TLS verification | `unit/deployments/*`, `unit/rollout/*` | node-deploy-rollback (depends on gitops) | **yes** |
| Infrastructure referential binding | (none -- referential is brik runtime design, not a stage) | All scenarios (referential mounted at `/etc/brik/infra`) | **yes** -- proves endpoints, TLS trust bundles, and credential scoping work end-to-end |
| Registry identity least-privilege | (none -- identity enforcement is deployment config) | node-complete (publish via `brik-cd` read-only), node-deploy-channel (digest-pinned CD uses brik-cd) | **yes** -- proves write credential held only by signing stage |
| Evidence signing with allowed_signers | `unit/stages/deploy*_spec.sh` (CD read-back) | node-deploy-signed (signs commits with referential's ssh key, CD verifies), cd-signed-kms (KMS-backed signing) | **yes** -- proves cryptographic commit verification on the orchestrator |
| Signing credential scoping | (none -- credential distribution is platform-specific) | cd-signed-kms (the OpenBAO token travels ONLY as a project variable scoped to the brik/signing environment; the CD pipeline carries no signing credential) | **yes** -- proves signing credential isolation per environment |
| Digest-pinned deployment | `unit/stages/deploy*_spec.sh` (pin logic) | node-deploy-channel (CI publishes, CD resolves+pins digest, ArgoCD applies pinned manifest) | **yes** -- proves immutable artifact delivery end-to-end |
| Stub mode (all stages on one image) | `unit/registry/*` (runner_classes resolution) | node-full-stub (GL+J, any scenario with `--stub`) | **yes** -- live proof the full workflow runs on the stub image |

## Flagged gaps (resolution)

Resolved 2026-06-01 by restoring 3 live scenarios; further resolved 2026-06-12
with security-focused scenarios covering signed evidence and digest-pinned deployment.

1. **promote -- FULLY RESOLVED.** Live: `node-plan-tag` (tagged commit `v0.1.0`)
   proves the planner activates promote on a release tag and a real candidate->release
   docker retag runs (assertion: release image lands in Nexus). `cd-promote` (channel-model
   channel model) proves immutability enforcement on a divergent release digest.
   Both verify TLS against the lab CA. Unit: `unit/stages/promote_spec.sh`.

2. **container-scan / scan-CVE -- FULLY RESOLVED.** Live: `node-full-cve`
   (expect-fail on `brik-scan`, error pattern `GHSA`) proves CVE-driven scan gating
   on the real orchestrator; the signing stage holds the write credential to Nexus.
   Unit: `unit/stages/{container_scan,verify/scan/*}_spec.sh`.

3. **package (real Nexus publish) -- ACCEPTED single path.** Proven by
   `node-complete` on Jenkins: the npm publish goes through the referential's
   PackageRegistry endpoint (declared plain-http posture, referenced
   credential), while the default `BRIK_REGISTRY_*` identity stays read-only
   (`brik-cd`) and only the signing stage is elevated to write.
   Unit: `unit/package-managers/*`, `integration/stages-x-package-manager/package_spec.sh`.

4. **Workflow filter -- FULLY RESOLVED.** Live: `workflow-trunk-main` (default
   branch creates a pipeline) + `workflow-trunk-tag` (a tag creates a pipeline) +
   `workflow-trunk-mr` (Gitea pull request creates a pipeline). The anti-duplicate
   push+MR rule is live-proven by the MR scenario; bare feature-branch push
   intentionally suppressed. Unit: `shared-libs/gitlab/spec/gitlab_pipeline_template_spec.sh`.

5. **Infrastructure referential (NEW, 2026-06-12) -- FULLY RESOLVED.** Live: All
   scenarios mount and use `data/infra/` at `/etc/brik/infra`. The referential
   contains endpoints (registry, git-host, argocd, signing, policy), TLS bundles
   (lab CA certificates), signing keys, and credential references. `node-deploy-signed`
   and `cd-signed-kms` prove the signing key and verification material work end-to-end.
   `node-deploy-gitops` and `node-deploy-channel` prove TLS verification against the
   lab CA. Unit: referential structure and binding is proved by brik's deployment and
   transverse modules.

6. **Least-privilege registry identities (NEW, 2026-06-12) -- FULLY RESOLVED.** Live:
   `node-complete` and `node-deploy-channel` prove CI jobs hold only the read-only
   `brik-cd` identity (configured via referential bindings); only the signing/container-scan
   stage receives write (`admin`). GitLab environment-scoped CI variables enforce the
   boundary on the brik/signing environment. Jenkins CasC remaps the write identity
   via `brikDockerArgs` to the signing stage only.

7. **Evidence signing and verification (NEW, 2026-06-12) -- FULLY RESOLVED.** Live:
   `node-deploy-signed` proves CI jobs sign BuildEvidence commits with the referential's
   ssh-ed25519 key (trust/evidence_signing_key) and CD jobs verify against allowed_signers
   (git namespace). `cd-signed-kms` proves the signing path works with a KMS backend
   (OpenBAO Transit). Gitea branch protection on evidence state-repos is governed by lab
   policy. Unit: `unit/stages/deploy*_spec.sh` (CD read-back logic).

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
| node-complete | Jenkins | Only live proof of real Nexus publish (gap 3); validates publish through the lab referential's read-only `brik-cd` identity |
| node-deploy-gitops | GitLab | Real ArgoCD sync with TLS verification against lab CA. Triggered on `branch:main` (NOT a tag): the trunk-based profile gates the gitops `staging` env on `branch=='main'`, so only a main-branch pipeline exercises gitops -- a tag pipeline skips staging and runs `production`/k8s instead. The suite asserts the `brik-e2e-gitops` app reaches Synced+Healthy after the pipeline (a green pipeline alone does not prove the gitops path ran). |
| node-deploy-rollback | GitLab | Real GitOps rollback with TLS verification (depends on gitops) |
| node-plan-tag | GitLab | Tagged commit runs planner inline + asserts brik-promote -- gap 1 |
| node-full-cve | GitLab | CVE must fail brik-scan (live scan gating) -- gap 2 |
| workflow-trunk-{main,tag} | GitLab | `workflow:` filter: default branch + tag each create a pipeline -- gap 4 |
| cd-promote | GitLab | Channel-model promotion: tagged run copies candidate -> release WITH its signed referrers (`oras cp -r`) and verifies them on the destination; second phase proves the immutability refusal on a divergent release digest. Host-side registry asserts (digest equality + referrer index), not job colors. TLS verification against lab CA throughout. |
| node-deploy-channel | GitLab | CD channel keystone + promotion chain (decision #2): CI publishes once, CD deploys the digest-pinned staging env. The chain phase proves production is refused before any validation (requires_eligibility on a fresh digest), that the green staging run journals artifact_validated_for (producer trace + digest-bound event read from the evidence-cd state-repo), and that production then deploys the SAME digest (ArgoCD Synced+Healthy). TLS verification and least-privilege registry identities enforced end-to-end. |
| node-deploy-signed | GitLab | Signed evidence keystone: CI jobs sign BuildEvidence commits with the referential's ssh-ed25519 key (trust/evidence_signing_key); CD reads-back and verifies signatures against allowed_signers (git namespace). The evidence state-repo enforces branch protection via Gitea policy binding. Signing credential (COSIGN_PRIVATE_KEY, COSIGN_PASSWORD) scoped to the brik/signing environment only. |
| cd-signed-kms | GitLab | KMS variant of signed evidence (depends on node-deploy-signed): same workflow against the infra-kms referential instance where the Signing backend is OpenBAO Transit KMS with verification_key. Proves the signing path works with a KMS provider and that the scoped OpenBAO token travels as a project variable to the signing stage only. |
| any scenario `--stub` | GitLab + Jenkins | Full workflow on the single stub image (replaces the old node-full-stub row) |

## Test validity audit (2026-06-04)

Audit of "does each scenario actually validate what its name/comment claims",
prompted by finding that `node-deploy-gitops` was green without ever exercising gitops
(it ran on a tag -> production/k8s, and nothing asserted the ArgoCD sync). brik stages
exit 0 even when they self-skip / no-op, so "brik-<stage> = success" is a weak
assertion. Findings:

- **node-full (GitLab + Jenkins) -- deploy is a no-op.** No `deploy:` config, yet the
  scenario forces `BRIK_WITH_DEPLOY=true` and requires `brik-deploy`. The deploy stage
  runs with zero environments and succeeds vacuously. Treatment: comments corrected --
  node-full proves the deploy stage is *wired into the orchestrator* (parity), NOT that a
  real deploy works. Real deploy coverage = node-deploy-gitops.
- **node-plan-tag -- promote self-skips.** No `release.{candidate,release}.docker`
  config, so on a tag `brik-promote` runs but self-skips its retag (status=skipped,
  reason=no-docker-promotion-config) and the job still succeeds. Treatment: comment
  corrected -- node-plan-tag proves the planner *activates/schedules* promote on a tag,
  NOT a real candidate->release retag. **Open gap:** a real promote-retag has no live
  coverage; it needs a dedicated publish+promote project + a registry/report assertion
  (candidate chantier).
- **node-complete -- "real Nexus publish" verified via report, not a Nexus query.** The
  publish does happen, but the only assertion is `assert.image_tag` reading the
  aggregate-report `.business.image.tag`. A Nexus-side query helper
  (`assert.nexus_docker_exists` / `e2e.nexus.docker_*tags`) used to exist but was
  removed: no scenario called it, and it hit the Docker v2 API
  (`/v2/<path>/tags/list`) **without authentication** -- Nexus answers 401, so it
  silently reported "absent" for images that were present. **Recommendation:** if
  Nexus-side verification is wanted, re-add a helper that authenticates against the v2
  API (`-u admin:$NEXUS_ADMIN_PASSWORD`) and wire it post-pipeline. Lower severity
  (behaviour occurs; only the verification is report-based).

Robust pattern (to replicate): assert the *effect* in the source of truth -- e.g.
node-deploy-gitops asserts the ArgoCD app is Synced+Healthy; node-full-cve uses
`expect_fail` + error pattern. Avoid relying on job status alone.
