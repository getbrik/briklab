<p align="center">
  <img src="docs/briklab.jpg" alt="Briklab">
</p>

Local Docker infrastructure for testing [Brik](https://github.com/getbrik/brik) pipelines end-to-end: write `brik.yml`, push to GitLab or Gitea, watch the pipeline run on real CI platforms.

## What is Briklab

Brik needs real CI/CD platforms to validate its shared libraries and runtime. Briklab provides that infrastructure locally via Docker Compose -- no cloud accounts, no shared servers.

- One command to set up everything (`init`)
- GitLab CE + Runner + Registry for GitLab CI pipelines
- Gitea + Jenkins for Jenkins pipelines
- E2E pipeline testing with automated scenario validation on both platforms
- Managed by a Bash CLI (`scripts/briklab.sh`)

For internal architecture details, see [docs/architecture.md](docs/architecture.md).

## Quick Start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (4 GB RAM minimum, 8 GB for full setup)
- `jq` (`brew install jq`)

### Network configuration

Add to `/etc/hosts`:

```
127.0.0.1  gitlab.briklab.local registry.briklab.local
127.0.0.1  gitea.briklab.local jenkins.briklab.local argocd.briklab.local
```

Add to Docker Desktop (Settings > Docker Engine):

```json
{
  "insecure-registries": ["localhost:5050"]
}
```

### Initialize

```bash
# GitLab only (MVP)
./scripts/briklab.sh init

# GitLab + Gitea + Jenkins (full)
./scripts/briklab.sh init --full
```

> GitLab takes 3-5 minutes on first start. Jenkins builds a custom Docker image on first start. The script waits automatically.

## Services

| Service | Port(s) | Credentials |
|---------|---------|-------------|
| GitLab CE | 8929 (HTTP), 2222 (SSH) | `root` / `Briklab-2026` |
| GitLab Runner | - | - |
| Docker Registry | 5050 | - |
| Gitea | 3000 (HTTP), 222 (SSH) | `brik` / `Brik-Gitea-2026` |
| Jenkins | 9090 (HTTP), 50000 (agent) | `admin` / `Brik-Jenkins-2026` |
| k3d (k3s) | 6443, 8080 | - |
| ArgoCD | 9080 | - |

> **macOS note:** the registry uses port 5050 because AirPlay Receiver occupies port 5000.

Default credentials are defined in `.env`. Modify them **before** the first `init`.

### Access URLs

| Service | URL |
|---------|-----|
| GitLab UI | http://localhost:8929 |
| GitLab SSH | `ssh://git@localhost:2222` |
| Docker Registry | http://localhost:5050/v2/_catalog |
| Gitea UI | http://localhost:3000 |
| Jenkins UI | http://localhost:9090 |

## CLI Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `briklab.sh init [--full]` | First launch (start + setup + smoke-test) |
| `briklab.sh start [--full]` | Start containers |
| `briklab.sh stop` | Stop all containers |
| `briklab.sh restart [--full]` | Stop + start |
| `briklab.sh clean` | Delete all data and volumes (irreversible) |

### Configuration

| Command | Description |
|---------|-------------|
| `briklab.sh setup` | Re-run GitLab/Runner/Gitea/Jenkins configuration |
| `briklab.sh smoke-test` | Verify that each component is reachable |

### Testing

| Command | Description |
|---------|-------------|
| `briklab.sh test` | Run E2E pipeline for `node-minimal` on GitLab |
| `briklab.sh test --all` | Run the full E2E test suite (GitLab) |
| `briklab.sh test --project <name>` | Run a single E2E scenario (GitLab) |
| `briklab.sh test --list` | List available E2E scenarios |
| `briklab.sh test --jenkins [job]` | Run Jenkins E2E pipeline (default: `node-minimal`) |

### Monitoring

| Command | Description |
|---------|-------------|
| `briklab.sh status` | Show container health and access URLs |
| `briklab.sh logs <service>` | Tail logs (gitlab, runner, registry, gitea, jenkins) |

### Kubernetes

| Command | Description |
|---------|-------------|
| `briklab.sh k3d-start` | Create k3d cluster + install ArgoCD |
| `briklab.sh k3d-stop` | Destroy the k3d cluster |

## Typical Workflow

```bash
# Day 1 - Full setup (GitLab + Gitea + Jenkins)
./scripts/briklab.sh init --full       # First time setup (~5 min)
./scripts/briklab.sh test --all        # Run GitLab E2E suite
./scripts/briklab.sh test --jenkins    # Run Jenkins E2E pipeline
./scripts/briklab.sh stop              # Done for the day

# Day N
./scripts/briklab.sh start --full      # Restart (fast, data preserved)
./scripts/briklab.sh test --all        # Run GitLab E2E suite
./scripts/briklab.sh test --jenkins    # Run Jenkins E2E pipeline
./scripts/briklab.sh stop              # Done
```

## E2E Testing

### GitLab

Each GitLab E2E scenario pushes a test project to briklab GitLab, triggers a pipeline, and validates that specific jobs pass.

#### Scenarios (13 total)

##### Minimal stack coverage

| Scenario | Stack | Trigger | Validated stages | Expected |
|----------|-------|---------|-----------------|----------|
| `node-minimal` | Node.js | push `main` | init, build, test, notify | pass |
| `python-minimal` | Python | push `main` | init, build, test, notify | pass |
| `java-minimal` | Java | push `main` | init, build, test, notify | pass |
| `rust-minimal` | Rust | push `main` | init, build, test, notify | pass |
| `dotnet-minimal` | .NET | push `main` | init, build, test, notify | pass |

##### Full pipelines

| Scenario | Stack | Trigger | Validated stages | Expected |
|----------|-------|---------|-----------------|----------|
| `node-full` | Node.js | tag `v0.1.0` | init, release, build, quality, test, package, notify | pass |
| `python-full` | Python | tag `v0.1.0` | init, release, build, quality, security, test, package, notify | pass |
| `java-full` | Java | tag `v0.1.0` | init, release, build, quality, test, package, notify | pass |

##### Security and Deploy

| Scenario | Stack | Trigger | Validated stages | Expected |
|----------|-------|---------|-----------------|----------|
| `node-security` | Node.js | push `main` | init, build, security, test, notify | pass |
| `node-deploy` | Node.js | tag `v0.1.0` | init, release, build, test, package, deploy, notify | pass |

##### Error scenarios

| Scenario | Stack | Trigger | Expected failure | Expected |
|----------|-------|---------|-----------------|----------|
| `error-build` | Node.js | push `main` | brik-build job fails | fail |
| `error-test` | Node.js | push `main` | brik-test job fails | fail |
| `error-config` | Node.js | push `main` | brik-init job fails (invalid brik.yml) | fail |

### Jenkins

Jenkins E2E testing pushes the Brik shared library and a test project to Gitea, then triggers a Jenkins pipeline via the REST API.

The Jenkins pipeline runs the full Brik fixed flow:

```
Init -> Release -> Build -> Quality & Security -> Test -> Package -> Deploy -> Notify
```

Jenkins is configured via CasC (Configuration as Code) with:
- The Brik Jenkins Shared Library loaded from Gitea (`brik/brik` repo)
- A `node-minimal` pipeline job that pulls from Gitea (`brik/node-minimal` repo)

```bash
# Run the Jenkins E2E pipeline
./scripts/briklab.sh test --jenkins

# Run a specific job (default: node-minimal)
./scripts/briklab.sh test --jenkins node-minimal
```

### Test projects

Test project fixtures live in `test-projects/`. Each has a `brik.yml` and platform-specific CI config (`.gitlab-ci.yml` for GitLab, `Jenkinsfile` for Jenkins).

| Project | Stack | CI Image | Purpose |
|---------|-------|----------|---------|
| `node-minimal` | Node.js | alpine:3.21 (default) | Basic flow (init, build, test) |
| `node-full` | Node.js | alpine:3.21 (default) | All stages (release, quality, package) |
| `node-security` | Node.js | alpine:3.21 (default) | Security stage (npm audit) |
| `node-deploy` | Node.js | alpine:3.21 (default) | Deploy stage validation |
| `python-minimal` | Python | alpine:3.21 (default) | Python stack (pytest) |
| `python-full` | Python | alpine:3.21 (default) | Full Python pipeline (ruff, pip-audit, Docker) |
| `java-minimal` | Java | maven:3.9-eclipse-temurin-21-alpine | Java stack (JUnit 5) |
| `java-full` | Java | maven:3.9-eclipse-temurin-21-alpine | Full Java pipeline (checkstyle, Docker) |
| `rust-minimal` | Rust | rust:1-alpine3.21 | Rust stack (cargo test) |
| `dotnet-minimal` | .NET | mcr.microsoft.com/dotnet/sdk:9.0-alpine3.21 | .NET stack (xUnit) |
| `node-error-build` | Node.js | alpine:3.21 (default) | Intentionally broken build |
| `node-error-test` | Node.js | alpine:3.21 (default) | Intentionally failing tests |
| `invalid-config` | Node.js | alpine:3.21 (default) | Invalid brik.yml (version: 99) |

## Troubleshooting

**GitLab won't start** -- Check Docker Desktop has at least 4 GB RAM. First start takes 3-5 minutes. Check logs: `./scripts/briklab.sh logs gitlab`

**Runner errors (`runner_system_failure` / `image_pull_failure`)** -- Verify `helper_image` is present in the runner's `config.toml`. Check logs: `./scripts/briklab.sh logs runner`. If needed, re-run `./scripts/briklab.sh setup`.

**Port 5000 already in use (macOS)** -- AirPlay Receiver occupies port 5000. Briklab uses 5050 by default. To free 5000: Settings > General > AirDrop & Handoff > AirPlay Receiver, uncheck.

**Registry unreachable** -- Verify `"insecure-registries": ["localhost:5050"]` in Docker Desktop settings. Test: `curl http://localhost:5050/v2/`

**Jenkins CasC errors** -- Check `./scripts/briklab.sh logs jenkins` for Configuration-as-Code errors. Common issue: plugin not installed. Verify `images/jenkins/plugins.txt` includes all required plugins.

**Jenkins pipeline can't find Brik library** -- The Brik shared library must be pushed to Gitea before triggering a pipeline. Run `./scripts/briklab.sh setup` to ensure Gitea is configured, then push repos with the E2E test command.

**Gitea shows install page** -- On first start, Gitea requires initial installation. The setup script handles this automatically. If it fails, check logs: `./scripts/briklab.sh logs gitea`

For the complete list of known issues and solutions, see [docs/architecture.md - Known Gotchas](docs/architecture.md#known-gotchas).

## Cleanup

```bash
# Stop containers (data preserved)
./scripts/briklab.sh stop

# Delete all data and volumes (irreversible, requires confirmation)
./scripts/briklab.sh clean

# Full removal: after clean, remove Docker images manually
docker rmi gitlab/gitlab-ce:18.10.1-ce.0 gitlab/gitlab-runner:alpine3.21-bleeding registry:3.0
docker rmi gitea/gitea:1.25.5-rootless
docker rmi briklab-jenkins  # custom-built Jenkins image
docker network rm brik-net 2>/dev/null
```

## Status

- [x] GitLab CE + Runner + Registry
- [x] Gitea + Jenkins (CasC + Job DSL)
- [x] Automated init with smoke tests
- [x] E2E pipeline testing -- GitLab (13 scenarios: node, python, java, rust, dotnet)
- [x] E2E pipeline testing -- Jenkins (node-minimal)
- [x] Security stage E2E
- [x] Deploy stage E2E
- [x] Error scenario E2E (build fail, test fail, invalid config)
- [ ] k3d + ArgoCD integration

## Related

- [Brik](https://github.com/getbrik/brik) -- the portable CI/CD pipeline system
- [Architecture](docs/architecture.md) -- how Briklab works internally

## License

MIT
