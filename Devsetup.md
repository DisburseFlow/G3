# SDP Local Development Setup Guide

This guide walks you through setting up the Stellar Disbursement Platform (SDP) for local development.

## Prerequisites

- **Docker** (v20.10+) and **Docker Compose** (v2.0+)
- **Go** (v1.22+) - for running the setup wizard and key generation
- **Git** - for cloning submodules
- **make** - for running Makefile targets
- **Node.js** (v22+) and **Yarn** - only needed if building frontend outside Docker

## Quick Start

```bash
# 1. Clone the repository with submodules
git clone --recursive https://github.com/DisburseFlow/G3.git
cd G3


# 2. Run the complete setup (one command!)
make setup
```

That's it! The `make setup` command will:
1. Create `.env` from `.env.example` with local development defaults
2. Generate Stellar testnet accounts (distribution + SEP10) and fund them via Friendbot
3. Build the frontend Docker image locally from `./frontend`
4. Start all services: PostgreSQL, SDP API, TSS, Frontend, Demo Wallet
5. Run all database migrations (102 SDP + 7 auth + admin + TSS)
6. Create the default tenant and admin user
7. Output login credentials

## Accessing the Application

After `make setup` completes successfully:

| Service | URL | Credentials |
|---------|-----|-------------|
| **Frontend (Dashboard)** | http://localhost:3000 | owner@default.local / Password123! |
| **Backend API** | http://localhost:8000 | JWT token from login |
| **Admin API** | http://localhost:8003 | Basic auth: SDP-admin / api_key_1234567890 |
| **Demo Wallet** | http://localhost:4000 | - |
| **TSS Metrics** | http://localhost:9002/metrics | - |
| **SDP Metrics** | http://localhost:8002/metrics | - |

## Project Structure

```
G3/
├── Make                 # Root Makefile - main entry point
├── backend/             # Go backend (submodule)
│   ├── dev/            # Docker Compose files & dev config
│   │   ├── .env.example    # Template environment file
│   │   ├── .env            # Generated (not committed)
│   │   ├── docker-compose.yml
│   │   ├── docker-compose-sdp.yml
│   │   ├── docker-compose-frontend.yml
│   │   ├── docker-compose-tss.yml
│   │   └── init-tenant.sh  # Tenant/admin initialization
│   └── tools/sdp-setup/    # Setup wizard & key generator
├── frontend/           # React frontend (submodule)
│   ├── Dockerfile      # Multi-stage build with runtime config
│   └── docker-entrypoint.sh  # Generates env-config.js at runtime
└── README.md
```

## Common Commands

```bash
# Full setup (run once)
make setup

# Start services (after initial setup)
make dev-up

# Stop services
make dev-down

# Restart services
make dev-restart

# View logs (all services)
make dev-logs

# View logs for specific service
cd backend/dev && docker compose -p sdp-testnet --env-file .env logs -f sdp-api

# Show service status
make dev-ps

# Rebuild frontend only (after source changes)
make frontend-build dev-up wait-healthy

# Run backend tests
make test

# Lint backend code
make lint

# Full clean (removes volumes, images)
make clean
```

## Configuration

### Environment Variables

The `.env` file in `backend/dev/` controls all configuration. Key variables for local development:

| Variable | Default | Description |
|----------|---------|-------------|
| `SINGLE_TENANT_MODE` | `true` | Single tenant mode (simpler for dev) |
| `DISABLE_MFA` | `true` | Disable MFA for easier login |
| `DISABLE_RECAPTCHA` | `true` | Disable reCAPTCHA |
| `RPC_ENABLED` | `true` | Enable RPC in frontend |
| `RECAPTCHA_SITE_KEY` | `` | Empty = disabled |
| `DISTRIBUTION_PUBLIC_KEY` | *generated* | Stellar distribution account |
| `DISTRIBUTION_SEED` | *generated* | Distribution account secret |
| `SEP10_SIGNING_PUBLIC_KEY` | *generated* | SEP10 auth account |
| `SEP10_SIGNING_PRIVATE_KEY` | *generated* | SEP10 auth secret |

### Network Type

Default is `testnet`. For pubnet/mainnet:
```bash
NETWORK_TYPE=pubnet make setup
```

### HTTPS (Optional)

For WebAuthn/passkey support, you need local HTTPS:

1. Install `mkcert`: `brew install mkcert && mkcert -install`
2. Generate certs:
   ```bash
   mkdir -p backend/dev/certs
   mkcert -key-file backend/dev/certs/stellar.local-key.pem \
     -cert-file backend/dev/certs/stellar.local.pem \
     "*.stellar.local" localhost 127.0.0.1 ::1
   ```
3. Add to `/etc/hosts`:
   ```
   127.0.0.1       stellar.local
   127.0.0.1       default.stellar.local
   ```
4. Run with HTTPS:
   ```bash
   USE_HTTPS=true make setup
   ```
   Frontend will be at `https://default.stellar.local:3443`

## Frontend Development

### Making Frontend Changes

The frontend is built into a Docker image. After modifying source files in `frontend/src/`:

```bash
# Rebuild and restart
make frontend-build dev-up wait-healthy
```

The `--no-cache` flag ensures source changes are picked up.

### Frontend Runtime Config

Frontend configuration is injected at container startup via `docker-entrypoint.sh`. Environment variables passed to the container become `window._env_` in the browser:

- `API_URL` - Backend API URL
- `RPC_ENABLED` - Enable Stellar RPC features
- `RECAPTCHA_SITE_KEY` - reCAPTCHA site key
- `SINGLE_TENANT_MODE` - Single tenant UI behavior
- `HORIZON_URL` / `STELLAR_EXPERT_URL` - Explorer links

## Backend Development

### Running Backend Locally (Outside Docker)

```bash
cd backend
ENV_FILE=dev/.env \
DATABASE_URL="postgres://postgres@localhost:5432/sdp_mtn?sslmode=disable" \
go run main.go serve
```

### Remote Debugging

The dev Dockerfile includes Delve debugger on port 2345. Use VS Code or GoLand with the provided `backend/dev/sample/launch.json`.

### Database Access

```bash
# Connect to PostgreSQL
cd backend/dev && docker compose -p sdp-testnet --env-file .env exec db psql -U postgres -d sdp_mtn

# Or from host (port 5432)
psql -h localhost -U postgres -d sdp_mtn
```

## Migration System & Common Issues

### How Migrations Work

The SDP uses a multi-stage migration system executed automatically during `make setup`:

1. **Admin migrations** - Core admin tables
2. **TSS migrations** - Transaction Submission Service tables (including `channel_accounts`)
3. **Auth migrations** - Authentication tables
4. **SDP migrations** - Core business logic tables
4. **Setup-for-network** - Network-specific data (assets, wallets)

Migrations are run automatically by the API container startup command:
```bash
sleep 5
./stellar-disbursement-platform db admin migrate up
./stellar-disbursement-platform db tss migrate up
./stellar-disbursement-platform db auth migrate up --all
./stellar-disbursement-platform db sdp migrate up --all
./stellar-disbursement-platform db setup-for-network --all
```

The TSS service depends on the API being healthy, ensuring migrations complete before TSS starts.

### Common Migration Issues & Fixes

#### Issue 1: "relation 'channel_accounts' does not exist"

**Error:** TSS fails with `pq: relation "channel_accounts" does not exist`

**Root Cause:** TSS started before API migrations completed. The `channel_accounts` table is created by TSS migrations.

**Fix:** The TSS service now depends on API being healthy (`depends_on: sdp-api: condition: service_healthy`). If you encounter this:
```bash
# Restart services to ensure correct order
make dev-down
make dev-up
wait-healthy
```

#### Issue 2: "dial tcp [::1]:5432: connect: connection refused"

**Error:** API cannot connect to PostgreSQL at startup.

**Root Cause:** API container tries to connect before PostgreSQL is ready, or DATABASE_URL points to localhost instead of Docker service name.

**Fix:** 
1. Ensure `.env` has correct DATABASE_URL: `postgres://postgres@db:5432/sdp_mtn?sslmode=disable`
2. Database has health check with `start_period: 30s`
3. API depends on DB with `condition: service_healthy`

#### Issue 3: "invalid private key, make sure your private key is generated with a curve at least as strong as prime256v1"

**Error:** API fails to start with EC256 private key error.

**Root Cause:** The default EC256_PRIVATE_KEY in docker-compose-sdp.yml was using invalid PEM format.

**Fix:** The `.env.example` and `.env` now include a valid prime256v1 EC key. If you need to regenerate:
```bash
openssl ecparam -genkey -name prime256v1 -noout -out ec_private_key.pem
cat ec_private_key.pem | sed ':a;N;s/\n/\\n/g;ta'  # Escape newlines for .env
```

#### Issue 4: "relation 'channel_accounts' does not exist" during TSS startup

**Error:** TSS logs show `pq: relation "channel_accounts" does not exist at character 33`

**Root Cause:** TSS started before API migrations created the table.

**Fix:** TSS now depends on API health check. The API health check uses `/app-config` endpoint which only returns 200 after migrations complete.

#### Issue 5: Health check fails with "curl: not found"

**Error:** Health check fails with `/bin/sh: curl: not found`

**Fix:** Added `curl` to the API development Dockerfile. If you rebuild the API image:
```bash
make clean
make setup
```

### How to Rebuild After Changes

#### Frontend Changes
```bash
# After modifying frontend/src/
make frontend-build dev-up wait-healthy
```

#### Backend Changes
```bash
# Full rebuild
make clean
make setup

# Or just rebuild API
cd backend/dev && docker compose -p sdp-testnet --env-file .env build sdp-api
make dev-up wait-healthy
```

#### Database Schema Changes (Adding Migrations)
```bash
# 1. Create migration files in backend/db/migrations/
# 2. Rebuild and restart
make clean
make setup
```

#### Database Connection Refused

Ensure PostgreSQL is healthy:
```bash
cd backend/dev && docker compose -p sdp-testnet --env-file .env ps db
# Should show "healthy"
```

### Tenant Initialization Fails

Re-run init script manually:
```bash
cd backend/dev && ./init-tenant.sh
```

### Reset Everything

```bash
make clean
# Then re-run
make setup
```

### Frontend Changes Not Reflecting

```bash
# Force rebuild without cache
make frontend-build dev-up wait-healthy
```

### Port Conflicts

If ports 3000, 4000, 5432, 8000, 8003, 9000 are in use:
```bash
# Find and kill processes
lsof -i :3000
kill -9 <PID>

# Or stop other SDP projects
make dev-down
```

### Database Connection Refused

Ensure PostgreSQL is healthy:
```bash
cd backend/dev && docker compose -p sdp-testnet --env-file .env ps db
# Should show "healthy"
```

### Tenant Initialization Fails

Re-run init script manually:
```bash
cd backend/dev && ./init-tenant.sh
```

### Reset Everything

```bash
make clean
# Then re-run
make setup
```

## Architecture Notes

### What's Different from Upstream

1. **Frontend builds locally** - Instead of pulling `stellar/stellar-disbursement-platform-frontend:edge` from registry, we build from `./frontend` with same image name
2. **Single tenant by default** - `SINGLE_TENANT_MODE=true` for simpler local dev
3. **Auto key generation** - `genkeys` target creates/funds Stellar accounts automatically
4. **Runtime frontend config** - `env-config.js` generated at container startup from env vars
5. **Init script** - `init-tenant.sh` runs all migrations + creates tenant + admin user

### Services Started

| Service | Container Name | Ports | Description |
|---------|---------------|-------|-------------|
| PostgreSQL | `sdp-testnet-db-1` | 5432 | Main database |
| SDP API | `sdp-testnet-sdp-api-1` | 8000, 8002, 8003, 2345 | REST API, metrics, admin, debugger |
| TSS | `sdp-testnet-sdp-tss-1` | 9000, 9002 | Transaction Submission Service |
| Frontend | `sdp-testnet-sdp-frontend-1` | 3000 | Nginx serving React app |
| Demo Wallet | `sdp-testnet-demo-wallet-1` | 4000 | Stellar demo wallet for testing |

## Updating from Upstream

When upstream SDP repos are updated:

```bash
# Update submodules
git submodule update --remote --merge

# Rebuild and restart
make clean
make setup
```

The changes are minimal and upstream-compatible - only the root Makefile and dev docker-compose files are modified.

## Useful Links

- [SDP Backend Repo](https://github.com/DisburseFlow/stellar-disbursement-platform-backend)
- [SDP Frontend Repo](https://github.com/DisburseFlow/stellar-disbursement-platform-frontend)
- [SDP Documentation](https://developers.stellar.org/docs/platforms/stellar-disbursement-platform)
- [Stellar Testnet Friendbot](https://friendbot.stellar.org)