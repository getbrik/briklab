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

## What makes Briklab different

### 🏗️ Pre-wired infrastructure

GitLab PAT, Runner registration, Gitea PAT, Jenkins Configuration-as-Code + Job DSL, Nexus repository creation (npm, Maven, PyPI, NuGet, Docker, Cargo), lab CA + infrastructure referential, k3d cluster, ArgoCD install + port-forwards, OpenBAO Transit KMS, SSH target container. All scripted, all idempotent, all under `scripts/lib/setup/`.

### 🧪 E2E framework

A focused suite of orchestrator-parity and real-deploy scenarios per platform, with single-scenario targeting (`--project <name>`), batching (`--batch-size 4`), and listing (`--list`). Built on reusable Bash libraries under `scripts/lib/e2e/lib/`. Per-stage, per-stack, planner and findings behavior is validated upstream by the `brik` repo's contract/unit/integration suites, so this lab stays small and fast.

### ⚓ Real deploy targets

The deploy stage is validated against actual infrastructure, not mocks: GitOps via ArgoCD (`node-deploy-gitops`), a 3-step rollback chain (`node-deploy-rollback`), and digest-pinned CD with signed evidence and channel promotion (`node-deploy-channel`, `node-deploy-signed`, `cd-promote`). The other deploy targets (Kubernetes, Helm, SSH, Docker Compose) have their dispatch and argument handling covered by the `brik` repo's integration tests, so their fixtures no longer live in the lab.

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

> [!NOTE]
> GitLab takes 3-5 minutes on first start. Jenkins builds a custom Docker image on first start. Nexus takes 2-3 minutes. The script waits automatically.

## Services and Security

| Service | URL | Credentials | Transport |
|---------|-----|-------------|-----------|
| GitLab UI | http://gitlab.briklab.test:8929 | `root` / `Brik-Gtlb-2026` | HTTP |
| GitLab SSH | `ssh://git@gitlab.briklab.test:2222` | - | SSH |
| GitLab Runner | - | - | Docker socket |
| Gitea UI | https://gitea.briklab.test:3000 | `brik` / `Brik-Gitea-2026` | TLS (custom-ca) |
| Jenkins UI | http://jenkins.briklab.test:9090 | `admin` / `Brik-Jenkins-2026` | HTTP |
| Nexus UI | http://nexus.briklab.test:8081 | `admin` / `Brik-Nexus-2026` | HTTP |
| Nexus Docker | https://nexus.briklab.test:8082 | read: `brik-cd` / write: `admin` | TLS (custom-ca) |
| ArgoCD UI | https://argocd.briklab.test:9080 | `admin` / (dynamic, see `k3d-start` output) | TLS (custom-ca) |
| OpenBAO | http://openbao.briklab.test:8200 | root token from `.env` | HTTP (dev-mode) |
| k3d (k3s) | localhost:6443 | - | - |
| SSH Target | internal only | `deploy` / SSH key | SSH |

Default credentials are defined in `.env`. Modify them **before** the first `init`.

> [!IMPORTANT]
> **TLS and certificate trust.** Gitea, the Nexus docker connector (port 8082), and
> ArgoCD serve TLS certificates issued by the lab internal CA (`data/ca/ca.crt`, minted
> by `scripts/lib/setup/ca.sh`). Trust that file in your browser or pass it to curl
> (`--cacert data/ca/ca.crt`). The brik referential instance (generated at `data/infra/`)
> distributes the CA bundle to all CI jobs as the `custom-ca` trust material, and the lab
> CLI imports it into the Jenkins JVM truststore and system git config.

> [!IMPORTANT]
> **Registry access control.** The Docker registry (Nexus port 8082) uses least-privilege
> identities per context. The CD pipelines resolve, verify and pull with the read-only
> `brik-cd` account: on GitLab the keystones scope `BRIK_REGISTRY_*` to brik-cd on the
> deploy environments (the CI jobs keep the group-level write identity), and on Jenkins
> brik-cd is the CasC default with the write identity carried as `BRIK_SIGNING_REGISTRY_*`
> and delivered to the signing stage only.

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

The full command reference (testing flags, reset, preflight, maintenance,
monitoring, lifecycle), the Nexus repository map, and runtime troubleshooting
live in **[docs/operations.md](docs/operations.md)**.

## E2E Testing

Briklab runs a small, irreducible set of end-to-end scenarios that need a real
orchestrator or real deploy infrastructure: **12 on GitLab, 10 on Jenkins**.
Everything else -- per-stage logic, per-stack dispatch, the planner, findings
normalization -- is validated upstream by the `brik` repo's
contract/unit/integration suites and by `brik-images` smoke tests, so this lab
stays fast.

The scenarios span the full CI flow (orchestrator parity), GitOps deploy +
rollback against a real ArgoCD, digest-pinned CD with signed evidence (ssh and
OpenBAO Transit KMS), channel promotion with immutability enforcement, and the
trunk-based workflow filter (push / tag / MR).

- The authoritative coverage map -- which spec proves what, which scenario is
  live-only, plus the test-validity audit -- is in
  [docs/e2e-coverage.md](docs/e2e-coverage.md).
- E2E test-behaviour issues (multibranch scan after reset, token rotation, TLS
  and referential setup) are in [docs/e2e-known-issues.md](docs/e2e-known-issues.md).

```bash
./scripts/briklab.sh test --gitlab --all                      # full GitLab suite
./scripts/briklab.sh test --gitlab --project node-deploy-channel
./scripts/briklab.sh test --gitlab --list
```

Test project fixtures live in `test-projects/` (each has a `brik.yml` and
platform-specific CI config). The lab keeps only the projects that need a **live
orchestrator** or **real external infrastructure**; see
[docs/e2e-coverage.md](docs/e2e-coverage.md) for the full project disposition.

## Coverage in numbers

- ✅ **2** CI platforms validated end-to-end (GitLab CE + Jenkins, parity scenarios on both)
- ✅ **22** live E2E scenarios (12 GitLab + 10 Jenkins) -- the irreducible set that needs a real orchestrator or real infrastructure; per-stage/stack/planner logic is owned by `brik/spec`
- ✅ **6** Nexus repository formats validated (npm, Maven, PyPI, NuGet, Docker, Cargo)
- ✅ **GitOps via ArgoCD** validated live (sync + rollback, TLS against the lab CA); Kubernetes, Helm, SSH and Docker Compose dispatch are covered by `brik`'s integration suites
- ✅ **Digest-pinned CD** with signed evidence: channel promotion (`oras cp -r`), ssh/KMS commit signing verified against allowed_signers, least-privilege registry identities
- ✅ **18** reusable Bash libraries under `scripts/lib/e2e/lib/`
- ✅ **1** rollback chain (3-step commit chain verifies ArgoCD rolls back to the previous image)
- ✅ **Idempotent setup** -- every step under `scripts/lib/setup/` re-runs safely; `briklab.sh setup` reconciles without `clean`

## Documentation

| Doc | What it covers |
|-----|----------------|
| [docs/operations.md](docs/operations.md) | Full CLI reference, Nexus repositories, cleanup, runtime troubleshooting |
| [docs/architecture.md](docs/architecture.md) | Internal design, components, referential, setup flow, directory structure, `.env` reference |
| [docs/e2e-coverage.md](docs/e2e-coverage.md) | Coverage map: which spec proves what, the irreducible live scenario set, test-validity audit |
| [docs/e2e-known-issues.md](docs/e2e-known-issues.md) | Living record of E2E behaviours rooted in lab state or third-party tooling |

## Related

- [Brik](https://github.com/getbrik/brik) -- the portable CI/CD pipeline system

## Transparency Notice

We use AI-assisted development ([Claude Code](https://claude.ai/code) + [ECC](https://github.com/affaan-m/ECC)) to accelerate implementation:

- Every contribution (human or AI-generated) follows the same quality gates: code review, test coverage, E2E testing, and CI checks.
- AI-generated code is not perfect. Regular refactoring passes address its shortcomings, and the overall productivity gains are significant.

## License

[MPL-2.0](LICENSE)
