# Briklab - Architecture

This document explains how Briklab works internally. It is intended for contributors and anyone curious about the design decisions behind the infrastructure.

For the user guide see the [README](../README.md); for the full CLI reference and
runtime troubleshooting see [operations.md](operations.md).

---

## Why Briklab

Brik pipelines run on real CI/CD platforms (GitLab, Jenkins, GitHub Actions). Unit tests and ShellSpec cover the runtime logic, but validating the full cycle -- from `git push` to pipeline completion -- requires actual CI infrastructure.

Briklab provides that infrastructure as a local Docker environment, reproducible in one command. No cloud accounts, no shared servers, no flaky network dependencies.

All services run together via a single `docker-compose.yml`:

| Component | Memory limit |
|-----------|-------------|
| GitLab CE | 12 GB |
| GitLab Runner | 1 GB |
| Gitea | 512 MB |
| Jenkins | 6 GB |
| SSH Target | 128 MB |
| Nexus 3 CE | 2 GB |
| **Total** | **~22 GB** |

---

## Entrypoints

Two concerns, two entrypoints, one shared `scripts/lib/` backbone:

| Entrypoint | Owns | Commands |
|------------|------|----------|
| `Makefile` -> `scripts/infra.sh` | Infra lifecycle | `init`, `start`, `stop`, `restart`, `clean` / `clean-force`, `k3d-start`, `k3d-stop`, `versions`, `versions-check` |
| `scripts/briklab.sh` | Test + config + ops | `test`, `setup`, `reset`, `preflight`, `status`, `logs`, `smoke-test`, `infra-refresh` |

```bash
make init                                # create the whole lab (~5 min)
./scripts/briklab.sh test --gitlab --all # run the GitLab E2E suite
./scripts/briklab.sh test --jenkins --all
make stop                                # done for the day; make start to resume
```

Both dispatchers are thin: they set shared paths, source `lib/common.sh` +
`lib/cli/prereqs.sh` (the `check_prereqs` / `load_env` bootstrap), then dispatch
to `cmd_*` functions in `lib/cli/*` and notion modules in `lib/`. The lifecycle
commands moved out of `briklab.sh` into `infra.sh`; `briklab.sh` redirects them
with a hint (`'start' is an infra command -- use: make start`).

### Versions are generated

`versions.yml` is the single source of truth for every component/tool version.
`make versions` regenerates the derived artifacts (`versions.env`,
`config/jenkins/plugins.txt`, `config/brik-images.lock.yaml`) via the
`briklab.versions.*` notion (`scripts/lib/versions.sh`); `make versions-check`
fails if any artifact drifts. Never edit the generated files by hand.

### When to run `infra-refresh`

After a lab restart, a `make clean` + `make init`, or any k3d/ArgoCD recreation,
the ArgoCD server signing key rotates and previously-issued tokens are
invalidated. The `test` self-heal (`preflight --fix`) refreshes the **local**
ArgoCD token in `.env`, but only `infra-refresh` **propagates** the fresh token
to the GitLab group CI variables (`briklab.recover.gitlab_ci_vars`) and to
Jenkins. A stale CI token makes `brik-deploy` fail on `argocd app sync` with
`token signature is invalid` even though the GitOps manifests pushed cleanly.

```bash
./scripts/briklab.sh infra-refresh   # regenerate + propagate tokens, then re-test
```

Run it before deploy/gitops scenarios whenever the lab was reset between runs.

---

## Design Principles

### 1. Single compose, all services

All services are defined in a single `docker-compose.yml`. This simplifies the CLI (no flags needed), ensures all services share the same network, and makes `docker compose up/down` straightforward.

### 2. Static IP networking

The GitLab Runner spawns CI jobs as sibling Docker containers on the host. These containers must resolve `gitlab.briklab.test` to clone repositories. A static IP network (`brik-net`, 172.20.0.0/16) with `extra_hosts` entries ensures hostname resolution works consistently, regardless of container start order.

### 3. Infrastructure referential (P-lab posture)

Brik requires an infrastructure referential instance at init time (`BRIK_INFRA_DIR`), describing where lab services live, with which transport posture, and how to access them. The lab generates this instance at `data/infra/` via `scripts/lib/setup/infra-referential.sh` and mounts it read-only at `/etc/brik/infra` in all job containers. The referential is the single source of truth for endpoint declarations (Nexus docker registry, Gitea, ArgoCD), TLS trust bundles (lab CA certificate), credentials (ssh signing key, cosign key pair, allowed_signers for commit verification), and organizational policy files. This replaces the former ad-hoc environment variables (BRIK_COSIGN_*, BRIK_SSH_STRICT_HOST_KEY, BRIK_KUBECTL_OPTS, BRIK_POLICY_URL, ARGOCD_SERVER/ARGOCD_INSECURE).

### 4. Internal CA and end-to-end TLS

`scripts/lib/setup/ca.sh` mints an EC-based root CA and per-service leaf certificates valid for 825 days. The CA stays stable across lab lifecycle restarts (only rotated on explicit deletion), so principals pinned in allowed_signers and the cosign public key remain fixed. ArgoCD, Gitea, and the Nexus docker connector serve TLS issued by this CA; all consumers verify the chain against the lab CA bundle distributed through the referential's `trust/ca/<hostname>/ca.crt` convention. The Jenkins JVM truststore and system git config are imported once by `scripts/lib/auth/jenkins-trust.sh` and must be refreshed if the CA or its leaves are recreated.

### 5. Least-privilege registry identities

The Docker registry (Nexus, port 8082) carries a read-only identity `brik-cd` (role `brik-cd-read`, created by `setup/nexus.sh`) for digest resolution, attestation verification and image pull, next to the admin write identity (publish, referrer attach, channel promotion). Delivery differs per orchestrator. On GitLab the group-level `BRIK_REGISTRY_*` variables carry the write identity for the CI jobs (attest attaches referrers, promote copies channels), and the keystone scenarios scope `BRIK_REGISTRY_*` to brik-cd on the deploy environments as project environment-scoped variables, so the CD jobs (which declare their environment) resolve and pull read-only. On Jenkins, CasC defaults `BRIK_REGISTRY_*` to brik-cd for every container and carries the write identity as `BRIK_SIGNING_REGISTRY_*`, which the brik shared library remaps onto `BRIK_REGISTRY_*` for the container-scan stage only. The referential's per-environment bindings declare the `registry-read` credential, recording that the CD identity cannot push.

### 6. Signing credential isolation

For scenarios that sign artifacts through OpenBAO (cd-signed-kms), the signing token travels as a GitLab project variable scoped to the brik/signing environment, which only the brik-container-scan job declares: the build and test jobs never receive it. CD pipelines carry no signing credential at all; verification uses the exported public key (`verification_key`) from the referential's trust material. Note the Jenkins caveat documented in the brik attestation guide: `docker.inside()` re-broadcasts controller globals to every container, so an isolated signing secret on Jenkins must be delivered per stage, never as a CasC global.

### 7. Automated setup via Rails runner

GitLab's REST API requires authentication, but authentication tokens don't exist until after the first boot. The setup scripts bootstrap GitLab by piping Ruby code into `gitlab-rails runner` via stdin. This avoids the chicken-and-egg problem and sidesteps shell escaping issues (notably with Ruby's `create!` method).

### 8. Bleeding edge runner

The runner uses a pre-release image (`alpine3.21-bleeding`) to access the latest CI features. The trade-off: the matching helper image tag may not be published yet. The setup script explicitly injects a compatible `helper_image` into `config.toml` to prevent `image_pull_failure` errors.

---

## Infrastructure Components

```
 brik-net (172.20.0.0/16)
+-------------------------------------------------------------------------+
|                                                                         |
|  +------------------+   +------------------+                            |
|  |   GitLab CE      |   |  GitLab Runner   |                            |
|  |   172.20.0.10    |   |  172.20.0.11     |                            |
|  |   :8929, :2222   |   |  (no port)       |                            |
|  +------------------+   +------------------+                            |
|                                                                         |
|  +------------------+   +------------------+   +--------------+         |
|  |   Gitea (TLS)    |   |  Jenkins         |   |  Nexus 3 CE  |         |
|  |   172.20.0.20    |   |  172.20.0.21     |   | 172.20.0.30  |         |
|  |   :3000, :222    |   |  :9090, :50000   |   | :8081, :8082 |         |
|  +------------------+   +------------------+   +--------------+         |
|                                                                         |
|  +------------------+  +-----------------+   +------------------+       |
|  |   SSH Target     |  |  OpenBAO (KMS)  |   |  ArgoCD (TLS)    |       |
|  |   172.20.0.41    |  |  172.20.0.50    |   |  (k3d cluster)   |       |
|  |   :22 (internal) |  |  :8200          |   |  :9080           |       |
|  +------------------+  +-----------------+   +------------------+       |
|                                                                         |
|  Infrastructure Referential Instance (generated + mounted at setup):    |
|  data/infra/ (P-lab) or data/infra-kms/ (KMS variant)                   |
|  -> Endpoints, TLS bundles, signing keys, allowed_signers, policy       |
+-------------------------------------------------------------------------+
```

| Service | Image | IP | Ports | TLS |
|---------|-------|----|-------|-----|
| GitLab CE | `gitlab/gitlab-ce` | 172.20.0.10 | 8929, 2222 | no |
| GitLab Runner | `gitlab/gitlab-runner:alpine3.21-bleeding` | 172.20.0.11 | - | docker socket |
| Gitea | `gitea/gitea` | 172.20.0.20 | 3000, 222 | lab CA |
| Jenkins | `jenkins/jenkins` | 172.20.0.21 | 9090, 50000 | no |
| SSH Target | `briklab-ssh-target` (custom) | 172.20.0.41 | 22 (internal) | no |
| Nexus 3 CE | `sonatype/nexus3:3.90.2-alpine` | 172.20.0.30 | 8081, 8082 | lab CA (8082) |
| OpenBAO | `ghcr.io/openbao/openbao` | 172.20.0.50 | 8200 | no (dev-mode) |
| k3d cluster | `rancher/k3s` | on-host | 6443 | - |
| ArgoCD | helm-installed | k3d | 9080 | lab CA |

The Runner uses `extra_hosts` to map `gitlab.briklab.test`, `nexus.briklab.test`, and `ssh-target.briklab.test` to their static IPs. This is required because CI job containers (spawned by the Runner as sibling containers) need to resolve hostnames to clone repositories, push artifacts, and verify TLS chains.

---

## Infrastructure Referential (P-lab Posture)

The brik referential instance (`data/infra/`) is the single source of truth for the lab's infrastructure posture, generated once by `scripts/lib/setup/infra-referential.sh` and mounted read-only at `/etc/brik/infra` in all CI job containers (and forwarded to stage containers on Jenkins). It contains:

### Endpoints (apiVersion: brik.dev/referential/v1)

- **registry-candidate**: `https://nexus.briklab.test:8082` with `tls.trust: custom-ca` (zone: candidate)
- **git-host**: `https://gitea.briklab.test:3000` with `tls.trust: custom-ca` (product: gitea)
- **signing**: backend: `key` or `kms` (OpenBAO Transit on infra-kms), with `verification_key: file://trust/cosign.pub`
- **argocd**: `https://host.docker.internal:9080` with `tls.trust: custom-ca` (reached via host port-forward from job containers)
- **policy**: `file:///etc/brik/policy/brik-policy.yml` (org-wide release gates, branch protection rules for evidence repos)

### Trust Material (generated once, reused across lifecycle restarts)

- **Lab CA certificate** (`trust/ca/<hostname>/ca.crt`): root CA + per-service leaves (valid 825 days), issued by `ca.sh`
- **Signing keys** (`trust/evidence_signing_key*`): ed25519 key pair for commit signing (CI identity: `brik-ci@noreply` in the git namespace)
- **Cosign key pair** (`trust/cosign.key`, `trust/cosign.pub`): for container image attestation; private key encrypted with `COSIGN_PASSWORD` (empty in P-lab)
- **allowed_signers**: principals matrix for git commit/tag verification, used by `git verify-commit` in CD jobs

### Credentials (via env:// or file:// references)

- **Registry identity** (brik-cd): read-only Nexus account for digest resolution and pull
- **Git token** (BRIK_GIT_TOKEN): Gitea PAT for branch protection checks and state-repo operations
- **ArgoCD token** (ARGOCD_AUTH_TOKEN): rotates on each lab lifecycle event; propagated by `infra-refresh`
- **Signing credential** (scoped to brik/signing environment on GitLab, or the signing stage on Jenkins): OpenBAO transit token or local key file path + password

This architecture eliminates scattered infrastructure variables and makes the security posture explicit and auditable: every endpoint, every TLS relationship, every credential source, and every policy gate is declared in one place.

---

## Setup Flow

```
0. make init  (-> scripts/infra.sh init)
 |-- 1. check_prereqs              (docker, jq)
 |-- 2. prepare .env               (copy .env.example if missing)
 |-- 3. docker compose up -d       (wait for healthchecks)
 |-- 4. setup
 |    |-- 4.1. ca.sh               (lab CA + per-service leaf certificates)
 |    |-- 4.2. infra-referential.sh (generate the data/infra referential instance)
 |    |-- 4.3. gitlab.sh           (GitLab configuration)
 |    |-- 4.4. runner.sh           (Runner registration)
 |    |-- 4.5. gitea.sh            (Gitea configuration)
 |    |-- 4.6. jenkins.sh          (Jenkins plugins + CasC)
 |    |-- 4.7. nexus.sh            (Nexus admin + repositories + read-only brik-cd account)
 |    |-- 4.8. openbao.sh          (OpenBAO Transit KMS, cosign openbao:// scenarios)
 |    +-- 4.9. ssh-target.sh       (SSH target container setup)
 |-- 5. k3d + ArgoCD               (k3d cluster, ArgoCD install, port-forward)
 +-- 6. smoke-test.sh              (component verification)
```

### gitlab.sh - GitLab configuration

1. **Wait for GitLab** -- polls `/users/sign_in` until HTTP 200. The `/-/readiness` endpoint no longer exists in GitLab 18.x, so the login page is used instead.

2. **Root password** -- sets the password defined in `GITLAB_ROOT_PASSWORD` via `gitlab-rails runner` (stdin). Also disables the forced password change on first login by setting `password_automatically_set = false` and `password_expires_at = nil`. GitLab 18.x requires a strong password (minimum 8 characters, mixed case + special chars).

3. **Personal Access Token** -- creates a PAT with scopes `api`, `read_repository`, `write_repository` (valid 1 year). The Ruby script is piped via stdin to avoid shell escaping issues with `create!`. The token is written to `.env` as `GITLAB_PAT`.

4. **Test project** -- creates a `brik-test` project via REST API (`POST /api/v4/projects`) using the PAT. Public, initialized with a README.

5. **Runner registration token** -- retrieves the instance-level runner token via `gitlab-rails runner` and saves it to `.env` as `GITLAB_RUNNER_TOKEN`.

### runner.sh - Runner registration

1. **Register** -- `gitlab-runner register` in non-interactive mode:
   - Executor: `docker`
   - Default image: `alpine:3.21`
   - Network: `brik-net`
   - Extra hosts: `gitlab.briklab.test:172.20.0.10`, `nexus.briklab.test:172.20.0.30`
   - Tags: `docker`, `brik`

2. **Concurrent jobs** -- `gitlab-runner register` always defaults to `concurrent = 1`. The script patches `config.toml` via `sed` to set `concurrent` to the value of `GITLAB_RUNNER_CONCURRENT` (default: 4). This allows multiple jobs to run in parallel within a pipeline and across pipelines.

3. **Request concurrency** -- controls how many jobs the runner requests from GitLab simultaneously. Set via `GITLAB_RUNNER_REQUEST_CONCURRENCY` (defaults to `GITLAB_RUNNER_CONCURRENT`). Without this, the runner fetches one job at a time, delaying parallel execution even when `concurrent` allows it.

4. **Job memory limit** -- each CI job container is capped at `GITLAB_RUNNER_JOB_MEMORY` (default: `512m`) to prevent OOM kills when running multiple jobs concurrently. Adjust based on available host RAM.

5. **Helper image injection** -- the bleeding edge runner tries to pull an unpublished helper (`arm64-v18.11.0`). The script injects `helper_image = "gitlab/gitlab-runner-helper:alpine3.21-arm-bleeding"` into `config.toml` via `sed`.

6. **Verification** -- confirms the `helper_image`, `concurrent`, `request_concurrency`, and `memory` entries exist in `config.toml`.

### jenkins.sh - Jenkins configuration

Installs plugins from `config/jenkins/plugins.txt` via `jenkins-plugin-cli` and applies Configuration-as-Code from `config/jenkins/casc.yaml`.

### nexus.sh - Nexus configuration

1. **Wait for Nexus** -- polls `/service/rest/v1/status` until HTTP 200.
2. **Admin password** -- reads the initial password from the container, changes it via REST API.
3. **Docker Bearer Token Realm** -- enables the realm needed for `docker login`.
4. **Anonymous access** -- enables anonymous reads (needed for `npm install`, `docker pull`).
5. **Repositories** -- creates 6 hosted repositories: `brik-npm`, `brik-maven`, `brik-pypi`, `brik-nuget`, `brik-docker` (TLS connector on port 8082, lab CA), `brik-cargo` (sparse protocol).
6. **Read-only identity** -- creates the `brik-cd` account (role `brik-cd-read`) used by CD jobs for digest resolution, attestation verification and image pull. Write stays with `admin`.

### k3d.sh - Kubernetes setup

Creates a k3d cluster, installs ArgoCD via Helm, and sets up port-forwarding for the ArgoCD UI.

---

## Smoke Tests

The `smoke-test.sh` script verifies each component after setup. Each check outputs PASS, FAIL, or SKIP (when the service is not running).

| Test | Method | Expected |
|------|--------|----------|
| Docker daemon | `docker info` | Accessible |
| brik-net network | `docker network inspect` | Exists |
| GitLab HTTP | `curl /users/sign_in` | HTTP 200 |
| GitLab API v4 | `curl /api/v4/version` | HTTP != 000 |
| Runner container | `gitlab-runner --version` | Executable |
| Runner registered | `grep "url" config.toml` | Present |
| Nexus Docker v2 API | `curl /v2/` (port 8082) | HTTP 200 |
| Gitea HTTP | `curl /` | HTTP 200 |
| Gitea API | `curl /api/v1/version` | HTTP 200 |
| Jenkins HTTP | `curl /login` | HTTP 200 |
| Nexus HTTP | `curl /service/rest/v1/status` | HTTP 200 |
| Nexus repositories | `curl /service/rest/v1/repositories` | HTTP 200 |
| k3d cluster | `kubectl cluster-info` | Reachable |
| ArgoCD server | `kubectl get deployment` | Ready |

A summary line shows total / PASS / FAIL / SKIP counts. Exit code is non-zero if any check fails.

---

## E2E Assertion Model

E2E test assertions live in `scripts/lib/e2e/lib/assert.sh`. Most
helpers (`assert.equals`, `assert.contains`, `assert.json_eq`,
`assert.job_status`, `assert.k8s_deployment_ready`, ...) are generic;
the four business-driven helpers below align the harness with the
Brik runtime's two orthogonal axes (tech vs business).

### Business outcome helpers

Each helper takes `<stage_name> <aggregate_report_json_path>` and
reads `business.status` from the named stage's entry in
`aggregate-report.json`:

| Helper            | PASS when                                                                                       |
|---|---|
| `assert.passed`   | `business.status == "success"`                                                                  |
| `assert.failed`   | `business.status == "error"`                                                                    |
| `assert.warned`   | `business.status == "warning"`                                                                  |
| `assert.skipped`  | `business.status` is absent OR (`business.status == "success"` AND `reason == "not applicable"`) |

The four categories mirror the Brik matrix:

```
tech.status x context  ->  business.status
  success                ->  success | warning (with side-band findings.ignored)
  failed   x snapshot    ->  warning
  failed   x release     ->  error
  skipped                ->  success (reason: "not applicable")
```

So an E2E scenario that asserts `assert.warned "lint" "$AGG"` will
pass either when lint failed in snapshot context or when lint passed
with ignored findings -- both legitimate "warning" outcomes per the
runtime contract.

### Why drop OPTIONAL_JOBS

Earlier, the harness carried an
`E2E_OPTIONAL_JOBS` list (column 5 of `SCENARIOS` in `gitlab-suite.sh`)
to tolerate "warning" GitLab jobs painted yellow via
`allow_failure: { exit_codes: [99] }`. With the Brik runtime now
gating on `business.status` (and the wrappers no longer translating
exit code 99), the GitLab job color carries the tech outcome only and
the business outcome surfaces in `aggregate-report.{md,json,html}`.
The harness therefore reads business directly via the four helpers
above, and the `OPTIONAL_JOBS` convention is gone. Column 5 of
`SCENARIOS` is kept as a vestigial empty placeholder so the positional
parser stays happy.

---

## Directory Structure

```
briklab/
|-- Makefile                      # Infra lifecycle entrypoint (-> scripts/infra.sh)
|-- docker-compose.yml            # All services (GitLab + Runner + Gitea + Jenkins + Nexus + SSH Target)
|-- .env.example                  # Variables template
|-- versions.yml                  # SINGLE SOURCE OF TRUTH for component/tool versions
|-- versions.env                  # GENERATED by 'make versions' (image tags + build args)
|-- scripts/
|   |-- briklab.sh                # Test/config CLI (test/setup/reset/status/logs/preflight/infra-refresh)
|   |-- infra.sh                  # Infra lifecycle CLI (init/start/stop/clean/k3d/versions)
|   +-- lib/
|       |-- common.sh             # Shared utilities (logging, retry, env loading)
|       |-- versions.sh           # briklab.versions.* (generate/check derived artifacts)
|       |-- checks.sh             # Pure state predicates (single probe truth)
|       |-- preflight.sh          # E2E readiness gate (--fix self-heals)
|       |-- recovery.sh           # briklab.recover.* (mutating: node/controller/token)
|       |-- runner-images.sh      # Pre-pull set derived from brik's registry
|       |-- infra-verify.sh       # verify_* presentation (for setup)
|       |-- infra-refresh.sh      # Token/port-forward refresh + propagate
|       |-- cli/                  # Command modules (sourced by both dispatchers)
|       |   |-- prereqs.sh        # check_prereqs + load_env bootstrap (shared)
|       |   |-- lifecycle.sh      # init/start/stop/restart/status/logs/clean/k3d (-> infra.sh)
|       |   |-- setup.sh          # setup + smoke-test
|       |   |-- test.sh           # test (preflight --fix -> run)
|       |   +-- reset.sh          # reset
|       |-- auth/                 # Credential management (ensure_* token repair)
|       |   |-- gitlab-pat.sh     # GitLab PAT management
|       |   |-- gitea-pat.sh      # Gitea PAT management
|       |   |-- argocd-token.sh   # ArgoCD token retrieval
|       |   +-- argocd-portfwd.sh # ArgoCD port-forward management
|       |-- setup/                # Setup scripts
|       |   |-- gitlab.sh         # PAT + project + runner token
|       |   |-- runner.sh         # Runner registration + helper_image
|       |   |-- gitea.sh          # Gitea initial install + API token
|       |   |-- jenkins.sh        # Jenkins plugins + CasC
|       |   |-- nexus.sh          # Nexus admin + repositories
|       |   |-- k3d.sh            # k3d cluster + ArgoCD
|       |   |-- ssh-target.sh     # SSH target container setup
|       |   +-- smoke-test.sh     # Component verification
|       +-- e2e/                  # E2E test scripts
|           |-- gitlab-push.sh    # Push repos to GitLab
|           |-- gitlab-test.sh    # Single GitLab pipeline test
|           |-- gitlab-suite.sh   # GitLab scenario orchestrator
|           |-- gitlab-rollback.sh # GitLab rollback E2E
|           |-- gitea-push.sh     # Push repos to Gitea
|           |-- jenkins-test.sh   # Single Jenkins pipeline test
|           |-- jenkins-suite.sh  # Jenkins scenario orchestrator
|           |-- jenkins-rollback.sh # Jenkins rollback E2E
|           +-- lib/              # Reusable E2E libraries (18 libs + 3 pattern files)
|               |-- assert.sh, auth.sh, suite.sh, scenario.sh, scm.sh
|               |-- push.sh, git.sh, reset.sh, rollback.sh, cd-channel.sh
|               |-- gitlab-api.sh, jenkins-api.sh, gitea-api.sh
|               |-- nexus.sh, k8s.sh, argocd.sh, compose.sh, ssh.sh
|               +-- error-patterns.conf, error-ignore-patterns.conf, false-positive-patterns.conf
|-- test-projects/                # E2E fixtures (live-only; per-stage/stack -> brik/spec)
|   |-- node-full/                # Full happy path on the real orchestrator
|   |-- node-complete/            # Full pipeline + real npm/Docker publish to Nexus
|   |-- node-deploy-gitops/       # Deploy via GitOps + real ArgoCD sync
|   |-- node-deploy-gitops-rollback/ # Real GitOps rollback (3-step commit chain)
|   |-- node-deploy-channel/      # Digest-pinned CD + staging->production eligibility chain
|   |-- node-deploy-signed/       # Signed BuildEvidence (ssh/KMS) verified by CD
|   |-- node-promote-channel/     # Channel promotion + immutability enforcement
|   |-- node-workflow-trunk/      # Trunk-based workflow (push+MR anti-dup filter)
|   |-- node-plan-tag/            # Tagged-commit release/promote (registry retag)
|   +-- node-full-cve/            # Container scan against a CVE-bearing image
|-- images/
|   |-- jenkins/                  # Custom Jenkins image (Dockerfile + entrypoint)
|   +-- ssh-target/               # SSH target container (Dockerfile + entrypoint)
|-- config/
|   |-- brik-images.lock.yaml     # GENERATED by 'make versions' (digest-pinned runner images)
|   +-- jenkins/
|       |-- plugins.txt           # GENERATED by 'make versions' (pinned plugins)
|       +-- casc.yaml             # Jenkins Configuration-as-Code
|-- docs/
|   |-- architecture.md           # This file
|   +-- briklab.jpg               # Logo
+-- data/                         # Persistent volumes (gitignored)
```

---

## Configuration Reference (.env)

### GitLab

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_ROOT_PASSWORD` | `Brik-Gtlb-2026` | Root password (must be strong) |
| `GITLAB_HTTP_PORT` | `8929` | HTTP port |
| `GITLAB_SSH_PORT` | `2222` | SSH port |
| `GITLAB_HOSTNAME` | `gitlab.briklab.test` | Hostname |
| `GITLAB_RUNNER_CONCURRENT` | `4` | Max parallel jobs on the runner |
| `GITLAB_RUNNER_REQUEST_CONCURRENCY` | *(same as concurrent)* | How many jobs the runner requests simultaneously |
| `GITLAB_RUNNER_JOB_MEMORY` | `512m` | Memory limit per CI job container |
| `GITLAB_PAT` | *(auto-generated)* | Personal Access Token |
| `GITLAB_RUNNER_TOKEN` | *(auto-generated)* | Runner registration token |

### Gitea

| Variable | Default | Description |
|----------|---------|-------------|
| `GITEA_HTTP_PORT` | `3000` | HTTP port |
| `GITEA_SSH_PORT` | `222` | SSH port |
| `GITEA_HOSTNAME` | `gitea.briklab.test` | Hostname |

### Jenkins

| Variable | Default | Description |
|----------|---------|-------------|
| `JENKINS_HTTP_PORT` | `9090` | HTTP port |
| `JENKINS_AGENT_PORT` | `50000` | Agent port |
| `JENKINS_HOSTNAME` | `jenkins.briklab.test` | Hostname |
| `JENKINS_ADMIN_PASSWORD` | `Brik-Jenkins-2026` | Admin password (no `!` -- see Known Gotchas) |

### Nexus

| Variable | Default | Description |
|----------|---------|-------------|
| `NEXUS_HOSTNAME` | `nexus.briklab.test` | Hostname |
| `NEXUS_HTTP_PORT` | `8081` | UI/API port |
| `NEXUS_DOCKER_PORT` | `8082` | Docker hosted registry port (HTTP) |
| `NEXUS_ADMIN_PASSWORD` | `Brik-Nexus-2026` | Admin password |

### k3d / ArgoCD

| Variable | Default | Description |
|----------|---------|-------------|
| `K3D_API_PORT` | `6443` | Kubernetes API port |
| `K3D_HTTP_PORT` | `8080` | HTTP ingress port |
| `ARGOCD_PORT` | `9080` | ArgoCD UI port |
| `ARGOCD_HOSTNAME` | `argocd.briklab.test` | Hostname |

### Docker Network

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_NETWORK` | `brik-net` | Network name |
| `DOCKER_SUBNET` | `172.20.0.0/16` | Network subnet |

---

## Known Gotchas

> [!NOTE]
> Setup-time quirks the scripts handle by design (GitLab 18.x changes, bleeding-edge
> runner, Nexus on Alpine). For runtime troubleshooting see
> [operations.md](operations.md); for E2E test behaviours see
> [e2e-known-issues.md](e2e-known-issues.md).

| Problem | Cause | Solution |
|---------|-------|----------|
| `grafana['enable']` crashes GitLab | Option removed in GitLab 18.x | Removed from `GITLAB_OMNIBUS_CONFIG` |
| `/-/readiness` returns 404 | Endpoint removed in GitLab 18.x | Healthcheck uses `/users/sign_in` instead |
| `create!` causes shell error | `!` is interpreted by bash/zsh | Rails runner via stdin (`cat <<'RUBY'`) |
| Runner `image_pull_failure` | Bleeding edge helper tag not published | Explicit `helper_image` in config.toml |
| Root password rejected | GitLab 18.x requires strong password | Default `Brik-Gtlb-2026` meets requirements |
| Forced password change at login | `password_automatically_set = true` | Rails runner sets `password_automatically_set = false` |
| Nexus healthcheck fails on Alpine | `curl` not available in Nexus Alpine image | Healthcheck uses `wget` instead |
| No `!` in passwords | Bash heredoc and Ruby escaping issues | Use `Brik-Gtlb-2026` not `Brik-Gtlb-2026!` |
| ArgoCD unreachable from runners | Hostname resolves to 127.0.0.1 inside containers | Use `host.docker.internal:9080` |
| Gitea API 404 on org repos | `brik` is a user, not an organization | Use `/api/v1/user/repos` not `/api/v1/orgs/brik/repos` |
| ArgoCD doesn't pick up new commits | Default polling interval ~3 minutes | Call `?refresh=hard` before sync |
| GitLab can't mask variables with spaces | GitLab restriction on masked variable format | Avoid spaces in masked CI variable values |
| Jenkins push scenario: `No build found for SHA` | Multibranch job not indexed after a lab reset (no webhook for user-owned repos, no periodic scan) | The Jenkins suite scans after each push; see [e2e-known-issues.md](e2e-known-issues.md) |

---

## Adding a Test Project

To add a new E2E test scenario:

1. **Create a project directory** under `test-projects/<name>/` with the application code, a `brik.yml`, and a `.gitlab-ci.yml` that includes the Brik shared library.

2. **Add a `brik.yml`** declaring the stack, tools, and stages to exercise.

3. **Add a scenario entry** in `scripts/lib/e2e/gitlab-suite.sh`:
   ```bash
   SCENARIOS=(
       # ...existing scenarios...
       # Normal scenario (pipeline must succeed):
       "my-scenario|my-project|main|brik-init,brik-build,brik-test,brik-notify||300"
       # Error scenario (pipeline must fail, with error pattern and success jobs):
       "my-error|my-project|main|brik-init||300|brik-build||npm ERR!~SyntaxError|brik-init"
       # Scenario with dependency on another scenario:
       "my-step2|my-project|v0.1.0|brik-init,brik-build||300||||my-step1"
   )
   ```
   Format: `name|project|ref|required_jobs|_legacy_optional|timeout|expect_fail|ci_vars|depends_on|error_pattern|success_jobs`

   - `_legacy_optional`: vestigial empty placeholder kept for the
     positional parser. The "optional jobs" convention was dropped
     alongside the SKIP_WITH_WARNING code 99 plumbing; all jobs that
     the runtime produces are now required. Always leave this column
     empty.
   - `expect_fail`: job name that must fail (empty for success scenarios)
   - `ci_vars`: CI variables injected via API (e.g. `BRIK_DRY_RUN=true`)
   - `depends_on`: scenario name that must run first (sequential execution)
   - `error_pattern`: regex patterns to validate in logs (use `~` as OR separator)
   - `success_jobs`: jobs that must succeed even in failure scenarios

4. **Define required jobs** -- required jobs must all succeed for the scenario to pass (in normal mode). Stage warnings (e.g. findings ignored by policy) surface in `aggregate-report.json` (`business.status=warning`) without failing the job.

5. **Add group mapping** -- update `_suite_get_group()` in the suite file if the new scenario doesn't match existing patterns (A=stack, B=full, C=complete, D=security, E=deploy, F=gitops, G=workflow, H=error).

6. **Run it**: `./scripts/briklab.sh test --gitlab --project <name>`

---

## Adding a Service

To add a new CI platform or tool to Briklab:

1. **Add the service** to `docker-compose.yml`.

2. **Allocate a static IP** following the pattern: 172.20.0.1x (core), 172.20.0.2x (secondary), 172.20.0.3x (tertiary).

3. **Create a setup script** in `scripts/lib/setup/` that handles initial configuration (wait for readiness, create credentials, etc.).

4. **Add a smoke test check** in `scripts/lib/setup/smoke-test.sh`.

5. **Add `extra_hosts`** entries if the service needs to resolve other briklab hostnames.

---

## Key Architectural Decisions

### Why Docker Compose (not Kubernetes-in-Docker, not Vagrant)

Docker Compose is lightweight, widely installed, and sufficient for running a handful of services. Vagrant adds VM overhead. Kubernetes-in-Docker (kind/k3d) is used only when testing Kubernetes-specific features (deploy stage with ArgoCD).

### Why GitLab CE (not EE)

GitLab Community Edition is free, open-source, and provides all the CI/CD features Brik needs (pipelines, runners, registry integration). Enterprise Edition would add licensing complexity without benefit for testing purposes.

### Why a bleeding edge runner

Brik targets the latest GitLab CI features. Using a bleeding edge runner ensures compatibility with new pipeline syntax and behaviors. The trade-off (manual `helper_image` management) is documented and automated in the setup script.

### Why Rails runner for setup (not the API)

GitLab's API requires a valid authentication token, but tokens don't exist on a fresh install. The Rails runner provides direct access to the application layer, bypassing the API authentication requirement. This solves the bootstrapping chicken-and-egg problem.

### Why Nexus CE (not Artifactory, not custom registries)

Nexus 3 CE is free, supports multiple repository formats (npm, Maven, PyPI, NuGet, Docker, Cargo) in a single instance, and has a well-documented REST API for automated setup. This avoids running separate registries per format.
