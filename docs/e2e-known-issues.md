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
