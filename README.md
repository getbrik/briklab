# Briklab

Local Docker environment for testing the full Brik cycle: write `brik.yml` → compile → render → run on real CI platforms.

## Architecture

| Level | Components | Estimated RAM |
|-------|-----------|---------------|
| **MVP** | GitLab CE + Runner + Registry | ~4 GB |
| **Full** | + Gitea + Jenkins + k3d/ArgoCD | ~8 GB |

### Services

| Service | Image | Port | Level |
|---------|-------|------|-------|
| GitLab CE | `gitlab/gitlab-ce:18.10.1-ce.0` | 8929, 2222 | MVP |
| GitLab Runner | `gitlab/gitlab-runner:alpine3.21-bleeding` | - | MVP |
| Docker Registry | `registry:3.0` | 5050 | MVP |
| Gitea | `gitea/gitea:1.25.5` | 3000, 222 | Full |
| Jenkins | `jenkins/jenkins:2.541.3-lts-jdk21` | 9090, 50000 | Full |
| k3d (k3s) | via CLI | 6443, 8080 | Full |
| ArgoCD | via kubectl | 9080 | Full |

> **macOS note:** the registry uses port 5050 by default because AirPlay Receiver occupies port 5000.

### Access URLs

**MVP (available after `init`):**

| Service | URL | Credentials |
|---------|-----|-------------|
| GitLab UI | http://localhost:8929 | `root` / `Briklab-2026!` |
| GitLab SSH | `ssh://git@localhost:2222` | SSH key |
| GitLab API | http://localhost:8929/api/v4/ | Header `PRIVATE-TOKEN: <GITLAB_PAT>` |
| Docker Registry | http://localhost:5050/v2/_catalog | - |

**Level 2 (available after `init --full`):**

| Service | URL | Credentials |
|---------|-----|-------------|
| Gitea | http://localhost:3000 | Configure on first access |
| Jenkins | http://localhost:9090 | `admin` / `Brik-Jenkins-2026!` |
| ArgoCD | https://localhost:9080 | `admin` / see `setup-k3d.sh` |

> Default credentials are defined in `.env`. Modify them **before** the first `init`.

## Prerequisites

```bash
# Docker Desktop (required)
# https://www.docker.com/products/docker-desktop/

# Recommended tools
brew install bash jq yq

# Level 2 - Kubernetes + GitOps
brew install k3d kubectl helm kustomize argocd
```

### Network configuration

Add to `/etc/hosts`:

```
127.0.0.1  gitlab.briklab.local registry.briklab.local
127.0.0.1  gitea.briklab.local jenkins.briklab.local argocd.briklab.local
```

Add to Docker Desktop configuration (Settings > Docker Engine):

```json
{
  "insecure-registries": ["localhost:5050"]
}
```

## Quick start

### Automated initialization (recommended)

A single command to install everything:

```bash
./scripts/briklab.sh init
```

This command automatically chains the following 5 steps:

1. **Prerequisites check** - Docker, jq
2. **Preparing `.env`** - copies `.env.example` → `.env` if missing
3. **Starting containers** - GitLab CE, Runner, Registry on the `brik-net` network
4. **GitLab + Runner configuration** - see [details below](#what-briklab-setup-does)
5. **Smoke tests** - verifies that each component responds

### Manual initialization

```bash
# 1. Copy and edit variables
cp .env.example .env
# Modify passwords in .env if desired

# 2. Start the MVP
./scripts/briklab.sh start

# 3. Configure GitLab and the runner
./scripts/briklab.sh setup

# 4. Verify
./scripts/briklab.sh smoke-test
```

## What `briklab.sh setup` does

The `setup` command orchestrates the initial configuration by calling two scripts.

### `setup-gitlab.sh` - GitLab configuration

1. **Wait for GitLab** - polls `/users/sign_in` until HTTP 200 (the `/-/readiness` endpoint no longer exists in GitLab 18.x)
2. **Root password configuration** - via `gitlab-rails runner`, applies the password defined in `GITLAB_ROOT_PASSWORD`, disables forced password change on first login (`password_automatically_set = false`, `password_expires_at = nil`). GitLab 18.x requires a strong password (the default `Briklab-2026!` meets this requirement)
3. **Personal Access Token creation** - runs a Ruby script via `gitlab-rails runner` (passed via stdin to avoid shell escaping issues with `create!`). Scopes: `api`, `read_repository`, `write_repository`. Validity: 1 year. The token is saved in `.env` as `GITLAB_PAT`
4. **`brik-test` project creation** - REST API call `POST /api/v4/projects` with the PAT, public project initialized with a README
5. **Runner registration token retrieval** - via `gitlab-rails runner` (reads `runners_registration_token` from settings). Saved in `.env` as `GITLAB_RUNNER_TOKEN`

### `setup-runner.sh` - Runner registration

1. **Registration** - `gitlab-runner register` in non-interactive mode with:
   - Executor: `docker`
   - Default image: `alpine:3.21`
   - Network: `brik-net` (same network as GitLab, resolution via static IP)
   - Extra hosts: `gitlab.briklab.local:172.20.0.10`
   - Tags: `docker`, `brik`
2. **Adding `helper_image`** - the bleeding edge runner (pre-release) attempts to pull an unpublished helper (`arm64-v18.11.0`). The script injects `helper_image = "gitlab/gitlab-runner-helper:alpine3.21-arm-bleeding"` into `config.toml` via `sed` to force a compatible image
3. **Verification** - checks that `config.toml` contains the `helper_image`

### `setup-jenkins.sh` - Jenkins configuration (Level 2)

Called only if Jenkins is running (`--full`). Installs plugins listed in `config/jenkins/plugins.txt` via `jenkins-plugin-cli`.

## Commands

| Command | Description |
|---------|-------------|
| `briklab.sh init [--full]` | Automated first launch (start + setup + smoke-test) |
| `briklab.sh start [--full]` | Start the briklab (MVP or full) |
| `briklab.sh stop` | Stop all containers |
| `briklab.sh restart [--full]` | Restart |
| `briklab.sh status` | Service status and URLs |
| `briklab.sh logs <service>` | Service logs (gitlab, runner, registry, gitea, jenkins) |
| `briklab.sh setup` | GitLab + Runner configuration (idempotent) |
| `briklab.sh k3d-start` | k3d cluster + ArgoCD |
| `briklab.sh k3d-stop` | Destroy the k3d cluster |
| `briklab.sh clean` | Delete all data (irreversible, requires confirmation) |
| `briklab.sh smoke-test` | Verify each component |

## Smoke tests

The `smoke-test.sh` script checks each component and displays a PASS / FAIL / SKIP result:

| Test | Method | Expected |
|------|--------|----------|
| Docker daemon | `docker info` | Accessible |
| brik-net network | `docker network inspect` | Exists |
| GitLab HTTP | `curl /users/sign_in` | HTTP 200 |
| GitLab API v4 | `curl /api/v4/version` | HTTP != 000 (401 = OK, auth required) |
| Runner container | `gitlab-runner --version` | Executable |
| Runner registered | `grep "url" config.toml` | Present |
| Registry v2 API | `curl /v2/` | HTTP 200 |
| Registry catalog | `curl /v2/_catalog` | HTTP 200 |
| Gitea / Jenkins / k3d | Respective tests | SKIP if not running |

## Mapping to Brik milestones

| Milestone | Infrastructure used |
|-----------|---------------------|
| M1–M4 | Local Rust only |
| **M5 - GitLab adapter** | **GitLab CE + Runner: push `.gitlab-ci.yml` → pipeline executed** |
| M6 - Bash Runtime | Runner Docker executor with bash 5+, jq, yq |
| Phase 5 - GitOps | k3d + ArgoCD + Gitea manifest repo |

## Structure

```
briklab/
├── docker-compose.yml          # MVP (GitLab + Runner + Registry)
├── docker-compose.level2.yml   # Extension (Jenkins + Gitea)
├── .env.example                # Variables template
├── scripts/
│   ├── briklab.sh              # Main CLI (init, start, stop, setup, ...)
│   ├── setup-gitlab.sh         # PAT + project + runner token via rails runner
│   ├── setup-runner.sh         # Runner registration + helper_image
│   ├── setup-jenkins.sh        # Jenkins plugins via CLI
│   ├── setup-k3d.sh            # k3d cluster + ArgoCD
│   └── smoke-test.sh           # Component verification
├── config/
│   ├── registry/config.yml     # Registry HTTP config
│   └── jenkins/
│       ├── plugins.txt         # Required plugins
│       └── casc.yaml           # Jenkins Configuration-as-Code
└── data/                       # Persistent volumes (gitignored)
```

## Docker network

`brik-net` network (172.20.0.0/16) with static IPs:

| Service | IP |
|---------|----|
| GitLab | 172.20.0.10 |
| Runner | 172.20.0.11 |
| Registry | 172.20.0.12 |
| Gitea | 172.20.0.20 |
| Jenkins | 172.20.0.21 |

The runner uses `extra_hosts` to resolve `gitlab.briklab.local` to GitLab's static IP within the Docker network, allowing CI jobs to clone repos via the hostname.

## `.env` variables

**GitLab (MVP):**

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_ROOT_PASSWORD` | `Briklab-2026!` | GitLab root password |
| `GITLAB_HTTP_PORT` | `8929` | GitLab HTTP port |
| `GITLAB_SSH_PORT` | `2222` | GitLab SSH port |
| `GITLAB_HOSTNAME` | `gitlab.briklab.local` | GitLab hostname |
| `GITLAB_PAT` | *(generated by setup)* | GitLab Personal Access Token |
| `GITLAB_RUNNER_TOKEN` | *(generated by setup)* | Runner registration token |

**Docker Registry (MVP):**

| Variable | Default | Description |
|----------|---------|-------------|
| `REGISTRY_PORT` | `5050` | Docker Registry port |

**Gitea (Level 2):**

| Variable | Default | Description |
|----------|---------|-------------|
| `GITEA_HTTP_PORT` | `3000` | Gitea HTTP port |
| `GITEA_SSH_PORT` | `222` | Gitea SSH port |
| `GITEA_HOSTNAME` | `gitea.briklab.local` | Gitea hostname |

**Jenkins (Level 2):**

| Variable | Default | Description |
|----------|---------|-------------|
| `JENKINS_HTTP_PORT` | `9090` | Jenkins HTTP port |
| `JENKINS_AGENT_PORT` | `50000` | Jenkins agent port |
| `JENKINS_HOSTNAME` | `jenkins.briklab.local` | Jenkins hostname |
| `JENKINS_ADMIN_PASSWORD` | `Brik-Jenkins-2026!` | Jenkins admin password |

**k3d / ArgoCD (Level 2):**

| Variable | Default | Description |
|----------|---------|-------------|
| `K3D_API_PORT` | `6443` | k3d Kubernetes API port |
| `K3D_HTTP_PORT` | `8080` | k3d HTTP ingress port |
| `ARGOCD_PORT` | `9080` | ArgoCD UI port |
| `ARGOCD_HOSTNAME` | `argocd.briklab.local` | ArgoCD hostname |

**Docker network:**

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_NETWORK` | `brik-net` | Docker network name |
| `DOCKER_SUBNET` | `172.20.0.0/16` | Docker network subnet |

## Troubleshooting

### GitLab won't start
- Check Docker Desktop resources (4 GB RAM minimum)
- Check logs: `./scripts/briklab.sh logs gitlab`
- First start: be patient, GitLab takes 3-5 minutes to initialize its database

### Runner: `runner_system_failure` or `image_pull_failure`
- Check that `helper_image` is present in the runner's `config.toml`
- If the helper image doesn't exist, change `GITLAB_RUNNER_HELPER_IMAGE` in `.env` and rerun `setup`
- Check logs: `./scripts/briklab.sh logs runner`

### Port 5000 already in use (macOS)
AirPlay Receiver occupies port 5000 on macOS. The briklab uses port 5050 by default. To disable AirPlay: Settings > General > AirDrop & Handoff > AirPlay Receiver → uncheck.

### Registry unreachable
- Check `"insecure-registries": ["localhost:5050"]` in Docker Desktop > Settings > Docker Engine
- Test: `curl http://localhost:5050/v2/`

## Cleanup and uninstallation

### Simple stop (data preserved)

Stops containers without removing volumes. On next `start`, everything restarts with data intact (GitLab projects, pipelines, registry images, etc.).

```bash
./scripts/briklab.sh stop
```

### Data deletion (irreversible)

Deletes all persistent volumes (`data/`). Containers are stopped first. Interactive confirmation is required.

```bash
./scripts/briklab.sh clean
```

**What is deleted:**
- GitLab database (projects, users, pipelines, CI/CD)
- GitLab configuration (generated `gitlab.rb`, certificates)
- GitLab logs
- Runner configuration (`config.toml`, registration token)
- Images stored in the registry
- Gitea data (repos, users)
- Jenkins configuration and jobs

**What is preserved:**
- Briklab configuration files (`docker-compose.yml`, `config/`, `scripts/`)
- The `.env` file (passwords, PAT - but the PAT will no longer be valid after clean)
- Downloaded Docker images (GitLab, Runner, etc.)

After a `clean`, run `init` again to recreate everything:

```bash
./scripts/briklab.sh init
```

### Full removal (containers + images + network)

To remove everything including downloaded Docker images and the network:

```bash
# 1. Stop and delete data
./scripts/briklab.sh clean

# 2. Remove Docker images (~2 GB for MVP)
docker rmi gitlab/gitlab-ce:18.10.1-ce.0
docker rmi gitlab/gitlab-runner:alpine3.21-bleeding
docker rmi gitlab/gitlab-runner-helper:alpine3.21-arm-bleeding
docker rmi registry:3.0
docker rmi alpine:3.21

# 3. Remove the Docker network (if still present)
docker network rm brik-net 2>/dev/null

# 4. (Optional) Remove .env to start fresh
rm .env
```

### k3d cluster destruction (Level 2)

```bash
./scripts/briklab.sh k3d-stop
```

This removes the Kubernetes cluster and associated ArgoCD resources. Docker containers (GitLab, Registry, etc.) are not affected.

### Precautions

- **Back up `.env` before a `clean`** - it contains `GITLAB_PAT` and `GITLAB_RUNNER_TOKEN` which cannot be recovered after deleting the GitLab database
- **Do not manually delete `data/`** while containers are running - use `clean` which stops services first
- **Docker images remain in local cache** after a `clean` - the next `init` will be much faster (no download needed)
- **`clean` does not affect the k3d cluster** - use `k3d-stop` separately if needed
