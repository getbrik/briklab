# Briklab E2E - Known Issues

Living record of E2E behaviours that are not bugs in the brik runtime but stem
from the lab's own state or third-party tooling. Each entry says what you see,
why it happens, and how it is handled.

---

## Jenkins: push-triggered Multibranch scenarios need an explicit scan after a lab reset

**Status:** resolved in the suite (2026-06-06).

**Symptom**

A push-driven Jenkins scenario (`workflow-trunk-main`, `workflow-trunk-tag`)
times out:

```
Triggering via git push (ref: main)...
Push SHA: 8e61511b...
Waiting for build triggered by SHA 8e61511b...
[ERROR] No build found for SHA 8e61511b... after 300s
```

All API-triggered scenarios (node-full, node-complete, node-deploy-gitops,
node-plan-tag, node-full-cve, the rollback) pass. Only the scenarios that rely
on `git push -> Jenkins build` fail.

**Root cause**

`node-workflow-trunk` is a `WorkflowMultiBranchProject`. A push only produces a
build if Jenkins is notified to index the repository. In this lab there is no
such notification after a reset:

- The Jenkins job has **no `PeriodicFolderTrigger`** (no scheduled scan).
- The freshly recreated Gitea repo has **no webhook**. The Jenkins gitea-plugin
  is configured with `manageHooks: true`, but it manages hooks at the **org**
  level, and `brik` is a Gitea **user**, not an organisation, so no per-repo
  webhook is ever created (verified: a manual scan discovers branches/tags but
  still registers no webhook).
- Neither `setup` nor the push step triggers a scan.

So after a `make clean` + `make init` (or any repo recreation) the multibranch
job is never re-indexed, and the push to `main` is never built. Tag scenarios
fail too, because the tag sub-job is only discovered by a scan.

This is independent of the brik runtime and of the `Makefile`/`infra.sh`
lifecycle split: the pipeline itself is fine (a manual "Scan Now" discovers
`main` + `v0.1.0` in ~5s and the branch auto-builds to SUCCESS).

**Resolution**

`jenkins-test.sh` now triggers an explicit Multibranch scan immediately after
the push, via `e2e.jenkins.scan_multibranch` (POST `/job/<job>/build`):

- branch push (`main`): the scan indexes the new commit and the
  `BranchDiscoveryTrait` auto-builds the branch;
- tag push (`v0.2.0`): the scan makes the tag sub-job appear, then the existing
  tag step issues the explicit `/build`.

Validated live: `workflow-trunk-main` 9/9, `workflow-trunk-tag` 10/10.

**If it still times out**

Confirm the job indexed and re-run the scenario:

```bash
curl -s -u "admin:${JENKINS_ADMIN_PASSWORD}" \
  "http://jenkins.briklab.test:9090/job/node-workflow-trunk/api/json" \
  | jq -r '[.jobs[]?.name] | join(",")'   # expect: main,v0.1.0,...
```

A full `make init` on a clean lab also re-establishes the job state.

---

## GitLab: `brik-deploy` fails with `token signature is invalid` after a lab reset

**Status:** operational (run `infra-refresh`).

**Symptom**

`brik-deploy` fails on `argocd app sync` even though the GitOps manifests were
pushed cleanly:

```
INFO   deploy  manifests pushed successfully to .../config-deploy-gitops.git
ERROR  deploy  argocd app sync failed for: brik-e2e-gitops
{"level":"fatal","msg":"... invalid session: token signature is invalid ..."}
```

**Root cause**

A lab reset rotates the ArgoCD server signing key, invalidating previously
issued tokens. The `test` self-heal (`preflight --fix`) refreshes the **local**
`ARGOCD_AUTH_TOKEN` in `.env`, but only `infra-refresh` **propagates** a fresh
token to the GitLab group CI variables (`briklab.recover.gitlab_ci_vars`). The
job runs with the stale CI-variable token.

**Resolution**

```bash
./scripts/briklab.sh infra-refresh   # regenerate + propagate the token
./scripts/briklab.sh test --gitlab --project node-deploy-gitops
```

Run `infra-refresh` before deploy/gitops scenarios whenever the lab was reset
between runs.

---

## Infrastructure Referential and TLS Setup

**Status:** permanent (referential-based architecture introduced in 2026-06).

**What it is**

The lab generates an infrastructure referential instance at `data/infra/` during
setup. This instance declares all endpoints (Nexus, Gitea, ArgoCD), TLS trust
bundles (lab CA certificate), signing keys, allowed signers for commit verification,
and organizational policy files. It is mounted read-only at `/etc/brik/infra` in all
CI jobs and forwarded to stage containers on Jenkins.

The referential is the single source of truth for the lab's security posture:
every endpoint URL, every TLS relationship, every credential reference, and every
gate comes from this instance. This replaces the former ad-hoc environment
variables (BRIK_COSIGN_*, BRIK_SSH_STRICT_HOST_KEY, BRIK_KUBECTL_OPTS,
BRIK_POLICY_URL, ARGOCD_SERVER/ARGOCD_INSECURE).

**TLS certificates and the lab CA**

The lab CA and per-service leaf certificates are generated once by `ca.sh` and
stored in `data/ca/`. The CA is never rotated by the setup scripts (only on
explicit deletion), so principals pinned in allowed_signers and the cosign public
key remain stable across lab lifecycle restarts.

The CA certificate is distributed to all consumers via the referential's
`trust/ca/<hostname>/ca.crt` convention:
- Job containers mount the referential and verify TLS via these bundles (Gitea, Nexus docker registry, ArgoCD)
- The Jenkins JVM truststore is imported once by `scripts/lib/auth/jenkins-trust.sh`
- The system git config is updated once to trust the lab CA for `git` operations

**After CA or leaf certificate recreation**

If the CA or its leaves are manually deleted or regenerated (e.g., by editing
the certificate SAN set), you must:
1. Delete the old certificates: `rm -rf data/ca/`
2. Re-run setup: `make clean && make init` or just `./scripts/briklab.sh setup`
3. Restart Jenkins to re-import the new CA into the JVM truststore: `make stop && make start`
4. Run `infra-refresh` to propagate the new tokens and refresh the referential instance

---

## Registry Identity and Least-Privilege Access

**Status:** permanent (identity scoping introduced in 2026-06, P-lab defaults).

**What it is**

The Nexus Docker registry (port 8082) carries two identities:
- **brik-cd** (read-only, role `brik-cd-read`, created by `setup/nexus.sh`):
  digest resolution, image pull, attestation verification. Password in
  `.env` as `NEXUS_CD_PASSWORD`.
- **admin** (write): publishing, attaching signed referrers, promoting
  images.

The referential's per-environment bindings declare the `registry-read`
credential (the bindings are CD-scope); which account the `BRIK_REGISTRY_*`
variables actually carry depends on the delivery context below.

**Enforcement**

- **GitLab**: the group-level `BRIK_REGISTRY_*` variables carry the admin
  (write) identity, which the CI jobs need (attest attaches referrers,
  promote copies channels). The keystone scenarios scope `BRIK_REGISTRY_*`
  to **brik-cd** on the deploy environments (staging/production/dev) as
  project environment-scoped variables (`e2e.gitlab.scope_cd_registry_creds`):
  the CD jobs declare their environment, so the read-only values shadow the
  group variable there.
- **Jenkins**: CasC sets `BRIK_REGISTRY_USER/PASSWORD` to **brik-cd** as the
  default for every container, and carries the write identity as
  `BRIK_SIGNING_REGISTRY_USER/PASSWORD`; the brik shared library remaps it
  onto `BRIK_REGISTRY_*` for the container-scan stage only (at the withEnv
  level -- `docker.inside()` re-injects build globals as trailing `-e`
  flags, so an env-file remap alone would lose).

**If access is denied**

```bash
# Probe the read-only account directly (read must pass, write must be denied)
curl -s -o /dev/null -w "%{http_code}\n" --cacert data/ca/ca.crt \
  -u "brik-cd:${NEXUS_CD_PASSWORD}" \
  "https://nexus.briklab.test:8082/v2/brik/node-deploy-channel/tags/list"

# GitLab: list the project's environment-scoped variables
curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
  "http://gitlab.briklab.test:8929/api/v4/projects/<id>/variables" | jq '.'
```
