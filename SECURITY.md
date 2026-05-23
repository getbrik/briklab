# Security Policy

## Scope

`briklab` is the **demonstration and test lab** for the Brik CI/CD platform. It provisions a local Docker-based environment (GitLab CE, Jenkins, Nexus, Gitea, k3d, ArgoCD) used to run end-to-end tests of Brik against multiple platforms.

This is **not** a production system. Default credentials are deliberately weak and documented for ease of setup. Do not expose this lab on a public network.

## Reporting a Vulnerability

Security issues in briklab that could affect users outside the lab boundary (for example, scripts that escape the lab and modify host system files, or that exfiltrate host credentials) should be reported privately.

1. Go to https://github.com/getbrik/briklab/security/advisories/new
2. Provide reproduction steps and impact.

Do not open public issues for security reports.

## In Scope

- Lab orchestration scripts under `scripts/`.
- `docker-compose.yml` and `docker-compose.level2.yml`.
- Configuration files under `config/`.
- Anything in the lab that interacts with the host filesystem, host network beyond `localhost`, or host secrets.

## Out of Scope

- Default credentials for the lab services (GitLab root, Jenkins admin, Nexus admin, Gitea admin). These are documented and intentional for a local lab.
- Vulnerabilities in the upstream services themselves (GitLab CE, Jenkins, Nexus, Gitea, ArgoCD, k3d). Report upstream.
- Any issue that requires running briklab outside its intended local-laptop usage.

## Disclosure Policy

Coordinated disclosure. We will issue a GitHub Security Advisory (GHSA) when applicable.
