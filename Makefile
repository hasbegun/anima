.PHONY: setup get-secret bootstrap seed test test-phase1 test-phase2 test-phase3 test-phase4 \
       backup restore logs logs-all status stop down clean all

# ──────────────────────────────────────────────
# Phase 1: Start services
# ──────────────────────────────────────────────
setup:
	docker compose up thunderid-setup 2>&1 | tee setup-output.txt
	docker compose up -d thunderid mailslurper
	@echo "Waiting for ThunderID to be healthy..."
	@until curl -sf --insecure https://localhost:8090/.well-known/openid-configuration > /dev/null 2>&1; do \
		sleep 2; echo "  waiting..."; \
	done
	@echo ""
	@echo "ThunderID is ready!"
	@echo "  Console: https://localhost:8090/console"
	@echo "  Gate:    https://localhost:8090/gate"
	@echo "  Mail:    http://localhost:4436"
	@echo ""
	@echo "IMPORTANT: Check setup-output.txt for admin password and Direct Auth Secret"

# ──────────────────────────────────────────────
# Retrieve Direct Auth Secret (needed for bootstrap)
# ──────────────────────────────────────────────
get-secret:
	@docker compose exec thunderid cat config/secrets/direct_auth_secret

# ──────────────────────────────────────────────
# Phase 2: Bootstrap tenants, resource servers, roles
# ──────────────────────────────────────────────
bootstrap:
	$(eval DIRECT_AUTH_SECRET ?= $(shell docker compose exec thunderid cat config/secrets/direct_auth_secret 2>/dev/null))
	cd bootstrap && pip install -r requirements.txt -q && \
		DIRECT_AUTH_SECRET="$(DIRECT_AUTH_SECRET)" python bootstrap.py

# ──────────────────────────────────────────────
# Phase 2b: Seed users into tenants
# ──────────────────────────────────────────────
seed:
	$(eval DIRECT_AUTH_SECRET ?= $(shell docker compose exec thunderid cat config/secrets/direct_auth_secret 2>/dev/null))
	cd bootstrap && \
		DIRECT_AUTH_SECRET="$(DIRECT_AUTH_SECRET)" python seed_users.py

# ──────────────────────────────────────────────
# Testing
# ──────────────────────────────────────────────
test:
	bash scripts/test-all.sh

test-phase1:
	bash scripts/test-phase1.sh

test-phase2:
	bash scripts/test-phase2.sh

test-phase3:
	bash scripts/test-phase3.sh

test-phase4:
	bash scripts/test-phase4.sh

# ──────────────────────────────────────────────
# Operations
# ──────────────────────────────────────────────
backup:
	bash scripts/backup-db.sh

restore:
	@echo "Usage: make restore FILE=backups/thunderid_YYYYMMDD.tar.gz"
	bash scripts/restore-db.sh $(FILE)

logs:
	docker compose logs -f thunderid

logs-all:
	docker compose logs -f

status:
	docker compose ps
	@echo ""
	@curl -sf --insecure https://localhost:8090/.well-known/openid-configuration > /dev/null 2>&1 \
		&& echo "ThunderID is healthy" \
		|| echo "ThunderID is not responding"

# ──────────────────────────────────────────────
# Lifecycle
# ──────────────────────────────────────────────
stop:
	docker compose stop

down:
	docker compose down

clean:
	docker compose down -v
	rm -f setup-output.txt
	@echo "All volumes removed. Run 'make setup' to start fresh."

# ──────────────────────────────────────────────
# Full setup (all phases)
# ──────────────────────────────────────────────
all: setup bootstrap
	@echo ""
	@echo "Identity service is ready!"
	@echo "Next steps:"
	@echo "  1. Register users via Gate: https://localhost:8090/gate"
	@echo "  2. Seed users: make seed"
	@echo "  3. Run tests: make test"
