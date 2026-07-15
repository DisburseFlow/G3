# Check if we need to prepend docker command with sudo
SUDO := $(shell docker version >/dev/null 2>&1 || echo "sudo")

# Default network type
NETWORK_TYPE ?= testnet

# Image name must match upstream
FRONTEND_IMAGE := stellar/stellar-disbursement-platform-frontend:edge

# Project name for docker compose
COMPOSE_PROJECT_NAME ?= sdp-$(NETWORK_TYPE)

# Frontend build directory
FRONTEND_DIR := frontend

# Backend dev directory
BACKEND_DEV_DIR := backend/dev

# Environment file
ENV_FILE := $(BACKEND_DEV_DIR)/.env

# Default environment variables for local development
export BASE_URL := http://localhost:8000
export SDP_UI_BASE_URL := http://localhost:3000
export NETWORK_TYPE := testnet
export DATABASE_NAME := sdp_mtn
export DATABASE_URL := postgres://postgres@localhost:5432/$(DATABASE_NAME)?sslmode=disable
export NETWORK_PASSPHRASE := "Test SDF Network ; September 2015"
export HORIZON_URL := https://horizon-testnet.stellar.org
export RPC_URL := https://soroban-testnet.stellar.org
export PORT := 8000
export METRICS_PORT := 8002
export ADMIN_PORT := 8003
export ENVIRONMENT := localhost
export LOG_LEVEL := INFO
export METRICS_TYPE := PROMETHEUS
export EMAIL_SENDER_TYPE := DRY_RUN
export SMS_SENDER_TYPE := DRY_RUN
export SEP10_CLIENT_ATTRIBUTION_REQUIRED := true
export ENABLE_SEP45 := true
export SEP45_CONTRACT_ID := CDY4CS2VWHAZOMYVTKUFKGNZKIVFBCXUFNFQ5KSXOTAHKL5H5ZRTAUTH
export ENABLE_EMBEDDED_WALLETS := true
export EMBEDDED_WALLETS_WASM_HASH := 9b784817dff1620a3e2b223fe1eb8dac56e18980dea9726f692847ccbbd3a853
export DISABLE_MFA := true
export RPC_ENABLED := true
export RECAPTCHA_SITE_KEY :=
export SINGLE_TENANT_MODE := true
export CAPTCHA_TYPE := GOOGLE_RECAPTCHA_V3
export DISABLE_RECAPTCHA := true
export CORS_ALLOWED_ORIGINS := *
export INSTANCE_NAME := "SDP on Docker"
export TENANT_XLM_BOOTSTRAP_AMOUNT := 5
export DEFAULT_TENANT_OWNER_EMAIL := "default@default.local"
export DEFAULT_TENANT_OWNER_FIRST_NAME := "Default"
export DEFAULT_TENANT_OWNER_LAST_NAME := "Owner"
export DEFAULT_TENANT_DISTRIBUTION_ACCOUNT_TYPE := "DISTRIBUTION_ACCOUNT.STELLAR.ENV"
export SCHEDULER_RECEIVER_INVITATION_JOB_SECONDS := 10
export SCHEDULER_PAYMENT_JOB_SECONDS := 10
export NUM_CHANNEL_ACCOUNTS := 3
export MAX_BASE_FEE := 1000000
export TSS_METRICS_PORT := 9002
export TSS_METRICS_TYPE := TSS_PROMETHEUS
export ADMIN_ACCOUNT := SDP-admin
export ADMIN_API_KEY := api_key_1234567890
export EC256_PRIVATE_KEY := "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgdo6o+tdFkF94B7z8\nnoybH6/zO3PryLLjLbj54/zOi4WhRANCAAQncc2mE8AQoe+1GOyXkqPBz21MypLa\nmZg3JusuzFnpy5C+DbKIShdmLE/ZwnvtywcKVcLpxvXBCn8E0YO8Yqg+\n-----END PRIVATE KEY-----"
export SEP24_JWT_SECRET := jwt_secret_1234567890

# These are set by the setup wizard or must be provided:
# DISTRIBUTION_PUBLIC_KEY
# DISTRIBUTION_SEED
# SEP10_SIGNING_PUBLIC_KEY
# SEP10_SIGNING_PRIVATE_KEY
# DISTRIBUTION_ACCOUNT_ENCRYPTION_PASSPHRASE
# CHANNEL_ACCOUNT_ENCRYPTION_PASSPHRASE

.PHONY: setup frontend-build frontend-clean dev-up dev-down dev-logs dev-ps dev-restart wait-healthy init-tenant check-env genkeys test lint setup-wizard clean

# Main setup target - runs everything needed for local development
setup: check-env genkeys frontend-build dev-up wait-healthy init-tenant
	@echo ""
	@echo "=========================================="
	@echo "  SDP Local Development Setup Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Frontend:  http://localhost:3000"
	@echo "Backend:   http://localhost:8000"
	@echo "Admin API: http://localhost:8003"
	@echo ""
	@echo "Default login (single tenant mode):"
	@echo "  Username: owner@default.local"
	@echo "  Password: Password123!"
	@echo ""
	@echo "To stop:    make dev-down"
	@echo "To logs:    make dev-logs"
	@echo "To restart: make dev-restart"

# Check/create environment file
check-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "Creating .env from .env.example..."; \
		cp $(BACKEND_DEV_DIR)/.env.example $(ENV_FILE); \
		echo "Created $(ENV_FILE) with default values for local development"; \
		echo "  SINGLE_TENANT_MODE=true"; \
		echo "  DISABLE_MFA=true"; \
		echo "  DISABLE_RECAPTCHA=true"; \
		echo "  RPC_ENABLED=true"; \
	else \
		echo "Using existing $(ENV_FILE)"; \
	fi

# Generate Stellar keys if not present in .env
genkeys:
	@echo "=========================================="
	@echo "  Generating Stellar accounts (if needed)"
	@echo "=========================================="
	cd backend && go run tools/sdp-setup/cmd/genkeys/main.go dev/.env

# Build frontend Docker image locally (same image name as upstream)
frontend-build:
	@echo "=========================================="
	@echo "  Building frontend Docker image locally"
	@echo "=========================================="
	$(SUDO) docker build --pull --no-cache -t $(FRONTEND_IMAGE) $(FRONTEND_DIR)

# Clean frontend build
frontend-clean:
	$(SUDO) docker rmi $(FRONTEND_IMAGE) 2>/dev/null || true

# Start all Docker services
dev-up:
	@echo "=========================================="
	@echo "  Starting Docker services"
	@echo "=========================================="
	$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env up -d --build

# Wait for all services to be healthy
wait-healthy:
	@echo "=========================================="
	@echo "  Waiting for services to become healthy"
	@echo "=========================================="
	@timeout=180; \
	while [ $$timeout -gt 0 ]; do \
		if $(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | grep -q "unhealthy\|starting"; then \
			echo "Waiting for services to be healthy... ($$timeout s)"; \
			sleep 5; \
			timeout=$$((timeout - 5)); \
		else \
			break; \
		fi; \
	done; \
	if [ $$timeout -le 0 ]; then \
		echo "Timeout waiting for services to become healthy"; \
		$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env ps; \
		exit 1; \
	fi; \
	echo "All services are healthy!"

# Initialize tenant and admin user (runs migrations + creates default tenant + user)
init-tenant:
	@echo "=========================================="
	@echo "  Initializing tenant and admin user"
	@echo "=========================================="
	cd $(BACKEND_DEV_DIR) && ./init-tenant.sh

# Stop all Docker services
dev-down:
	$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env down --remove-orphans

# View logs
dev-logs:
	$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env logs -f

# Show service status
dev-ps:
	$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env ps

# Restart services
dev-restart: dev-down dev-up wait-healthy

# Run tests
test:
	cd backend && go test ./...

# Lint
lint:
	cd backend && golangci-lint run

# Run the interactive setup wizard (for manual configuration)
setup-wizard:
	cd backend && go run tools/sdp-setup/main.go

# Full clean
clean: frontend-clean
	$(SUDO) docker compose -p $(COMPOSE_PROJECT_NAME) -f $(BACKEND_DEV_DIR)/docker-compose.yml --env-file $(BACKEND_DEV_DIR)/.env down -v --remove-orphans 2>/dev/null || true