# E2E Validation Campaign -- brik v0.6.0

Started: 2026-05-24
Status: in progress

## Scope

Systematic per-scenario validation of the briklab E2E suite against brik
v0.6.0. For each scenario we run both the GitLab and the Jenkins
pipeline, then compare per-stage logs.

## Acceptance criteria (per stage)

A stage is considered **clean** only when **all four** hold:

1. **Expected behavior** -- the stage produces the documented outcome
   (status, artifacts, downstream gating).
2. **Detail is anomaly-free** -- no swallowed errors, unexplained
   warnings, suspicious fallbacks, or noise.
3. **GitLab and Jenkins are coherent** -- both adapters expose the same
   information, in the same shape, for the same input.
4. **End-user clarity** -- a developer reading the log understands what
   happened **without reading the source code**. Bare reason codes
   (`opt-in-flag-missing`, `reason=context-mismatch`) must be accompanied
   by a one-line human-readable explanation that names the concrete
   condition and the action a user can take.

## Workflow

For each scenario:

1. Run on GitLab via `./scripts/briklab.sh test --gitlab --project <name>`
2. Capture pipeline logs per stage via GitLab API
3. Run on Jenkins via `./scripts/briklab.sh test --jenkins --project <name>`
4. Capture build logs per stage via Jenkins API
5. Stage-by-stage analysis against the four criteria above
6. Document findings in `<scenario>.md`
7. If issues found: fix on the relevant repo's `main` branch (local,
   uncommitted), re-run the scenario, re-verify
8. When clean: mark scenario `done` in the table below; move to next

## Branch and commit strategy

- All fixes land directly on `main` of the relevant repo (brik / briklab
  / other), kept locally uncommitted until the campaign closes.
- At campaign close: group the accumulated diff into logical commits,
  push together with the findings docs.

## Scenarios

| # | Scenario | GitLab | Jenkins | Findings | Status |
|---|----------|--------|---------|----------|--------|
| 1 | node-minimal | ⏳ | ⏳ | [node-minimal.md](node-minimal.md) | in progress |

(Other scenarios will be added as we go.)
