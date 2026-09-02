.PHONY: setup get-secret bootstrap seed test test-phase1 test-phase2 test-phase3 test-phase4 test-phase5 \
       test-phase6 test-phase7 backup restore logs logs-all status stop down clean build-toolbox all

TOOLBOX = docker compose run --rm toolbox

# ──────────────────────────────────────────────
# Phase 1: Start services
# ──────────────────────────────────────────────
setup:
	docker compose up thunderid-setup 2>&1 | tee setup-output.txt
	docker compose up -d thunderid mailslurper
	@echo "Waiting for ThunderID to be healthy..."
	@until docker inspect auth-thunderid-1 --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; do \
		sleep 3; echo "  waiting..."; \
	done
	@echo ""
	@echo "ThunderID is ready!"
	@echo "  Console: https://localhost:8090/console"
	@echo "  Gate:    https://localhost:8090/gate"
	@echo "  Mail:    http://localhost:4436"
	@echo ""
	@echo "IMPORTANT: Check setup-output.txt for admin password and Direct Auth Secret"

# ──────────────────────────────────────────────
# Build the toolbox container (Python + deps)
# ──────────────────────────────────────────────
build-toolbox:
	docker compose build toolbox

# ──────────────────────────────────────────────
# Retrieve Direct Auth Secret
# ──────────────────────────────────────────────
get-secret:
	@docker compose exec thunderid cat config/secrets/direct_auth_secret

# ──────────────────────────────────────────────
# Phase 2: Bootstrap tenants, resource servers, roles, agents
# ──────────────────────────────────────────────
bootstrap:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) python3 bootstrap/bootstrap.py

# ──────────────────────────────────────────────
# Phase 2b: Seed users into tenants
# ──────────────────────────────────────────────
seed:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) python3 bootstrap/seed_users.py

# ──────────────────────────────────────────────
# Testing (all run inside the toolbox container)
# ──────────────────────────────────────────────
test:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) bash scripts/test-all.sh

test-phase1:
	$(TOOLBOX) bash scripts/test-phase1.sh

test-phase2:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) bash scripts/test-phase2.sh

test-phase3:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) bash scripts/test-phase3.sh

test-phase4:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) bash scripts/test-phase4.sh

test-phase5:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	$(TOOLBOX) bash scripts/test-phase5.sh

test-phase6:
	@test -n "$(ADMIN_PASSWORD)" || { echo "Error: set ADMIN_PASSWORD"; exit 1; }
	ADMIN_PASSWORD="$(ADMIN_PASSWORD)" bash scripts/test-phase6.sh

test-phase7:
	bash scripts/test-phase7.sh

# ──────────────────────────────────────────────
# Operations
# ──────────────────────────────────────────────
backup:
	bash scripts/backup-db.sh

restore:
	@echo "Usage: make restore FILE=backups/thunderid_YYYYMMDD.tar.gz"
	@test -n "$(FILE)" || { echo "Error: set FILE=<backup.tar.gz>"; exit 1; }
	CONFIRM=yes bash scripts/restore-db.sh $(FILE)

logs:
	docker compose logs -f thunderid

logs-all:
	docker compose logs -f

status:
	docker compose ps
	@echo ""
	@docker inspect auth-thunderid-1 --format '{{.State.Health.Status}}' 2>/dev/null \
		| grep -q healthy \
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
	rm -f setup-output.txt bootstrap/config/agent-secrets.json
	@echo "All volumes removed. Run 'make setup' to start fresh."

# ──────────────────────────────────────────────
# Full setup (all phases)
# ──────────────────────────────────────────────
all: setup build-toolbox bootstrap seed
	@echo ""
	@echo "Identity service is ready!"
	@echo "  Run tests: ADMIN_PASSWORD=<pw> make test"
