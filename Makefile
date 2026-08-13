# GrowthBook self-hosted — local dev workflow
# Uses docker compose if available, otherwise podman compose.

ENGINE := $(shell command -v docker >/dev/null 2>&1 && echo "docker compose" || echo "podman compose")

.PHONY: help up down ps logs seed setup reset

help:
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Start GrowthBook (UI http://localhost:3000, API http://localhost:3100)
	$(ENGINE) up -d

down: ## Stop the stack (keeps data volumes)
	$(ENGINE) down

ps: ## Show running containers
	$(ENGINE) ps

logs: ## Follow GrowthBook logs
	$(ENGINE) logs -f growthbook

seed: ## Provision admin account, org and flags (idempotent, safe to re-run)
	bash scripts/seed-growthbook.sh

setup: up seed ## Start + provision everything (use this on a fresh clone)

reset: ## Stop and wipe all GrowthBook data (clean-slate for another clone)
	$(ENGINE) down -v