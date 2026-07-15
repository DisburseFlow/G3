# Stellar Disbursement Platform - Trustlines & Receiver Analysis + SAPCONE PRD Gap Analysis

---

## Part 1: Trustlines for Receiving Accounts (Receiver Wallets)

### How Trustlines Are Handled

**Key Finding: Trustlines are managed for the DISTRIBUTION ACCOUNT (sender), NOT for receiver accounts.**

The SDP codebase handles trustlines exclusively at the **distribution account level** (the sending organization's Stellar account). Receivers do NOT need trustlines created/managed by the platform.

#### Trustline Management Locations:

1. **Provisioning** (`stellar-multitenant/internal/provisioning/manager.go:168-254`):
   - On tenant provisioning, trustlines are added to the **distribution account** for all non-native assets associated with enabled wallets
   - `addTrustlinesForDistributionAccount()` gathers assets from all enabled wallets and adds trustlines to the distribution account

2. **Asset Management** (`internal/serve/httphandler/assets_handler.go:164-344`):
   - `CreateAsset`: Automatically adds trustline for new asset to distribution account
   - `DeleteAsset`: Attempts to remove trustline from distribution account (fails if balance > 0)
   - `handleUpdateAssetTrustlineForDistributionAccount()`: Core logic for add/remove trustlines on distribution account

3. **Direct Payments** (`internal/services/direct_payment_service.go:335-346`):
   - `checkTrustlineExists()` validates distribution account has trustline before sending
   - Returns error if trustline missing: `"distribution account %s does not have a trustline for asset %s:%s"`

4. **Bridge Integration** (`internal/bridge/service.go:158-165`):
   - Requires USDC trustline on distribution account to enable Bridge integration

### Unique Constraints on Receivers

From `internal/data/receivers.go:326-335` and database constraints:

| Constraint | Columns | Purpose |
|------------|---------|---------|
| `receiver_unique_email` | `email` | Unique email per receiver |
| `receiver_unique_phone_number` | `phone_number` | Unique phone number per receiver |

From `internal/data/receivers_wallet.go:15` migration:
| Constraint | Columns | Purpose |
|------------|---------|---------|
| `UNIQUE (receiver_id, wallet_id)` | `receiver_id`, `wallet_id` | One receiver-wallet pairing per wallet |
| Trigger `validate_stellar_address_per_receiver` | `stellar_address`, `receiver_id` | Stellar address can only belong to ONE receiver |

From `db/migrations/sdp-migrations/2025-07-02.0-add-wallet-per-receiver-unique-constaint.sql`:
- A Stellar address (wallet address) **cannot be shared across multiple receivers** (enforced by DB trigger)

### What Happens When a Receiver Changes Their Phone Number?

**Current Implementation (from `internal/data/receivers.go:340-395`):**

1. **Receiver table allows phone number updates** via `ReceiverModel.Update()`
2. **Unique constraint `receiver_unique_phone_number` prevents duplicates** - will return `ErrDuplicatePhoneNumber` if new number already exists
3. **Receiver wallets are linked by `receiver_id`, NOT phone number** - the wallet association is stable

**Impact on Receiver Wallets:**
- The `receiver_wallets` table links to `receivers.id` (foreign key), NOT phone number
- Changing phone number does NOT affect wallet registration or trustlines
- The Stellar address in `receiver_wallets.stellar_address` remains unchanged

**Implication:** The wallet address (Stellar account) is **pegged to the receiver_id**, not the phone number. A receiver can change phone numbers freely without affecting their wallet or ability to receive payments. The unique constraint on phone number is only to prevent two different receivers from claiming the same phone number.

---

## Part 1b: Proposed Architecture - Abstracted Wallet Management for ALL Receivers

### New Requirement: Platform-Managed Wallets for ALL Receivers

**Goal:** Abstract wallet management completely so receivers (both with and without phones) never interact with wallets, private keys, or trustlines. The platform creates and manages Stellar accounts + trustlines for every receiver.

### Architecture Changes Required

| Component | Current SDP | Proposed Change |
|-----------|-------------|-----------------|
| **Receiver Stellar Account** | Created by receiver via SEP-24 (phone/email + wallet) | Created by platform at receiver registration (embedded wallet or custodial account) |
| **Trustline Management** | Only distribution account | **Both distribution account AND all receiver accounts** |
| **Wallet Custody** | Receiver-managed (Vibrant, Lobstr, etc.) or embedded wallet (no-phone only) | **Platform-managed custodial accounts for ALL receivers** |
| **Private Keys** | Held by receiver or TSS (embedded only) | **Held by TSS (Threshold Signature Service) for all platform-managed accounts** |
| **SEP-24 Flow** | Required for registration | **Eliminated for platform-managed wallets** |

### Trustline Management for All Receiver Addresses

#### When Trustlines Are Created for Receivers

1. **At Receiver Registration** (for all receivers, regardless of phone):
   - Platform creates Stellar account via TSS (embedded wallet contract or custodial account)
   - Platform adds trustlines for ALL assets configured for the programme/disbursement
   - Trustlines created before first payment can be sent

2. **When New Assets Are Added to Programme**:
   - Background job adds trustline to ALL existing receiver accounts for the new asset
   - Similar to distribution account provisioning but at scale

3. **At Disbursement Creation** (lazy creation):
   - If receiver account lacks trustline for disbursement asset, add it before payment

#### Trustline Operations at Scale

| Operation | Current (Distribution Only) | Proposed (All Receivers) |
|-----------|----------------------------|--------------------------|
| Add trustline | 1 per asset per tenant | N receivers × M assets per tenant |
| Remove trustline | Rare (only on asset delete) | Rare (only on asset delete or receiver deletion) |
| Check trustline | Before each payment batch | Before each payment batch (cached) |
| Batch operations | Single transaction | Batched via TSS (100-500 ops/tx) |

#### Database Schema Changes Required

```sql
-- New table: receiver_stellar_accounts
CREATE TABLE receiver_stellar_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receiver_id UUID NOT NULL REFERENCES receivers(id),
    stellar_address VARCHAR(56) NOT NULL UNIQUE,  -- Contract address or ed25519 pubkey
    account_type VARCHAR(32) NOT NULL,  -- 'EMBEDDED_WALLET' | 'CUSTODIAL'
    tss_key_id VARCHAR(64),  -- Reference to TSS key share
    status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- New table: receiver_trustlines
CREATE TABLE receiver_trustlines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receiver_stellar_account_id UUID NOT NULL REFERENCES receiver_stellar_accounts(id),
    asset_code VARCHAR(12) NOT NULL,
    asset_issuer VARCHAR(56) NOT NULL,
    trustline_limit BIGINT,  -- NULL = no limit
    status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE',  -- 'ACTIVE', 'REMOVED', 'PENDING'
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    confirmed_at TIMESTAMPTZ,
    stellar_tx_hash VARCHAR(64),
    UNIQUE (receiver_stellar_account_id, asset_code, asset_issuer)
);

-- Indexes for efficient lookups
CREATE INDEX idx_receiver_trustlines_asset ON receiver_trustlines(asset_code, asset_issuer);
CREATE INDEX idx_receiver_trustlines_status ON receiver_trustlines(status);
```

#### Integration Points

1. **Receiver Registration API** (`POST /receivers`):
   - Creates receiver record
   - Triggers async Stellar account creation via TSS
   - Returns `reference_id` immediately (account created in background)

2. **Disbursement Processing**:
   - Before payment batch, verify all receivers have trustlines for asset
   - Queue missing trustlines for batch creation
   - Hold payments until trustlines confirmed

3. **Asset Management** (`POST /assets`):
   - After adding asset to distribution account, queue trustline creation for all active receivers
   - Background worker processes in batches via TSS

4. **TSS Integration** (`internal/transactionsubmission/engine`):
   - Extend to support batch ChangeTrust operations
   - Use contract accounts (Soroban) for embedded wallets or ed25519 for custodial
   - Implement idempotent trustline creation (check Horizon first)

### Implications for Phone vs No-Phone Receivers

| Aspect | Receivers WITH Phone | Receivers WITHOUT Phone |
|--------|---------------------|------------------------|
| **Registration** | Phone verification + auto-create Stellar account | In-person verification + auto-create Stellar account |
| **Wallet Access** | Optional: can link external wallet later | None (platform-managed only) |
| **Trustlines** | Auto-managed by platform | Auto-managed by platform |
| **Cash-out** | Can use external wallet or platform off-ramp | Platform off-ramp only (proxy or agent) |
| **PII** | Phone + optional email | Name + ID verification only |

### Security Considerations

- **Custodial risk**: Platform holds keys for all receivers → requires audit, insurance, regulatory review
- **TSS threshold**: Use appropriate threshold (e.g., 3-of-5) for key management
- **Account recovery**: Built-in via TSS (no seed phrase for receivers)
- **Compliance**: KYC/AML on receiver at registration; transaction monitoring on all payments

---

## Part 2: SAPCONE PRD V2 - Product 1 (DisburseFlow) Gap Analysis

### Product 1: DisburseFlow (The Payment Platform)
*Deployed, gap-analysed, and forked SDP instance with SAPCONE customisations*

---

### Current SDP Capabilities (What SDP Already Provides)

| Area | SDP Provides |
|------|--------------|
| Bulk disbursement from file upload | ✅ CSV upload, validation, individual payment tracking |
| Wallet management | ✅ Multiple wallets (Vibrant, embedded, etc.), asset configuration |
| Stellar payments | ✅ Native Stellar, trustlines on distribution account |
| Retry logic | ✅ Automatic retries for failed payments |
| Dashboards | ✅ Operational dashboards for finance/programme admins |
| SEP-24 registration | ✅ Phone/email + wallet address registration flows |
| Proxy payments | ⚠️ Partial (receiver verification fields exist, but no proxy handover flow) |
| Organization/tenant multi-tenancy | ✅ Complete isolation |

---

### Gap Analysis: SAPCONE Requirements vs. SDP Capabilities

| SAPCONE Requirement | SDP Status | Gap Classification |
|---------------------|------------|-------------------|
| **Cross-border payments (Kenya → Uganda/Ethiopia/South Sudan)** | ✅ Stellar payments work cross-border | **SDP-provides** - use USDC on Stellar |
| **Domestic Kenya (M-Pesa/Equity Bank)** | ⚠️ SDP has anchor integration path | **Fork-extends** - needs off-ramp integration |
| **Proxy/cash delivery (gatekeepers, chiefs)** | ❌ No proxy delivery confirmation flow | **Fork-extends** - D-5, L-4, L-5 |
| **Participants with NO phone** | ⚠️ SEP-24 requires phone/email | **Fork-extends** - L-1, L-2, L-3 |
| **Offline field registration** | ❌ No offline capability | **Fork-extends** - L-1, L-2 |
| **Physical reference cards (QR + ref ID, no PII)** | ❌ Not in SDP | **Fork-extends** - L-1 |
| **Delivery confirmation anchored on-chain** | ❌ Not in SDP | **Fork-extends** - L-5 |
| **Fraud detection (anomalous proxy patterns)** | ❌ Not in SDP | **Fork-extends** - L-6 |
| **Auto-return of undelivered funds** | ❌ Not in SDP | **Fork-extends** - L-8 |
| **Donor-facing public verification portal** | ❌ Only internal dashboards | **Product 3 (OpenLedger)** - O-1 to O-7 |
| **PII isolation (reference IDs only in downstream)** | ✅ SDP already separates PII | **SDP-provides** |
| **Real-time per-participant verification** | ❌ Internal only | **Product 3 (OpenLedger)** - O-2, O-3 |

---

### Required Fork Extensions for Product 1 (Priority from PRD)

| ID | Extension | Description | Why SDP Can't Do This |
|----|-----------|-------------|----------------------|
| **D-5a** | Proxy-linked disbursement records | Add `proxy_id`, `delivery_confirmation` fields to payments/disbursements | SDP has no proxy concept |
| **D-5b** | Registration event hooks | Emit events when receiver created/updated for LastMile sync | No event emission for receiver lifecycle |
| **D-5c** | Offline-tolerant registration API | Accept registrations without immediate SEP-24 flow | SEP-24 requires interactive flow |
| **D-5d** | Reference ID generation | Generate opaque reference IDs for participants (no PII) | SDP uses phone/email as primary identifiers |
| **D-5e** | Embedded wallet auto-provisioning | Create Stellar accounts for no-phone participants via embedded wallet | Requires TSS integration + custom flow |
| **D-5f** | Universal receiver Stellar account provisioning | Create platform-managed Stellar account + trustlines for EVERY receiver at registration (phone + no-phone) | Requires TSS integration, new DB schema, background workers |
| **D-5g** | Receiver trustline lifecycle management | Background jobs to add trustlines to all receivers when new assets added; verify before disbursement | New scheduler jobs, Horizon caching, batch TSS operations |
| **D-5h** | Custodial account recovery & compliance | Account freeze, regulatory reporting, audit trails for all platform-managed accounts | New admin APIs, compliance hooks |

---

### What Product 2 (LastMile) NEEDS from Product 1

| Need | Product 1 Contract | Current Status |
|------|-------------------|----------------|
| **Receiver registration extension** | New API: `POST /receivers/offline` accepting name, programme, ID verification, optional phone → returns `reference_id` + prints card | **Gap** - needs D-5c, D-5d |
| **Disbursement events for proxy lists** | Event: `disbursement.created` with payments[] containing `reference_id`, `amount`, `asset` | **Gap** - needs event emission (D-5b) |
| **Delivery confirmation write-back** | API: `PATCH /payments/:id/delivery-confirmation` with `proxy_id`, `timestamp`, `geotag`, `stellar_tx_hash` | **Gap** - new endpoint needed |
| **Undelivered funds auto-return** | API: `POST /disbursements/:id/return-undelivered` triggers refunds to org wallet | **Gap** - L-8 requires this |
| **PII isolation guarantee** | All APIs use `reference_id` (opaque); PII only in `/receivers` (restricted) | ✅ SDP already does this |
| **Receiver Stellar account + trustlines** | API: `GET /receivers/:id/stellar-account` → `{stellar_address, trustlines: [{asset_code, asset_issuer, status}]}` | **Gap** - needs D-5f, D-5g |
| **Trustline status check before disbursement** | Event/API: verify all receivers in disbursement have trustlines for asset | **Gap** - needs D-5g |

---

### What Product 3 (OpenLedger) NEEDS from Product 1

| Need | Product 1 Contract | Current Status |
|------|-------------------|----------------|
| **Read-only payment data** | API: `GET /programmes/:id/payments` → `{reference_id, amount, status, stellar_tx_hash, delivered_at, delivery_confirmed}` | **Gap** - needs programme-scoped read API |
| **Delivery confirmation data** | Join from LastMile: `delivery_confirmations` table with `payment_id`, `proxy_id`, `confirmed_at`, `stellar_tx_hash` | **Gap** - needs D-5a schema + API |
| **Horizon deep links** | Use `stellar_tx_hash` from payments to link to public explorer | ✅ SDP stores tx hashes |
| **Zero PII guarantee** | API must NEVER return phone, email, name - only `reference_id` | ✅ SDP already separates |

---

### Summary of Product 1 Improvements Required

| Priority | Improvement | PRD Ref | Effort |
|----------|-------------|---------|--------|
| **P0** | Proxy-linked disbursement schema + API | D-5, D-6 | Medium |
| **P0** | Event emission for receiver/disbursement lifecycle | D-5b, C.2 | Medium |
| **P0** | Offline registration endpoint (no SEP-24) | L-1, L-2 | Medium |
| **P0** | Reference ID generation (opaque, no PII) | C.1, L-3 | Low |
| **P0** | Delivery confirmation write-back endpoint | L-4, L-5 | Medium |
| **P0** | Universal receiver Stellar account provisioning (all receivers) | D-5f, L-1, L-3 | High (TSS + schema) |
| **P0** | Receiver trustline lifecycle management (add/verify at scale) | D-5g | High (workers + TSS) |
| **P1** | Embedded wallet auto-provisioning for no-phone | L-1, L-3 | High (TSS) |
| **P1** | Custodial account recovery & compliance hooks | D-5h | High (regulatory) |
| **P1** | Programme-scoped read API for OpenLedger | O-1, C.2 | Low |
| **P1** | Auto-return undelivered funds job | L-8 | Medium |
| **P2** | Fraud detection hooks (anomaly flags) | L-6 | Low (hooks) |
| **P2** | Right-to-erasure endpoint (PII only) | L-9 | Low |

---

### What is OUT OF SCOPE for Product 1 (Deferred to Propel / Product 2/3)

| Item | Reason | Owner |
|------|--------|-------|
| Live off-ramp integration (M-Pesa, Equity Bank) | Requires commercial agreements | Propel (D-8) |
| USSD channel | Aggregator agreements take longer than Studio | Propel |
| Full RBAC beyond SDP's built-in | SDP ships with basic roles | Propel |
| Ethiopia/South Sudan corridors | Out of scope per A.6 | Propel |
| Donor accounts with scoped access | OpenLedger feature | Product 3 (O-8) |
| Physical card printing/distribution | LastMile hardware/logistics | Product 2 |
| Proxy incentive/liability model | SAPCONE operational decision | Propel |
| Exchange rate disclosure at cash-out | Requires off-ramp partner rates | Propel |

---

## Key Architectural Decisions from PRD

1. **SDP is the spine** - Products 2 & 3 integrate via fork's APIs/events, not parallel DBs
2. **PII separation is non-negotiable** - Only `receivers` table holds PII; everything else uses `reference_id`
3. **Reference ID = participant identifier** - Opaque, generated at registration, used everywhere downstream
4. **Proxy confirmation anchors on Stellar** - Makes handover independently verifiable (Product 2 decision: memo tx vs Soroban)
5. **Flow-of-funds diagram required** - For any multi-party fund flow (distribution → embedded wallet → proxy → participant)

---

## Trustline-Related Notes for SAPCONE

- **USDC trustlines**: Only needed on **distribution account** (sender side)
- **Receiver wallets (CURRENT SDP)**: No trustline management needed - they receive native XLM or assets their wallet already trusts
- **Embedded wallets** (for no-phone participants): Will need trustlines set up at account creation time via TSS
- **Bridge integration**: Requires USDC trustline on distribution account (already validated in SDP)

### Proposed Architecture: Platform-Managed Trustlines for ALL Receivers

- **NEW**: Platform creates trustlines for **every receiver account** (not just distribution account)
- **At receiver registration**: Auto-create Stellar account + trustlines for all programme assets
- **At new asset addition**: Background job adds trustline to ALL existing receiver accounts
- **At disbursement**: Verify trustlines exist; queue missing ones for batch creation via TSS
- **Scale**: N receivers × M assets per tenant; batched via TSS (100-500 ops/tx)
- **Schema**: New tables `receiver_stellar_accounts` + `receiver_trustlines` (see Part 1b)