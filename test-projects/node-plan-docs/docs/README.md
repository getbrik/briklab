# node-plan-docs

E2E fixture for L.1 scenario 2: a docs-only incremental commit.

The suite triggers this project with the `docs-only` ref, which the
harness handles as a two-phase push (baseline with `-o ci.skip`, then a
commit touching only `docs/`). The dynamic-pipeline planner then sees a
docs-only diff and skips the build/lint/sast/scan/test grid -- only the
report aggregator (`brik-notify`) runs in the child pipeline.
