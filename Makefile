# Briklab - infra lifecycle entrypoint.
# Thin wrapper over scripts/infra.sh. Testing/config live in scripts/briklab.sh.
INFRA := ./scripts/infra.sh

.PHONY: help init start stop restart clean clean-force \
        k3d-start k3d-stop versions versions-check

help: ## Show this help
	@$(INFRA) help

init: ## First launch (start + setup + k3d + smoke-test)
	@$(INFRA) init

start: ## Start all containers
	@$(INFRA) start

stop: ## Stop all containers
	@$(INFRA) stop

restart: ## Stop + start
	@$(INFRA) restart

clean: ## Delete all data and volumes (prompts for confirmation)
	@$(INFRA) clean

clean-force: ## Delete all data and volumes (no prompt)
	@$(INFRA) clean --yes

k3d-start: ## Create k3d cluster + install ArgoCD
	@$(INFRA) k3d-start

k3d-stop: ## Destroy the k3d cluster
	@$(INFRA) k3d-stop

versions: ## Regenerate versions.env + Jenkins plugins + image lock from versions.yml
	@$(INFRA) versions

versions-check: ## Fail if any generated artifact drifts from versions.yml
	@$(INFRA) versions --check
