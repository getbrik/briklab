# Briklab - Architecture

This document explains how Briklab works internally. It is intended for contributors and anyone curious about the design decisions behind the infrastructure.

For the user guide (installation, commands, workflows), see the [README](../README.md).

---

## Why Briklab

Brik pipelines run on real CI/CD platforms (GitLab, Jenkins, GitHub Actions). Unit tests and ShellSpec cover the runtime logic, but validating the full cycle -- from `git push` to pipeline completion -- requires actual CI infrastructure.

Briklab provides that infrastructure as a local Docker environment, reproducible in one command. No cloud accounts, no shared servers, no flaky network dependencies.

All services run together via a single `docker-compose.yml`:

| Component | Estimated RAM |
|-----------|---------------|
| GitLab CE + Runner + Registry | ~4 GB |
| Gitea + Jenkins | ~2 GB |
| Nexus 3 CE | ~1 GB |
| **Total (recommended)** | **~8 GB** |

---

## Design Principles

### 1. Single compose, all services

All services are defined in a single `docker-compose.yml`. This simplifies the CLI (no flags needed), ensures all services share the same network, and makes `docker compose up/down` straightforward.

### 2. Static IP networking

The GitLab Runner spawns CI jobs as sibling Docker containers on the host. These containers must resolve `gitlab.briklab.test` to clone repositories. A static IP network (`brik-net`, 172.20.0.0/16) with `extra_hosts` entries ensures hostname resolution works consistently, regardless of container start order.

### 3. Automated setup via Rails runner

GitLab's REST API requires authentication, but authentication tokens don't exist until after the first boot. The setup scripts bootstrap GitLab by piping Ruby code into `gitlab-rails runner` via stdin. This avoids the chicken-and-egg problem and sidesteps shell escaping issues (notably with Ruby's `create!` method).

### 4. Bleeding edge runner

The runner uses a pre-release image (`alpine3.21-bleeding`) to access the latest CI features. The trade-off: the matching helper image tag may not be published yet. The setup script explicitly injects a compatible `helper_image` into `config.toml` to prevent `image_pull_failure` errors.

---

## Infrastructure Components

```
 brik-net (172.20.0.0/16)
+-----------------------------------------------------------------+
|                                                                  |
|  +------------------+   +------------------+   +--------------+  |
|  |   GitLab CE      |   |  GitLab Runner   |   |  Registry    |  |
|  |   172.20.0.10    |   |  172.20.0.11     |   | 172.20.0.12  |  |
|  |   :8929, :2222   |   |  (no port)       |   |   :5050      |  |
|  +------------------+   +------------------+   +--------------+  |
|                                                                  |
|  +------------------+   +------------------+   +--------------+  |
|  |   Gitea          |   |  Jenkins         |   |  Nexus 3 CE  |  |
|  |   172.20.0.20    |   |  172.20.0.21     |   | 172.20.0.30  |  |
|  |   :3000, :222    |   |  :9090, :50000   |   | :8081, :8082 |  |
|  +------------------+   +------------------+   +--------------+  |
|                                                                  |
+-----------------------------------------------------------------+
```

| Service | Image | IP | Ports |
|---------|-------|----|-------|
| GitLab CE | `gitlab/gitlab-ce` | 172.20.0.10 | 8929, 2222 |
| GitLab Runner | `gitlab/gitlab-runner:alpine3.21-bleeding` | 172.20.0.11 | - |
| Docker Registry | `registry:3.0` | 172.20.0.12 | 5050 |
| Gitea | `gitea/gitea` | 172.20.0.20 | 3000, 222 |
| Jenkins | `jenkins/jenkins` | 172.20.0.21 | 9090, 50000 |
| Nexus 3 CE | `sonatype/nexus3:3.90.2-alpine` | 172.20.0.30 | 8081, 8082 |

The Runner uses `extra_hosts` to map `gitlab.briklab.test` and `nexus.briklab.test` to their static IPs. This is required because CI job containers (spawned by the Runner as sibling containers) need to resolve hostnames to clone repositories and push artifacts.

---

## Setup Flow

```
0. init
 |-- 1. check_prereqs         (docker, jq)
 |-- 2. prepare .env          (copy .env.example if missing)
 |-- 3. docker compose up -d  (wait for healthchecks)
 |-- 4. setup
 |    |-- 4.1. gitlab.sh      (GitLab configuration)
 |    |-- 4.2. runner.sh      (Runner registration)
 |    |-- 4.3. gitea.sh       (Gitea configuration)
 |    |-- 4.4. jenkins.sh     (Jenkins plugins + CasC)
 |    +-- 4.5. nexus.sh       (Nexus admin + repositories)
 +-- 5. smoke-test.sh         (component verification)
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
5. **Repositories** -- creates 6 hosted repositories: `brik-npm`, `brik-maven`, `brik-pypi`, `brik-nuget`, `brik-docker` (HTTP connector on port 8082), `brik-raw`.

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
| Registry v2 API | `curl /v2/` | HTTP 200 |
| Registry catalog | `curl /v2/_catalog` | HTTP 200 |
| Gitea HTTP | `curl /` | HTTP 200 |
| Gitea API | `curl /api/v1/version` | HTTP 200 |
| Jenkins HTTP | `curl /login` | HTTP 200 |
| Nexus HTTP | `curl /service/rest/v1/status` | HTTP 200 |
| Nexus repositories | `curl /service/rest/v1/repositories` | HTTP 200 |
| k3d cluster | `kubectl cluster-info` | Reachable |
| ArgoCD server | `kubectl get deployment` | Ready |

A summary line shows total / PASS / FAIL / SKIP counts. Exit code is non-zero if any check fails.

---

## Directory Structure

```
briklab/
|-- docker-compose.yml            # All services (GitLab + Runner + Registry + Gitea + Jenkins + Nexus)
|-- .env.example                  # Variables template
|-- scripts/
|   |-- briklab.sh                # Main CLI
|   +-- lib/
|       |-- setup/                # Setup scripts
|       |   |-- gitlab.sh         # PAT + project + runner token
|       |   |-- runner.sh         # Runner registration + helper_image
|       |   |-- gitea.sh          # Gitea initial install + API token
|       |   |-- jenkins.sh        # Jenkins plugins + CasC
|       |   |-- nexus.sh          # Nexus admin + repositories
|       |   |-- k3d.sh            # k3d cluster + ArgoCD
|       |   +-- smoke-test.sh     # Component verification
|       +-- e2e/                  # E2E test scripts
|           |-- ensure-gitlab-pat.sh         # Auto-refresh GitLab PAT
|           |-- push-test-project-gitlab.sh  # Push repos to briklab GitLab
|           |-- push-test-project-gitea.sh   # Push repos to briklab Gitea
|           |-- e2e-gitlab-test.sh           # Trigger + validate one GitLab pipeline
|           |-- e2e-gitlab-suite.sh          # Orchestrate all GitLab scenarios
|           |-- e2e-jenkins-test.sh          # Trigger + validate Jenkins pipeline
|           +-- e2e-jenkins-suite.sh         # Orchestrate all Jenkins scenarios
|-- test-projects/                # E2E fixtures (13 scenarios)
|   |-- node-minimal/             # Node.js minimal (init, build, test)
|   |-- node-full/                # Node.js full (release, quality, package)
|   |-- node-security/            # Node.js security stage (npm audit)
|   |-- node-deploy/              # Node.js deploy stage
|   |-- python-minimal/           # Python minimal (pytest)
|   |-- python-full/              # Python full (ruff, pip-audit, Docker)
|   |-- java-minimal/             # Java minimal (JUnit 5) - maven CI image
|   |-- java-full/                # Java full (checkstyle, Docker) - maven CI image
|   |-- rust-minimal/             # Rust minimal (cargo test) - rust CI image
|   |-- dotnet-minimal/           # .NET minimal (xUnit) - dotnet SDK CI image
|   |-- node-error-build/         # Error: intentionally broken build
|   |-- node-error-test/          # Error: intentionally failing tests
|   +-- invalid-config/           # Error: invalid brik.yml (version: 99)
|-- config/
|   |-- registry/config.yml       # Registry HTTP config
|   +-- jenkins/
|       |-- plugins.txt           # Required plugins
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
| `GITLAB_ROOT_PASSWORD` | `Briklab-2026!` | Root password (must be strong) |
| `GITLAB_HTTP_PORT` | `8929` | HTTP port |
| `GITLAB_SSH_PORT` | `2222` | SSH port |
| `GITLAB_HOSTNAME` | `gitlab.briklab.test` | Hostname |
| `GITLAB_RUNNER_CONCURRENT` | `4` | Max parallel jobs on the runner |
| `GITLAB_RUNNER_REQUEST_CONCURRENCY` | *(same as concurrent)* | How many jobs the runner requests simultaneously |
| `GITLAB_RUNNER_JOB_MEMORY` | `512m` | Memory limit per CI job container |
| `GITLAB_PAT` | *(auto-generated)* | Personal Access Token |
| `GITLAB_RUNNER_TOKEN` | *(auto-generated)* | Runner registration token |

### Docker Registry

| Variable | Default | Description |
|----------|---------|-------------|
| `REGISTRY_PORT` | `5050` | Registry port (5050 to avoid macOS AirPlay conflict) |

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
| `JENKINS_ADMIN_PASSWORD` | `Brik-Jenkins-2026!` | Admin password |

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

| Problem | Cause | Solution |
|---------|-------|----------|
| `grafana['enable']` crashes GitLab | Option removed in GitLab 18.x | Removed from `GITLAB_OMNIBUS_CONFIG` |
| `/-/readiness` returns 404 | Endpoint removed in GitLab 18.x | Healthcheck uses `/users/sign_in` instead |
| `create!` causes shell error | `!` is interpreted by bash/zsh | Rails runner via stdin (`cat <<'RUBY'`) |
| Port 5000 already in use (macOS) | AirPlay Receiver occupies port 5000 | Registry uses port 5050 |
| Runner `image_pull_failure` | Bleeding edge helper tag not published | Explicit `helper_image` in config.toml |
| Root password rejected | GitLab 18.x requires strong password | Default `Briklab-2026!` meets requirements |
| Forced password change at login | `password_automatically_set = true` | Rails runner sets `password_automatically_set = false` |
| Nexus healthcheck fails on Alpine | `curl` not available in Nexus Alpine image | Healthcheck uses `wget` instead |

---

## Adding a Test Project

To add a new E2E test scenario:

1. **Create a project directory** under `test-projects/<name>/` with the application code, a `brik.yml`, and a `.gitlab-ci.yml` that includes the Brik shared library.

2. **Add a `brik.yml`** declaring the stack, tools, and stages to exercise.

3. **Add a scenario entry** in `scripts/lib/e2e/e2e-gitlab-suite.sh`:
   ```bash
   SCENARIOS=(
       # ...existing scenarios...
       # Normal scenario (pipeline must succeed):
       "my-scenario|my-project|main|brik-init,brik-build,brik-test,brik-notify||300"
       # Error scenario (pipeline must fail at specific job):
       "my-error|my-project|main|brik-init||300|brik-build"
   )
   ```
   Format: `name|project|trigger_ref|required_jobs|optional_jobs|timeout|expect_failed_job`

   The 7th field is optional. When set, the E2E test expects the pipeline to fail and verifies that the specified job has `failed` status.

4. **Define required and optional jobs** -- required jobs must all succeed for the scenario to pass (in normal mode). Optional jobs are checked but do not cause failure.

5. **Override CI image** -- for non-Alpine stacks (Java, Rust, .NET), override `BRIK_CI_IMAGE` in the project's `.gitlab-ci.yml`:
   ```yaml
   variables:
     BRIK_CI_IMAGE: maven:3.9-eclipse-temurin-21-alpine

   include:
     - project: 'brik/gitlab-templates'
       ref: v0.1.0
       file: '/templates/pipeline.yml'
   ```

6. **Run it**: `./scripts/briklab.sh test --project <name>`

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

Nexus 3 CE is free, supports multiple repository formats (npm, Maven, PyPI, NuGet, Docker, raw) in a single instance, and has a well-documented REST API for automated setup. This avoids running separate registries per format.
