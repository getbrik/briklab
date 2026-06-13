# Brik E2E Coverage Map

> [!NOTE]
> This map records, for every brik pipeline stage and cross-cutting feature, **where it
> is validated**: in the `brik` repo's spec suites (L0-L2 + local adapter) or in a
> **live** briklab scenario (real GitLab / Jenkins orchestrator and real external
> infrastructure).

> [!IMPORTANT]
> Before deleting anything from `briklab/scripts/` or `briklab/test-projects/`, this map
> must already show the behaviour is covered elsewhere. A row whose only coverage is a
> live scenario must keep that scenario.

## Coverage model

| Layer | Where | What it proves |
|---|---|---|
| L0-L2 unit/contract | `brik/spec/{unit,contracts}` | Stage/stack/deploy/package-manager/transverse/registry/planning logic in isolation |
| Integration | `brik/spec/integration` | Cross-module behaviour + **adapter parity** (GitLab/Jenkins materialisation derived from the same SoT) |
| Local adapter e2e | `brik/spec/pipeline-e2e/plan_l3_local_spec.sh` + `shared-libs/local/spec` | The plan executes end-to-end through the **local** wrapper |
| Live orchestrator | `briklab` GitLab/Jenkins scenarios | The real CI engine runs the plan: needs/sequence, per-job containers, dotenv forwarding, gates |
| Live infrastructure | `briklab` deploy/gitops scenarios | Real ArgoCD sync, real GitOps rollback, real Nexus publish, real registry, real SSH |

The design intent: **per-stage, per-stack, planner and findings behaviour is owned by
`brik/spec`**. Live scenarios exist only for what specs cannot prove: the real
orchestrator executing the plan, and genuinely external infrastructure.

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
| container-scan | `unit/stages/container_scan_spec.sh`, `unit/stages/verify/scan/container_spec.sh` | node-full-cve (CVE must fail the scan stage) | **yes** | node-full-cve proves real CVE-driven scan gating on the orchestrator; the signing stage holds the write credential to Nexus. |
| promote | `unit/stages/promote_spec.sh` | node-plan-tag (planner activates, live retag), cd-promote (channel-model promotion) | **yes** | node-plan-tag proves the planner schedules promote on a tag; cd-promote proves a real candidate->release copy and immutability enforcement. |
| deploy | `unit/stages/deploy*_spec.sh`, `unit/deployments/*`, `integration/stages-x-deployments/deploy_dispatch_spec.sh` | node-deploy-gitops (real ArgoCD with TLS verification), node-full (compose), node-deploy-channel (digest-pinned CD), node-deploy-signed (with evidence verification) | **yes (gitops/argocd/tls/signed)** | Real ArgoCD sync with lab CA TLS verification, digest-pinned deployment, and evidence-based authorization covered live. |
| notify | `unit/stages/notify*_spec.sh`, `unit/pipeline/report*_spec.sh` | node-full (aggregate report) | no | aggregate/report rendering owned by spec |

## Cross-cutting feature coverage

| Feature | brik/spec | Live briklab scenario | Live-only? |
|---|---|---|---|
| Planner (safe/balanced/docs/tag/invalid) | `unit/planning/*`, `unit/cli/plan*_spec.sh`, `integration/planning-x-stages/*` (cold-start, reproducibility, gate) | node-plan-tag (tag context + promote activation) | no |
| Plan adapter parity | `integration/adapter-parity/plan_adapter_parity_spec.sh` | node-full `--stub` (GL+J) approximates | no |
| Findings management | `transverse/findings*_spec.sh`, `contracts/findings_contract_spec.sh`, `integration/findings-x-verify-stages` | node-full (verify) | no |
| Runner-class resolution / image map | `unit/registry/runner_class_resolution_spec.sh`, `unit/pipeline/runner_images_spec.sh` | node-full `--stub` (stub image map) | no |
| GitLab needs/dotenv parity | `integration/adapter-parity/gitlab_{needs,dotenv}_parity_spec.sh` | node-full (GL) | no |
| Jenkins stage iteration parity | `integration/adapter-parity/adapter_coverage_spec.sh` (registry stages) | node-full (J) | no |
| Workflow filter (push+MR anti-dup) | `shared-libs/gitlab/spec/gitlab_pipeline_template_spec.sh` | workflow-trunk-main, workflow-trunk-tag, workflow-trunk-mr | **yes**, live proof of the push+MR trigger filter and trunk-based sourcing |
| GitOps sync with TLS verification | `unit/deployments/gitops_spec.sh`, `unit/deployments/argocd_spec.sh` | node-deploy-gitops (syncs against ArgoCD with lab CA TLS verification), node-deploy-signed (with evidence policy checks) | **yes** |
| GitOps rollback with TLS verification | `unit/deployments/*`, `unit/rollout/*` | node-deploy-rollback (depends on gitops) | **yes** |
| Infrastructure referential binding | (none; referential is brik runtime design, not a stage) | All scenarios (referential mounted at `/etc/brik/infra`) | **yes**, proves endpoints, TLS trust bundles and credential scoping end-to-end |
| Registry identity least-privilege | (none; identity enforcement is deployment config) | node-complete (publish via `brik-cd` read-only), node-deploy-channel (digest-pinned CD uses brik-cd) | **yes**, write credential held only by the signing stage |
| Evidence signing with allowed_signers | `unit/stages/deploy*_spec.sh` (CD read-back) | node-deploy-signed (signs commits with referential's ssh key, CD verifies), cd-signed-kms (KMS-backed signing) | **yes**, cryptographic commit verification on the orchestrator |
| Signing credential scoping | (none; credential distribution is platform-specific) | cd-signed-kms (the OpenBAO token travels ONLY as a project variable scoped to the brik/signing environment; the CD pipeline carries no signing credential) | **yes**, signing credential isolation per environment |
| Digest-pinned deployment | `unit/stages/deploy*_spec.sh` (pin logic) | node-deploy-channel (CI publishes, CD resolves+pins digest, ArgoCD applies pinned manifest) | **yes**, immutable artifact delivery end-to-end |
| Stub mode (all stages on one image) | `unit/registry/*` (runner_classes resolution) | node-full `--stub` (GL+J, any scenario with `--stub`) | **yes**, the full workflow runs on the stub image |

## Live scenarios (the irreducible set)

These need a real orchestrator or real external infrastructure; everything else is owned
by `brik/spec`.

| Scenario | Platform | Unique justification |
|---|---|---|
| node-full | GitLab + Jenkins | Real orchestrator runs the full plan end-to-end (needs/sequence, per-job containers, dotenv) |
| node-complete | Jenkins | Only live proof of real Nexus publish; validates publish through the lab referential's read-only `brik-cd` identity |
| node-deploy-gitops | GitLab | Real ArgoCD sync with TLS verification against the lab CA. Triggered on `branch:main` (not a tag): the trunk-based profile gates the gitops `staging` env on `branch=='main'`, so only a main-branch pipeline exercises gitops; a tag pipeline skips staging and runs `production`/k8s instead. The suite asserts the `brik-e2e-gitops` app reaches Synced+Healthy after the pipeline (a green pipeline alone does not prove the gitops path ran). |
| node-deploy-rollback | GitLab | Real GitOps rollback with TLS verification (depends on gitops) |
| node-plan-tag | GitLab | Tagged commit runs the planner inline and asserts brik-promote |
| node-full-cve | GitLab | CVE must fail brik-scan (live scan gating) |
| workflow-trunk-{main,tag,mr} | GitLab | `workflow:` filter: default branch, tag and merge request each create a pipeline (push+MR anti-duplication) |
| cd-promote | GitLab | Channel-model promotion: a tagged run copies candidate -> release WITH its signed referrers (`oras cp -r`) and verifies them on the destination; a second phase proves the immutability refusal on a divergent release digest. Host-side registry asserts (digest equality + referrer index), not job colors. TLS verification against the lab CA throughout. |
| node-deploy-channel | GitLab | CD channel keystone + promotion chain: CI publishes once, CD deploys the digest-pinned staging env. The chain phase proves production is refused before any validation (requires_eligibility on a fresh digest), that the green staging run journals artifact_validated_for (producer trace + digest-bound event read from the evidence-cd state-repo), and that production then deploys the SAME digest (ArgoCD Synced+Healthy). TLS verification and least-privilege registry identities enforced end-to-end. |
| node-deploy-signed | GitLab | Signed evidence keystone: CI jobs sign BuildEvidence commits with the referential's ssh-ed25519 key (trust/evidence_signing_key); CD reads-back and verifies signatures against allowed_signers (git namespace). The evidence state-repo enforces branch protection via Gitea policy binding. Signing credential (COSIGN_PRIVATE_KEY, COSIGN_PASSWORD) scoped to the brik/signing environment only. |
| cd-signed-kms | GitLab | KMS variant of signed evidence (depends on node-deploy-signed): the same workflow against the infra-kms referential instance where the Signing backend is OpenBAO Transit KMS with verification_key. Proves the signing path works with a KMS provider and that the scoped OpenBAO token travels as a project variable to the signing stage only. |
| any scenario with `--stub` | GitLab + Jenkins | Full workflow on the single stub image |

## Assertion principle

A brik stage exits 0 even when it self-skips or no-ops, so `brik-<stage> = success` is a
weak assertion on its own. Assert the **effect** in the source of truth instead: e.g.
node-deploy-gitops asserts the ArgoCD app is Synced+Healthy, node-full-cve uses
`expect_fail` plus an error pattern.

Known caveats where a scenario proves less than its name suggests:

- **node-full (GitLab + Jenkins): deploy is a no-op.** It carries no `deploy:` config yet
  forces `BRIK_WITH_DEPLOY=true` and requires `brik-deploy`, so the deploy stage runs with
  zero environments and succeeds vacuously. node-full proves the deploy stage is *wired
  into the orchestrator* (parity), not that a real deploy works; real deploy coverage is
  node-deploy-gitops.
- **node-plan-tag: promote self-skips.** With no `release.{candidate,release}.docker`
  config, `brik-promote` runs on a tag but self-skips its retag (status=skipped,
  reason=no-docker-promotion-config) and the job still succeeds. node-plan-tag proves the
  planner *activates* promote on a tag, not a real candidate->release retag; that retag is
  covered by `cd-promote` (the `node-promote-channel` project, which copies
  candidate->release and asserts the registry state host-side).
- **node-complete: real Nexus publish is verified via the aggregate report, not a Nexus
  query.** The publish happens, but the only assertion reads `.business.image.tag` from the
  aggregate report. A Nexus-side query helper would have to authenticate against the v2 API
  (`-u admin:$NEXUS_ADMIN_PASSWORD`); an earlier unauthenticated helper saw 401 and silently
  reported "absent" for images that were present, so it was removed.
