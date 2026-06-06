<p align="center">
  <img src="docs/briklab.jpg" alt="Briklab">
</p>

<p align="center">
  <b>The Brik test lab.</b><br>
  Local Docker infra for end-to-end validation of Brik pipelines on real GitLab and real Jenkins.<br>
  <i>One command. Two CI platforms. Real orchestrator and deploy validation.</i>
</p>

<p align="center">
  <a href="https://github.com/getbrik/briklab/actions/workflows/ci.yml"><img src="https://github.com/getbrik/briklab/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="#e2e-testing"><img src="https://img.shields.io/badge/E2E-orchestrator%20parity%20%2B%20real%20deploy-brightgreen" alt="E2E scope"></a>
  <a href="#coverage-in-numbers"><img src="https://img.shields.io/badge/validates-GitLab%20%2B%20Jenkins-blueviolet" alt="Platforms"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-blue" alt="License"></a>
</p>

## Why Briklab exists

Most of Brik's behavior is validated fast and offline by its own typed test suites (contracts, unit, and notion-pair integration tests in the `brik` repo, plus per-stack smoke tests in `brik-images`). But some things only a real orchestrator can prove: that the shared libraries drive real GitLab APIs and real Jenkins agents identically, and that the deploy stage syncs and rolls back against a real ArgoCD/GitOps target. That is what Briklab validates.

The alternatives are bad:

- Renting GitLab/Jenkins cloud accounts per contributor: expensive, slow to iterate, shared state across PRs.
- Hand-rolling GitLab CE + Jenkins (with Configuration-as-Code) + Nexus + k3d + ArgoCD in Docker: days of wiring per contributor for PAT registration, runner registration, Job DSL, Nexus repository creation, ArgoCD port-forwards.

Briklab wires it once. Every contributor runs `make init` and gets the full stack ready in 5 minutes.

For internal architecture details, see [docs/architecture.md](docs/architecture.md).

## What makes Briklab different

### 🏗️ Pre-wired infrastructure

GitLab PAT, Runner registration, Gitea PAT, Jenkins Configuration-as-Code + Job DSL, Nexus repository creation (npm, Maven, PyPI, NuGet, Docker, Cargo), k3d cluster, ArgoCD install + port-forwards, SSH target container. All scripted, all idempotent, all under `scripts/setup/`.

### 🧪 E2E framework

A focused suite of orchestrator-parity and real-deploy scenarios per platform, with single-scenario targeting (`--project <name>`), batching (`--batch-size 4`), and listing (`--list`). Built on 17 reusable Bash libraries under `scripts/lib/e2e/lib/`. Per-stage, per-stack, planner and findings behavior is validated upstream by the `brik` repo's contract/unit/integration suites, so this lab stays small and fast.

### ⚓ Real deploy targets

The deploy stage is validated against actual infrastructure, not mocks: GitOps via ArgoCD (`node-deploy-gitops`) and a 3-step rollback chain (`node-deploy-rollback`) that verifies ArgoCD rolls back to the previous image. The other deploy targets (Kubernetes, Helm, SSH, Docker Compose) have their dispatch and argument handling covered by the `brik` repo's integration tests, so their fixtures no longer live in the lab.

### 🔁 Reset, refresh and self-healing

E2E runs accumulate state -- repos, namespaces, ArgoCD apps, artifacts. `briklab.sh reset --gitlab` cleans everything in one command. Tokens and port-forwards expire on long sessions -- `briklab.sh infra-refresh` renews them without restarting any container.

Deeper failures (a stale PAT, a `NotReady` k3d node, a stranded ArgoCD application-controller) used to make deploys hang silently. The readiness gate now catches them, and `briklab.sh preflight --gitlab --with-deploy --fix` repairs them. You rarely call it directly: `briklab.sh test` runs the gate in `--fix` mode automatically, so launching the tests also heals the lab. The goal is to *run* the E2E suite, not babysit the infra.

## Quick Start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (24 GB RAM recommended)
- `jq` (`brew install jq`)
- `k3d` (lightweight K3s in Docker) -- see [install docs](https://k3d.io/#installation)
- `argocd` CLI -- see [install docs](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

| Tool | macOS | Linux |
|------|-------|-------|
| k3d | `brew install k3d` | `wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| argocd | `brew install argocd` | `curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd && rm argocd-linux-amd64` |

### Network configuration

Add to `/etc/hosts`:

```
127.0.0.1  gitlab.briklab.test nexus.briklab.test
127.0.0.1  gitea.briklab.test jenkins.briklab.test
127.0.0.1  argocd.briklab.test ssh-target.briklab.test
```

Add to Docker Desktop (Settings > Docker Engine):

```json
{
  "insecure-registries": [
    "nexus.briklab.test:8082"
  ]
}
```

### Initialize

```bash
make init
```

> GitLab takes 3-5 minutes on first start. Jenkins builds a custom Docker image on first start. Nexus takes 2-3 minutes. The script waits automatically.

## Services

| Service | URL | Credentials |
|---------|-----|-------------|
| GitLab UI | http://gitlab.briklab.test:8929 | `root` / `Brik-Gtlb-2026` |
| GitLab SSH | `ssh://git@gitlab.briklab.test:2222` | - |
| GitLab Runner | - | - |
| Gitea UI | http://gitea.briklab.test:3000 | `brik` / `Brik-Gitea-2026` |
| Jenkins UI | http://jenkins.briklab.test:9090 | `admin` / `Brik-Jenkins-2026` |
| Nexus UI | http://nexus.briklab.test:8081 | `admin` / `Brik-Nexus-2026` |
| Nexus Docker | http://nexus.briklab.test:8082 | - |
| ArgoCD UI | https://argocd.briklab.test:9080 | `admin` / (dynamic, see `k3d-start` output) |
| k3d (k3s) | localhost:6443 | - |
| SSH Target | internal only | `deploy` / SSH key |

Default credentials are defined in `.env`. Modify them **before** the first `init`.

### Nexus Repositories

Setup creates 6 hosted repositories for artifact publishing:

| Repository | Format | Endpoint | Usage |
|-----------|--------|----------|-------|
| `brik-npm` | npm | `:8081/repository/brik-npm/` | `npm publish` |
| `brik-maven` | maven2 (release) | `:8081/repository/brik-maven/` | `mvn deploy` |
| `brik-pypi` | pypi | `:8081/repository/brik-pypi/` | `twine upload` / `uv publish` |
| `brik-nuget` | nuget (V3) | `:8081/repository/brik-nuget/` | `dotnet nuget push` |
| `brik-docker` | docker | `:8082/v2/` | `docker push` |
| `brik-cargo` | cargo | `:8081/repository/brik-cargo/` | `cargo publish` (sparse protocol) |

## CLI Commands

### Lifecycle (Makefile)

Infra lifecycle is driven by the root `Makefile` (or `./scripts/infra.sh <command>`
directly). Testing, configuration and reset stay on `./scripts/briklab.sh`.

| Command | Description |
|---------|-------------|
| `make init` | First launch (start + setup + k3d + smoke-test) |
| `make start` | Start all containers |
| `make stop` | Stop all containers |
| `make restart` | Stop + start |
| `make clean` | Delete all data and volumes (prompts; `make clean-force` skips it) |
| `make k3d-start` / `make k3d-stop` | Create / destroy the k3d cluster + ArgoCD |
| `make versions` | Regenerate versions.env + Jenkins plugins + image lock from `versions.yml` |
| `make versions-check` | Fail if any generated artifact drifts from `versions.yml` (CI guard) |

### Configuration

| Command | Description |
|---------|-------------|
| `briklab.sh setup` | Re-run GitLab/Runner/Gitea/Jenkins/Nexus configuration |
| `briklab.sh smoke-test` | Verify that each component is reachable |

### Testing

Platform is required: `--gitlab` or `--jenkins`. All other flags are identical.

| Command | Description |
|---------|-------------|
| `briklab.sh test --gitlab` | Run `node-full` on GitLab |
| `briklab.sh test --gitlab --all` | Run the full GitLab E2E suite |
| `briklab.sh test --gitlab --project <name>` | Run a single GitLab scenario by name |
| `briklab.sh test --gitlab --list` | List available GitLab scenarios |
| `briklab.sh test --jenkins` | Run `node-full` on Jenkins |
| `briklab.sh test --jenkins --all` | Run the full Jenkins E2E suite |
| `briklab.sh test --jenkins --complete` | Run only Jenkins `*-complete` scenarios |
| `briklab.sh test --jenkins --project <name>` | Run a single Jenkins scenario by name |
| `briklab.sh test --jenkins --list` | List available Jenkins scenarios |
| `briklab.sh test --gitlab --batch-size N` | Execute scenarios in batches of N |
| `briklab.sh test --gitlab --project <name> --stub` | Run any scenario on the single stub image (no heavy stack images) |

**Self-healing by default.** Before touching the lab, `test` runs the readiness
gate (`preflight`) in `--fix` mode: a stale PAT, a dropped ArgoCD port-forward, a
`NotReady` k3d node, or a stranded `argocd-application-controller` is repaired
automatically, then re-verified, so the run proceeds instead of aborting. For
deploy/gitops scenarios (or `--all`) the ArgoCD + cluster checks are blocking.

| Flag | Effect |
|------|--------|
| `--stub` | Pin every stage to `brik-runner-stub` (validates the workflow without real tools) |
| `--no-repair` | Run the readiness gate but only report -- do not mutate the lab |
| `--no-preflight` | Skip the readiness gate entirely (run on a known-good lab) |

### Reset

| Command | Description |
|---------|-------------|
| `briklab.sh reset --gitlab --repos` | Delete test repos on GitLab |
| `briklab.sh reset --jenkins --repos` | Delete test repos on Gitea |
| `briklab.sh reset --k8s` | Delete test k8s namespaces |
| `briklab.sh reset --argocd` | Delete test ArgoCD apps |
| `briklab.sh reset --artifacts` | Purge Nexus artifacts |
| `briklab.sh reset --gitlab` | Full reset (repos + k8s + argocd + artifacts) |

### Maintenance

| Command | Description |
|---------|-------------|
| `briklab.sh infra-refresh` | Refresh expired tokens and port-forwards |
| `briklab.sh preflight --gitlab\|--jenkins` | Read-only readiness check (PAT, Nexus, ArgoCD, k3d node + controller) |
| `briklab.sh preflight --gitlab --with-deploy` | Make ArgoCD/cluster checks blocking (deploy-ready) |
| `briklab.sh preflight --gitlab --with-deploy --fix` | Self-heal: regenerate token, restart a `NotReady` node, reschedule a stranded ArgoCD controller, then re-verify |

### Monitoring

| Command | Description |
|---------|-------------|
| `briklab.sh status` | Show container health and access URLs |
| `briklab.sh logs <service>` | Tail logs (gitlab, runner, gitea, jenkins, nexus, ssh-target) |

### Kubernetes

k3d lifecycle lives in the Makefile: `make k3d-start` / `make k3d-stop` (see the
Lifecycle table above).

## Typical Workflow

```bash
# Day 1 - Full setup
make init                                     # First time setup (~5 min)
./scripts/briklab.sh test --gitlab --all     # Run GitLab E2E suite
./scripts/briklab.sh test --jenkins --all    # Run Jenkins E2E suite
make stop                                     # Done for the day

# Day N
make start                                    # Restart (fast, data preserved)
./scripts/briklab.sh test --gitlab           # Quick GitLab smoke test
./scripts/briklab.sh test --jenkins          # Quick Jenkins smoke test
make stop                                     # Done
```

## E2E Testing

Briklab runs a small set of end-to-end scenarios that need a real orchestrator
or real deploy infrastructure. Everything else -- per-stage logic, per-stack
dispatch, the planner, findings normalization -- is validated upstream by the
`brik` repo's contract/unit/integration suites and by `brik-images` smoke
tests, so this lab stays fast.

### GitLab

Each scenario pushes a test project to briklab GitLab, triggers a pipeline, and
validates the expected jobs.

| Scenario | Trigger | Validates | Expected |
|----------|---------|-----------|----------|
| `node-full` | tag `v0.1.0` | full flow (init, release, build, lint, sast, scan, test, package, deploy, notify) -- orchestrator parity | pass |
| `node-deploy-gitops` | tag `v0.1.0` | deploy via GitOps with a real ArgoCD sync | pass |
| `node-deploy-rollback` | multi-step | 3-step commit chain (deploy v0.1.0, deploy v0.2.0, revert config repo) verifying ArgoCD rolls back to the v0.1.0 image | pass |

### Jenkins

Jenkins mirrors GitLab for orchestrator parity: it pushes the Brik shared
library and test projects to Gitea, then triggers pipelines via the REST API.

| Scenario | Trigger | Validates | Expected |
|----------|---------|-----------|----------|
| `node-full` | job build | full flow including deploy | pass |
| `node-complete` | job build | full flow + Nexus publish, no deploy | pass |

```bash
# Run the suite
./scripts/briklab.sh test --gitlab --all
./scripts/briklab.sh test --jenkins --all

# Single scenario / list
./scripts/briklab.sh test --gitlab --project node-deploy-gitops
./scripts/briklab.sh test --gitlab --list
```

### Test projects

Test project fixtures live in `test-projects/`. Each has a `brik.yml` and platform-specific CI config (`.gitlab-ci.yml` for GitLab, `Jenkinsfile` for Jenkins).

Per-stage and per-stack behaviour is validated in the `brik` repo's spec suites
(`spec/{unit,contracts,integration}`). The lab keeps only the projects that need
a **live orchestrator** or **real external infrastructure** -- see
[docs/e2e-coverage.md](docs/e2e-coverage.md) for the full coverage map.

| Project | Stack | Purpose (live-only justification) |
|---------|-------|-----------------------------------|
| `node-full` | Node.js | Full happy path end-to-end on the real orchestrator (needs/sequence, per-job containers, dotenv) |
| `node-complete` | Node.js | Full pipeline + real npm/Docker publish to Nexus |
| `node-deploy-gitops` | Node.js | Deploy via GitOps + real ArgoCD sync |
| `node-deploy-gitops-rollback` | Node.js | Real GitOps rollback (ArgoCD, 3-step commit chain) |
| `node-workflow-trunk` | Node.js | Trunk-based workflow (push+MR anti-duplication filter) |
| `node-plan-tag` | Node.js | Tagged-commit release/promote (registry retag) |
| `node-full-cve` | Node.js | Container scan against a CVE-bearing image |

> Runner images are selected automatically by the init job based on `project.stack` and `project.stack_version` in `brik.yml`. The init job resolves the image and propagates it via dotenv to downstream jobs. Images are published at `ghcr.io/getbrik/brik-runner-<stack>:<version>`.

## Known Issues (E2E)

Full suite run on 2026-04-18

| Issue | Affected scenarios | Root cause |
|-------|-------------------|------------|
| Runner saturation | various (GitLab timeout) | Single runner overwhelmed by concurrent pipelines. Mitigate with `--batch-size` |

## Troubleshooting

**GitLab won't start** -- Check Docker Desktop has at least 18 GB RAM allocated. First start takes 3-5 minutes. Check logs: `./scripts/briklab.sh logs gitlab`

**Runner errors (`runner_system_failure` / `image_pull_failure`)** -- Verify `helper_image` is present in the runner's `config.toml`. Check logs: `./scripts/briklab.sh logs runner`. If needed, re-run `./scripts/briklab.sh setup`.

**Jenkins CasC errors** -- Check `./scripts/briklab.sh logs jenkins` for Configuration-as-Code errors. Common issue: plugin not installed. Verify `images/jenkins/plugins.txt` includes all required plugins. To reload CasC without restarting Jenkins, use the `jenkins_reload_casc` helper in `briklab.sh` (only works for CasC YAML changes; env var changes require a full restart).

**Jenkins pipeline can't find Brik library** -- The Brik shared library must be pushed to Gitea before triggering a pipeline. Run `./scripts/briklab.sh setup` to ensure Gitea is configured, then push repos with the E2E test command.

**Gitea shows install page** -- On first start, Gitea requires initial installation. The setup script handles this automatically. If it fails, check logs: `./scripts/briklab.sh logs gitea`

**Nexus slow to start** -- First start takes 2-3 minutes (JVM + plugin initialization). The healthcheck has a 180s start_period. Check logs: `./scripts/briklab.sh logs nexus`

**Nexus Docker push fails (HTTP)** -- Add `"nexus.briklab.test:8082"` to `insecure-registries` in Docker Desktop settings. The Nexus Docker registry uses HTTP, not HTTPS.

**Nexus repository creation fails** -- If `setup` is run before Nexus is fully ready, repository creation may fail. Wait for the healthcheck to pass, then re-run: `./scripts/briklab.sh setup`

**k3d cluster already exists** -- `k3d cluster delete brik && make k3d-start`

**ArgoCD won't sync** -- ArgoCD default polling is ~3 minutes. Use `argocd app get <app> --refresh hard` to force, or run `./scripts/briklab.sh infra-refresh` to renew port-forwards and tokens.

**`brik-deploy` fails with `token signature is invalid`** -- After a lab reset (`make clean` + `make init`) or any k3d/ArgoCD recreation, the ArgoCD signing key rotates and the `ARGOCD_AUTH_TOKEN` stored in GitLab CI variables goes stale. The `test` self-heal only refreshes the local token in `.env`; run `./scripts/briklab.sh infra-refresh` to propagate a fresh token to the GitLab CI variables (and Jenkins), then re-run the deploy/gitops scenarios.

**E2E timeout** -- Use `--batch-size 4` to limit concurrent pipelines. Check runner saturation with `./scripts/briklab.sh logs runner`. Run `./scripts/briklab.sh infra-refresh` if tokens expired.

**Reset between E2E runs** -- `./scripts/briklab.sh reset --gitlab` cleans repos, k8s namespaces, ArgoCD apps, and Nexus artifacts.

For the complete list of known issues and solutions, see [docs/architecture.md - Known Gotchas](docs/architecture.md#known-gotchas).

## Cleanup

```bash
# Stop containers (data preserved)
make stop

# Delete all data and volumes (irreversible, requires confirmation)
make clean

# Delete k3d cluster
make k3d-stop

# Full removal: after clean, remove Docker images manually
docker rmi gitlab/gitlab-ce:18.10.1-ce.0 gitlab/gitlab-runner:alpine3.21-bleeding
docker rmi gitea/gitea:1.25.5
docker rmi briklab-jenkins  # custom-built Jenkins image
docker rmi sonatype/nexus3:3.90.2-alpine
docker network rm brik-net 2>/dev/null
```

## Script Architecture

Briklab scripts are organized into reusable libraries under `scripts/lib/`:

```
scripts/
  briklab.sh                    # CLI entry point
  lib/
    common.sh                   # Shared utilities (logging, retry, env loading)
    infra-verify.sh             # Environment verification
    infra-refresh.sh            # Token/port-forward refresh
    auth/
      gitlab-pat.sh             # GitLab PAT management
      gitea-pat.sh              # Gitea PAT management
      argocd-token.sh           # ArgoCD token retrieval
      argocd-portfwd.sh         # ArgoCD port-forward management
    setup/
      gitlab.sh                 # GitLab CE configuration
      runner.sh                 # GitLab Runner registration
      gitea.sh                  # Gitea configuration
      jenkins.sh                # Jenkins CasC + Job DSL
      nexus.sh                  # Nexus repository creation
      k3d.sh                    # k3d cluster + ArgoCD install
      ssh-target.sh             # SSH target container setup
      smoke-test.sh             # Post-setup health checks
    e2e/
      gitlab-push.sh            # Push repos to GitLab
      gitlab-test.sh            # Single GitLab pipeline test
      gitlab-suite.sh           # GitLab scenario orchestrator
      gitlab-rollback.sh        # GitLab rollback E2E
      gitea-push.sh             # Push repos to Gitea
      jenkins-test.sh           # Single Jenkins pipeline test
      jenkins-suite.sh          # Jenkins scenario orchestrator
      jenkins-rollback.sh       # Jenkins rollback E2E
      lib/                      # Reusable E2E libraries (17 files)
        assert.sh               # Assertion framework
        auth.sh                 # PAT validation
        suite.sh                # Suite orchestrator (groups, batches)
        push.sh                 # Git push helpers
        git.sh                  # Git operations
        reset.sh                # State cleanup between runs
        rollback.sh             # Rollback test helpers
        gitlab-api.sh           # GitLab API client
        jenkins-api.sh          # Jenkins API client
        gitea-api.sh            # Gitea API client
        nexus.sh                # Nexus artifact verification
        k8s.sh                  # Kubernetes assertions
        argocd.sh               # ArgoCD sync/status
        compose.sh              # Docker Compose assertions
        ssh.sh                  # SSH deploy assertions
        error-patterns.conf     # Error detection patterns
        error-ignore-patterns.conf  # False positive filters
```

Auth libraries are reusable -- each validates and caches credentials, and can be sourced from any script.

## Coverage in numbers

- ✅ **2** CI platforms validated end-to-end (GitLab CE + Jenkins, same scenarios on both)
- ✅ **56** E2E scenarios (28 per platform: minimal, full, complete, security, deploy, helm, workflow, error)
- ✅ **6** Nexus repository formats validated (npm, Maven, PyPI, NuGet, Docker, Cargo)
- ✅ **5** deploy targets validated (Kubernetes, Helm, SSH, Docker Compose, GitOps via ArgoCD)
- ✅ **17** reusable Bash libraries under `scripts/lib/e2e/lib/`
- ✅ **1** rollback chain (3-step commit chain verifies ArgoCD rolls back to the previous image)
- ✅ **Idempotent setup** -- every step under `scripts/setup/` re-runs safely; `briklab.sh setup` reconciles without `clean`

## Related

- [Brik](https://github.com/getbrik/brik) -- the portable CI/CD pipeline system
- [Architecture](docs/architecture.md) -- how Briklab works internally

## Transparency Notice

We use AI-assisted development ([Claude Code](https://claude.ai/code) + [ECC](https://github.com/affaan-m/ECC)) to accelerate implementation:

- Every contribution (human or AI-generated) follows the same quality gates: code review, test coverage, E2E testing, and CI checks.
- AI-generated code is not perfect. Regular refactoring passes address its shortcomings, and the overall productivity gains are significant.

## License

[MPL-2.0](LICENSE)
