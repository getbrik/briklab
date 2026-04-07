<p align="center">
  <img src="docs/briklab.jpg" alt="Briklab">
</p>

Local Docker infrastructure for testing [Brik](https://github.com/getbrik/brik) pipelines end-to-end: write `brik.yml`, push to GitLab or Gitea, watch the pipeline run on real CI platforms.

## What is Briklab

Brik needs real CI/CD platforms to validate its shared libraries and runtime. Briklab provides that infrastructure locally via Docker Compose -- no cloud accounts, no shared servers.

- One command to set up everything (`init`)
- GitLab CE + Runner + Registry for GitLab CI pipelines
- Gitea + Jenkins for Jenkins pipelines
- Nexus 3 CE for artifact publishing (npm, Maven, PyPI, NuGet, Docker, raw)
- E2E pipeline testing with automated scenario validation on both platforms
- Managed by a Bash CLI (`scripts/briklab.sh`)

For internal architecture details, see [docs/architecture.md](docs/architecture.md).

## Quick Start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (18 GB RAM recommended)
- `jq` (`brew install jq`)

### Network configuration

Add to `/etc/hosts`:

```
127.0.0.1  gitlab.briklab.test registry.briklab.test
127.0.0.1  gitea.briklab.test jenkins.briklab.test argocd.briklab.test
127.0.0.1  nexus.briklab.test
```

Add to Docker Desktop (Settings > Docker Engine):

```json
{
  "insecure-registries": [
    "registry.briklab.test:5050",
    "nexus.briklab.test:8082"
  ]
}
```

### Initialize

```bash
./scripts/briklab.sh init
```

> GitLab takes 3-5 minutes on first start. Jenkins builds a custom Docker image on first start. Nexus takes 2-3 minutes. The script waits automatically.

## Services

| Service | Port(s) | Credentials |
|---------|---------|-------------|
| GitLab CE | 8929 (HTTP), 2222 (SSH) | `root` / `Brik-Gitlab-2026!` |
| GitLab Runner | - | - |
| Docker Registry | 5050 | - |
| Gitea | 3000 (HTTP), 222 (SSH) | `brik` / `Brik-Gitea-2026` |
| Jenkins | 9090 (HTTP), 50000 (agent) | `admin` / `Brik-Jenkins-2026` |
| Nexus 3 CE | 8081 (UI/API), 8082 (Docker) | `admin` / `Brik-Nexus-2026` |
| k3d (k3s) | 6443, 8080 | - |
| ArgoCD | 9080 | - |

> **macOS note:** the registry uses port 5050 because AirPlay Receiver occupies port 5000.

Default credentials are defined in `.env`. Modify them **before** the first `init`.

### Access URLs

| Service | URL |
|---------|-----|
| GitLab UI | http://gitlab.briklab.test:8929 |
| GitLab SSH | `ssh://git@gitlab.briklab.test:2222` |
| Docker Registry | http://registry.briklab.test:5050/v2/_catalog |
| Gitea UI | http://gitea.briklab.test:3000 |
| Jenkins UI | http://jenkins.briklab.test:9090 |
| Nexus UI | http://nexus.briklab.test:8081 |
| Nexus Docker | http://nexus.briklab.test:8082 |

### Nexus Repositories

Setup creates 6 hosted repositories for artifact publishing:

| Repository | Format | Endpoint | Usage |
|-----------|--------|----------|-------|
| `brik-npm` | npm | `:8081/repository/brik-npm/` | `npm publish` |
| `brik-maven` | maven2 (release) | `:8081/repository/brik-maven/` | `mvn deploy` |
| `brik-pypi` | pypi | `:8081/repository/brik-pypi/` | `twine upload` / `uv publish` |
| `brik-nuget` | nuget (V3) | `:8081/repository/brik-nuget/` | `dotnet nuget push` |
| `brik-docker` | docker | `:8082/v2/` | `docker push` |
| `brik-raw` | raw | `:8081/repository/brik-raw/` | Generic artifacts (Cargo workaround) |

> **Note:** Nexus CE does not support the Cargo registry protocol natively. Rust crate publishing uses `cargo publish --dry-run` for validation, with Docker as the actual publish target.

## CLI Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `briklab.sh init` | First launch (start + setup + smoke-test) |
| `briklab.sh start` | Start all containers (+ set root password) |
| `briklab.sh stop` | Stop all containers |
| `briklab.sh restart` | Stop + start |
| `briklab.sh clean` | Delete all data and volumes (irreversible) |

### Configuration

| Command | Description |
|---------|-------------|
| `briklab.sh setup` | Re-run GitLab/Runner/Gitea/Jenkins/Nexus configuration |
| `briklab.sh smoke-test` | Verify that each component is reachable |

### Testing

Platform is required: `--gitlab` or `--jenkins`. All other flags are identical.

| Command | Description |
|---------|-------------|
| `briklab.sh test --gitlab` | Run `node-minimal` on GitLab |
| `briklab.sh test --gitlab --all` | Run the full GitLab E2E suite |
| `briklab.sh test --gitlab --complete` | Run only `*-complete` scenarios (with Nexus publish) |
| `briklab.sh test --gitlab --project <name>` | Run a single GitLab scenario by name |
| `briklab.sh test --gitlab --list` | List available GitLab scenarios |
| `briklab.sh test --jenkins` | Run `node-minimal` on Jenkins |
| `briklab.sh test --jenkins --all` | Run the full Jenkins E2E suite |
| `briklab.sh test --jenkins --complete` | Run only Jenkins `*-complete` scenarios |
| `briklab.sh test --jenkins --project <name>` | Run a single Jenkins scenario by name |
| `briklab.sh test --jenkins --list` | List available Jenkins scenarios |

### Monitoring

| Command | Description |
|---------|-------------|
| `briklab.sh status` | Show container health and access URLs |
| `briklab.sh logs <service>` | Tail logs (gitlab, runner, registry, gitea, jenkins, nexus) |

### Kubernetes

| Command | Description |
|---------|-------------|
| `briklab.sh k3d-start` | Create k3d cluster + install ArgoCD |
| `briklab.sh k3d-stop` | Destroy the k3d cluster |

## Typical Workflow

```bash
# Day 1 - Full setup
./scripts/briklab.sh init                    # First time setup (~5 min)
./scripts/briklab.sh test --gitlab --all     # Run GitLab E2E suite
./scripts/briklab.sh test --jenkins --all    # Run Jenkins E2E suite
./scripts/briklab.sh stop                    # Done for the day

# Day N
./scripts/briklab.sh start                   # Restart (fast, data preserved)
./scripts/briklab.sh test --gitlab           # Quick GitLab smoke test
./scripts/briklab.sh test --jenkins          # Quick Jenkins smoke test
./scripts/briklab.sh stop                    # Done
```

## E2E Testing

### GitLab

Each GitLab E2E scenario pushes a test project to briklab GitLab, triggers a pipeline, and validates that specific jobs pass.

#### Scenarios (18 total)

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

##### Complete pipelines with Nexus publish

| Scenario | Stack | Trigger | Validated stages | Expected |
|----------|-------|---------|-----------------|----------|
| `node-complete` | Node.js | tag `v0.1.0` | init, release, build, test, package, notify | pass |
| `python-complete` | Python | tag `v0.1.0` | init, release, build, test, package, notify | pass |
| `java-complete` | Java | tag `v0.1.0` | init, release, build, test, package, notify | pass |
| `rust-complete` | Rust | tag `v0.1.0` | init, release, build, test, package, notify | pass |
| `dotnet-complete` | .NET | tag `v0.1.0` | init, release, build, test, package, notify | pass |

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

| Project | Stack | Runner Image | Purpose |
|---------|-------|--------------|---------|
| `node-minimal` | Node.js | `brik-runner-node:22` | Basic flow (init, build, test) |
| `node-full` | Node.js | `brik-runner-node:22` | All stages (release, quality, package) |
| `node-security` | Node.js | `brik-runner-node:22` | Security stage (npm audit) |
| `node-deploy` | Node.js | `brik-runner-node:22` | Deploy stage validation |
| `python-minimal` | Python | `brik-runner-python:3.13` | Python stack (pytest) |
| `python-full` | Python | `brik-runner-python:3.13` | Full Python pipeline (ruff, pip-audit, Docker) |
| `java-minimal` | Java | `brik-runner-java:21` | Java stack (JUnit 5) |
| `java-full` | Java | `brik-runner-java:21` | Full Java pipeline (checkstyle, Docker) |
| `rust-minimal` | Rust | `brik-runner-rust:1` | Rust stack (cargo test) |
| `dotnet-minimal` | .NET | `brik-runner-dotnet:9.0` | .NET stack (xUnit) |
| `node-complete` | Node.js | `brik-runner-node:22` | Full pipeline + npm/Docker publish to Nexus |
| `python-complete` | Python | `brik-runner-python:3.13` | Full pipeline + PyPI/Docker publish to Nexus |
| `java-complete` | Java | `brik-runner-java:21` | Full pipeline + Maven/Docker publish to Nexus |
| `rust-complete` | Rust | `brik-runner-rust:1` | Full pipeline + Cargo dry-run/Docker publish to Nexus |
| `dotnet-complete` | .NET | `brik-runner-dotnet:9.0` | Full pipeline + NuGet/Docker publish to Nexus |
| `node-error-build` | Node.js | `brik-runner-node:22` | Intentionally broken build |
| `node-error-test` | Node.js | `brik-runner-node:22` | Intentionally failing tests |
| `invalid-config` | Node.js | `brik-runner-base:latest` | Invalid brik.yml (version: 99) |

> Runner images are selected automatically by the init job based on `project.stack` and `project.stack_version` in `brik.yml`. The init job resolves the image and propagates it via dotenv to downstream jobs. Images are published at `ghcr.io/getbrik/brik-runner-<stack>:<version>`.

## Troubleshooting

**GitLab won't start** -- Check Docker Desktop has at least 18 GB RAM allocated. First start takes 3-5 minutes. Check logs: `./scripts/briklab.sh logs gitlab`

**Runner errors (`runner_system_failure` / `image_pull_failure`)** -- Verify `helper_image` is present in the runner's `config.toml`. Check logs: `./scripts/briklab.sh logs runner`. If needed, re-run `./scripts/briklab.sh setup`.

**Port 5000 already in use (macOS)** -- AirPlay Receiver occupies port 5000. Briklab uses 5050 by default. To free 5000: Settings > General > AirDrop & Handoff > AirPlay Receiver, uncheck.

**Registry unreachable** -- Verify `"insecure-registries": ["registry.briklab.test:5050"]` in Docker Desktop settings. Test: `curl http://registry.briklab.test:5050/v2/`

**Jenkins CasC errors** -- Check `./scripts/briklab.sh logs jenkins` for Configuration-as-Code errors. Common issue: plugin not installed. Verify `images/jenkins/plugins.txt` includes all required plugins. To reload CasC without restarting Jenkins, use the `jenkins_reload_casc` helper in `briklab.sh` (only works for CasC YAML changes; env var changes require a full restart).

**Jenkins pipeline can't find Brik library** -- The Brik shared library must be pushed to Gitea before triggering a pipeline. Run `./scripts/briklab.sh setup` to ensure Gitea is configured, then push repos with the E2E test command.

**Gitea shows install page** -- On first start, Gitea requires initial installation. The setup script handles this automatically. If it fails, check logs: `./scripts/briklab.sh logs gitea`

**Nexus slow to start** -- First start takes 2-3 minutes (JVM + plugin initialization). The healthcheck has a 180s start_period. Check logs: `./scripts/briklab.sh logs nexus`

**Nexus Docker push fails (HTTP)** -- Add `"nexus.briklab.test:8082"` to `insecure-registries` in Docker Desktop settings. The Nexus Docker registry uses HTTP, not HTTPS.

**Nexus repository creation fails** -- If `setup` is run before Nexus is fully ready, repository creation may fail. Wait for the healthcheck to pass, then re-run: `./scripts/briklab.sh setup`

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
docker rmi sonatype/nexus3:3.90.2-alpine
docker network rm brik-net 2>/dev/null
```

## Status

- [x] GitLab CE + Runner + Registry
- [x] Gitea + Jenkins (CasC + Job DSL)
- [x] Nexus 3 CE -- artifact publishing (npm, Maven, PyPI, NuGet, Docker, raw)
- [x] Automated init with smoke tests
- [x] E2E pipeline testing -- GitLab (18 scenarios: node, python, java, rust, dotnet)
- [x] E2E pipeline testing -- Jenkins (node-minimal)
- [x] Security stage E2E
- [x] Deploy stage E2E
- [x] Error scenario E2E (build fail, test fail, invalid config)
- [ ] Complete E2E scenarios with Nexus artifact verification
- [ ] k3d + ArgoCD integration

## Related

- [Brik](https://github.com/getbrik/brik) -- the portable CI/CD pipeline system
- [Architecture](docs/architecture.md) -- how Briklab works internally

## License

MIT
