# Briklab - Operations and CLI reference

The complete command reference and runtime troubleshooting for Briklab.

- New to the lab? Start with the [README](../README.md) (prerequisites, `make init`, daily commands).
- Want the internal design? See [architecture.md](architecture.md).
- Want the E2E coverage map or test-behaviour issues? See
  [e2e-coverage.md](e2e-coverage.md) and [e2e-known-issues.md](e2e-known-issues.md).

---

## CLI commands

Infra lifecycle is driven by the root `Makefile` (or `./scripts/infra.sh <command>`
directly). Testing, configuration and reset stay on `./scripts/briklab.sh`.

### Lifecycle (Makefile)

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

> [!TIP]
> **Self-healing by default.** Before touching the lab, `test` runs the readiness
> gate (`preflight`) in `--fix` mode: a stale PAT, a dropped ArgoCD port-forward, a
> `NotReady` k3d node, or a stranded `argocd-application-controller` is repaired
> automatically, then re-verified, so the run proceeds instead of aborting. For
> deploy/gitops scenarios (or `--all`) the ArgoCD + cluster checks are blocking.

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

---

## Nexus repositories

Setup creates 6 hosted repositories for artifact publishing:

| Repository | Format | Endpoint | Usage |
|-----------|--------|----------|-------|
| `brik-npm` | npm | `:8081/repository/brik-npm/` | `npm publish` |
| `brik-maven` | maven2 (release) | `:8081/repository/brik-maven/` | `mvn deploy` |
| `brik-pypi` | pypi | `:8081/repository/brik-pypi/` | `twine upload` / `uv publish` |
| `brik-nuget` | nuget (V3) | `:8081/repository/brik-nuget/` | `dotnet nuget push` |
| `brik-docker` | docker | `:8082/v2/` | `docker push` |
| `brik-cargo` | cargo | `:8081/repository/brik-cargo/` | `cargo publish` (sparse protocol) |

The Docker registry (port 8082) serves TLS issued by the lab CA. A read-only
`brik-cd` account (digest resolution, attestation verification, pull) sits next to
the `admin` write identity; see
[architecture.md - Least-privilege registry identities](architecture.md#5-least-privilege-registry-identities).

---

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

> [!NOTE]
> Image tags are the SoT values in `versions.yml`; check there if a tag above has moved.

---

## Troubleshooting

Runtime problems hit while running the lab. For the GitLab/Jenkins setup quirks the
setup scripts handle by design, see
[architecture.md - Known Gotchas](architecture.md#known-gotchas); for E2E
test-behaviour deep dives, see [e2e-known-issues.md](e2e-known-issues.md).

**GitLab won't start** -- Check Docker Desktop has at least 18 GB RAM allocated. First start takes 3-5 minutes. Check logs: `./scripts/briklab.sh logs gitlab`

**Runner errors (`runner_system_failure` / `image_pull_failure`)** -- Verify `helper_image` is present in the runner's `config.toml`. Check logs: `./scripts/briklab.sh logs runner`. If needed, re-run `./scripts/briklab.sh setup`.

**Jenkins CasC errors** -- Check `./scripts/briklab.sh logs jenkins` for Configuration-as-Code errors. Common issue: plugin not installed. Verify `config/jenkins/plugins.txt` includes all required plugins. To reload CasC without restarting Jenkins, use the `jenkins_reload_casc` helper in `briklab.sh` (only works for CasC YAML changes; env var changes require a full restart).

**Jenkins pipeline can't find Brik library** -- The Brik shared library must be pushed to Gitea before triggering a pipeline. Run `./scripts/briklab.sh setup` to ensure Gitea is configured, then push repos with the E2E test command.

**Gitea shows install page** -- On first start, Gitea requires initial installation. The setup script handles this automatically. If it fails, check logs: `./scripts/briklab.sh logs gitea`

**Nexus slow to start** -- First start takes 2-3 minutes (JVM + plugin initialization). The healthcheck has a 180s start_period. Check logs: `./scripts/briklab.sh logs nexus`

**Nexus Docker push fails (HTTP)** -- Add `"nexus.briklab.test:8082"` to `insecure-registries` in Docker Desktop settings (the host-side `docker push`/`pull` transport stays on the daemon's insecure path; brik consumers verify the lab CA TLS).

**Nexus repository creation fails** -- If `setup` is run before Nexus is fully ready, repository creation may fail. Wait for the healthcheck to pass, then re-run: `./scripts/briklab.sh setup`

**k3d cluster already exists** -- `k3d cluster delete brik && make k3d-start`

**ArgoCD won't sync** -- ArgoCD default polling is ~3 minutes. Use `argocd app get <app> --refresh hard` to force, or run `./scripts/briklab.sh infra-refresh` to renew port-forwards and tokens.

**`brik-deploy` fails with `token signature is invalid`** -- After a lab reset (`make clean` + `make init`) or any k3d/ArgoCD recreation, the ArgoCD signing key rotates and the `ARGOCD_AUTH_TOKEN` stored in GitLab CI variables goes stale. The `test` self-heal only refreshes the local token in `.env`; run `./scripts/briklab.sh infra-refresh` to propagate a fresh token to the GitLab CI variables (and Jenkins), then re-run the deploy/gitops scenarios. Full write-up in [e2e-known-issues.md](e2e-known-issues.md).

**E2E timeout** -- Use `--batch-size 4` to limit concurrent pipelines. Check runner saturation with `./scripts/briklab.sh logs runner`. Run `./scripts/briklab.sh infra-refresh` if tokens expired.

**Reset between E2E runs** -- `./scripts/briklab.sh reset --gitlab` cleans repos, k8s namespaces, ArgoCD apps, and Nexus artifacts.

### Known issue: runner saturation

| Issue | Affected scenarios | Root cause |
|-------|-------------------|------------|
| Runner saturation | various (GitLab timeout) | Single runner overwhelmed by concurrent pipelines. Mitigate with `--batch-size` |
