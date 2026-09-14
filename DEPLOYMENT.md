# Deployment & Cutover Guide: Moving to Full Gmail-Capable Stack

This guide provides concrete host instructions for transitioning an existing preview deployment to a full, self-hosted, Gmail-capable Kurrier stack using Docker Compose.

---

## 1. Architectural Overview & Live Host Topology

### Live Topology Findings
Based on live environment diagnostics:
- **Docker Engine and Docker Compose are absent** from the preview host.
- The existing preview is running directly on the host as a systemd service: `kurrier-ui.service` (listening on port 3000), not a Docker container.
- The worker backend (`http://worker:3001`) was absent, resulting in HTTP 500 errors on API routes (such as `/api/kurrier/me`) when Next.js attempted to proxy backend requests.

### Full Stack Architecture
The full Docker Compose stack introduces:
- **`web`**: Next.js user interface (`ghcr.io/kurrier-org/kurrier-web:v4.1.0`), bound to `${WEB_PORT:-3000}:3000`.
- **`worker`**: Nitro API engine (`ghcr.io/kurrier-org/kurrier-worker:v4.1.0`), bound privately to `127.0.0.1:${NITRO_PORT:-3001}:3001`.
- **`postgres`**: Core relational database with Row-Level Security (RLS) support, bound privately to `127.0.0.1:${POSTGRES_PORT:-5432}:5432`.
- **`migrate`**: One-shot bootstrap container that waits for Postgres health, idempotently initializes the `auth` schema and `kurrier` database role, synchronizes credentials without logging secrets, and applies all SQL migrations before `web` and `worker` launch.
- **`redis`**: Session caching and task queue, bound privately to `127.0.0.1:${REDIS_PORT:-6379}:6379`.
- **`typesense`**: Full-text email and thread search engine, bound privately to `127.0.0.1:${TYPESENSE_PORT:-8108}:8108`.
- **`garage`**: Lightweight S3-compatible object storage for attachments and raw EML files, bound privately to `127.0.0.1` on ports `3900-3903`.
- **`baikal-postgres`** & **`dav`**: Baikal CalDAV/CardDAV server backed by dedicated PostgreSQL, bound privately to `127.0.0.1` on ports `5433` and `5232`.

### Security Hardening (Private Port Bindings)
All backing infrastructure services (`postgres`, `baikal-postgres`, `redis`, `typesense`, `garage`, `dav`, and `worker`) bind strictly to `127.0.0.1`. They are accessible to other containers via internal Docker networking and to the host locally for administration and health checks, but are never exposed on public network interfaces (`0.0.0.0`).

---

## 2. Pre-Cutover: Preserving Existing Secrets

> [!IMPORTANT]
> **Never overwrite an existing `.env` file!**
> Overwriting `.env` with `example.env` destroys existing encryption keys, invalidating stored sessions and any existing secrets encrypted with `APP_SECRET_ENCRYPTION_KEY`.

Before performing any changes on the host:

1. **Create an Explicit Backup of `.env`**:
   Save a dedicated pre-cutover copy to an exact, deterministic filename (as well as an optional timestamped copy):
   ```bash
   # Create canonical pre-cutover backup:
   cp /path/to/kurrier/db/.env /path/to/kurrier/db/.env.pre-cutover

   # Optional timestamped copy:
   BACKUP_NAME=".env.backup.$(date +%Y%m%d%H%M%S)"
   cp /path/to/kurrier/db/.env "/path/to/kurrier/db/$BACKUP_NAME"
   echo "Timestamped backup saved as: $BACKUP_NAME"
   ```

2. **Verify Required Secret Variables**:
   Ensure the following keys are preserved with their original values in `db/.env`:
   - `JWT_SECRET`: Used for session authentication tokens.
   - `APP_SECRET_ENCRYPTION_KEY`: AES encryption key for Vault secrets.
   - `REDIS_PASSWORD`: Password for Redis authentication.
   - `POSTGRES_PASSWORD`: Postgres superuser password.
   - `DATABASE_URL`: `postgresql://postgres:<POSTGRES_PASSWORD>@postgres:5432/postgres`
   - `DATABASE_RLS_URL`: `postgresql://kurrier:<POSTGRES_PASSWORD>@postgres:5432/postgres`

3. **RLS Role Credentials (Secret-Safe & Percent-Decoded)**:
   You can supply explicit client credentials in `db/.env` (recommended if passwords contain reserved URL characters):
   ```bash
   RLS_CLIENT_USER=kurrier
   RLS_CLIENT_PASSWORD=your_rls_password_here
   ```
   If omitted, `db/init/db-bootstrap.sh` automatically extracts the user and password from `DATABASE_RLS_URL` and RFC 3986 percent-decodes them (for example, `p%40ss%3Aword` decodes to `p@ss:word`).

4. **Confirm Additional Variables**:
   Ensure the following additions are present in `db/.env`:
   ```bash
   BAIKAL_POSTGRES_PASSWORD=strong_baikal_password
   GOOGLE_MAIL_CLIENT_ID=
   GOOGLE_MAIL_CLIENT_SECRET=
   # Leave false for initial workspace setup; set to true once owner account exists to close public signup:
   DISABLE_SIGNUP=false
   ```

---

## 3. Host Preflight & Docker Installation

Because Docker Engine and Docker Compose are not pre-installed on the preview host, install them prior to cutover:

```bash
# 1. Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# 2. Add Docker's official GPG key (Debian 12 bookworm)
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 3. Add the Docker apt repository (Debian 12 bookworm)
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. Install Docker Engine, CLI, and Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. Enable and start Docker daemon
sudo systemctl enable --now docker

# 6. Add operator user to the docker group
sudo usermod -aG docker "$USER"

# 7. Apply group membership to the current shell session (or log out and re-login)
newgrp docker
```

### Preflight Verification
Verify that Docker and Compose are operational and accessible without `sudo`:
```bash
docker --version
docker compose version
docker info >/dev/null && echo "✅ Docker daemon is running and accessible without sudo"
```
*(Note: If continuing in an existing shell without running `newgrp docker` or opening a fresh login session, the supplementary group will not be active in the current shell, requiring you to prefix all subsequent `docker` and `docker compose` commands with `sudo`).*

---

## 4. Google Cloud OAuth Prerequisites & Setup Sequence

Before connecting Gmail or Google Workspace accounts, you must create and register an OAuth 2.0 Web Application in the Google Cloud Console.

> [!WARNING]
> **No Usable OAuth Link Prior to Configuration**:
> The interactive "Add Google Account" authorization link (`/api/oauth/google/connect`) requires valid Google OAuth application credentials. If you click the link before configuring a Client ID and Client Secret, the server will raise an error (`Google Mail OAuth is not configured`). The Kurrier UI displays a configuration modal until credentials exist.

### Step 4.0: Initial Workspace Creation & Admin Signup (No Default Credentials)

> [!IMPORTANT]
> **Kurrier Has No Default Credentials**:
> Kurrier does not seed an initial admin user or default credentials.
> - The first user to complete registration at `/en/auth/signup` (reached via the "Create an account" link on `/auth/login`) creates the workspace and automatically becomes the workspace owner and administrator.
> - Because registration is open by default, complete the first signup immediately upon deploying the stack.
> - Once the workspace owner account exists, lock down public registration to prevent unauthorized signups across the network by setting `DISABLE_SIGNUP=true` in `db/.env` and recreating the web container (see Step 5 in Section 5).

### Step 4.1: Google Cloud Console Setup

1. **Project Creation / Selection**:
   - Go to the [Google Cloud Console](https://console.cloud.google.com/).
   - Select an existing project or create a new project (e.g. `kurrier-mail`).

2. **Enable Gmail API**:
   - Navigate to **APIs & Services → Library**.
   - Search for **Gmail API** and click **Enable**.

3. **Configure OAuth Consent Screen**:
   - Go to **APIs & Services → OAuth consent screen**.
   - Choose User Type:
     - **Internal**: If connecting accounts only within your Google Workspace organization.
     - **External**: If connecting personal `@gmail.com` accounts or cross-organization accounts.
   - Set Application Name (`Kurrier`) and support email.
   - If External and in "Testing" status: Navigate to **Test users** and add the specific Gmail addresses that will be connected.

4. **Required OAuth Scopes**:
   Configure the following scopes under the consent screen:
   - `openid`
   - `email`
   - `profile`
   - `https://www.googleapis.com/auth/gmail.modify` (read, label, and manage messages)
   - `https://www.googleapis.com/auth/gmail.send` (send messages)

5. **Create OAuth 2.0 Client Credentials**:
   - Navigate to **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
   - Select **Application type**: **Web application**.
   - **Authorized JavaScript origins**:
     - Local/preview: `http://localhost:3000`
     - Production: `https://mail.example.com` (your `WEB_URL`)
   - **Authorized redirect URIs**:
     - Local/preview: `http://localhost:3000/api/oauth/google/callback`
     - Production: `https://mail.example.com/api/oauth/google/callback` (must match exact host and protocol)
   - Click **Create** and record the **Client ID** and **Client Secret**.

### Step 4.2: Applying Credentials to Kurrier

Choose one of two configuration methods:

- **Method A (Environment Variables - Recommended for Self-Hosting)**:
  Add the credentials to `db/.env`:
  ```bash
  GOOGLE_MAIL_CLIENT_ID=123456789-abcdef.apps.googleusercontent.com
  GOOGLE_MAIL_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxx
  ```
  Recreate the application containers so Docker Compose re-reads `db/.env` and injects the updated environment variables into the container processes:
  ```bash
  docker compose up -d --force-recreate web worker
  ```
  *(Important: `docker compose restart` only cycles existing containers with their original environment intact; it does **not** reload `.env` files or recreate containers. Running `docker compose up -d --force-recreate web worker` recreates only the application containers with the new environment variables while leaving PostgreSQL, Redis, and storage infrastructure undisturbed).*

- **Method B (Dashboard Vault)**:
  Log into Kurrier as a workspace admin, navigate to **Dashboard → Providers → Google**, click **Configure Google OAuth**, enter your Client ID and Client Secret, and click **Save**. Credentials will be stored in the workspace Vault.

### Step 4.3: Linking Google Account
Once credentials are saved, the dashboard activates the **Add Google Account** button:
1. Click **Add Google Account**.
2. Complete the Google OAuth authentication and grant the requested permissions.
3. Upon redirection to `/dashboard/providers/google`, the account appears under **Connected Accounts** with status `connected`.

### Step 4.4: Creating Email Identity (Queues Discovery & Backfill)
> [!IMPORTANT]
> OAuth linkage alone does **not** begin syncing email! You must create an Email Identity tied to the Google account:
1. In the Kurrier navigation menu, go to **Dashboard → Identities** (or `/dashboard/identities`).
2. Click **Add Email Identity**.
3. In the modal form, select the connected **Google account** from the provider dropdown.
4. Set Display Name (optional) and Daily Quota.
5. Click **Add Email Identity** (or Submit).
6. Kurrier saves the identity and immediately enqueues two background BullMQ jobs to Redis:
   - `gmail:backfill-discover`: Discovers Gmail labels, folders, and message identifiers.
   - `gmail:backfill-account`: Streams message headers, bodies, and attachments into Postgres and Garage object storage.

### Step 4.5: Verifying Initial Sync
1. **Monitor Worker Logs**:
   Observe initial label discovery, backfill paging, and completion:
   ```bash
   docker compose logs -f worker | grep -E "\[GMAIL\]|gmail:backfill"
   ```
   Expected source-accurate log flow:
   ```text
   [GMAIL] Discovered 14 labels for user@example.com
   [GMAIL] gmail:backfill-discover <jobId> completed
   [GMAIL] Backfill started for user@example.com from historyId=123456
   [GMAIL] Backfill page done for user@example.com: inserted=50, skipped=0, bytes=..., remainingQuota=..., next=true
   [GMAIL] Backfill completed for user@example.com; queued delta catch-up
   [GMAIL] gmail:backfill-account <jobId> completed
   ```
2. **Verify Database Mailbox Records**:
   ```bash
   docker compose exec postgres psql -U postgres -d postgres -c "SELECT id, name, slug, kind FROM mailboxes;"
   ```
   Confirm system mailboxes (`inbox`, `sent`, `drafts`, `trash`, `archive`) exist for the Google identity.
3. **Verify Webmail Inbox**:
   Navigate to `http://localhost:3000/mail` (or `http://localhost:3000/`), select the newly created Google identity, and confirm that Gmail message threads and folder hierarchies appear in the UI.

---

## 5. Host Cutover Procedure

### Step 1: Update Repository on Host (Verified Fast-Forward Only)
Fetch latest commits and advance the local branch with strict fast-forward verification:
```bash
cd /path/to/kurrier
git fetch origin

# Switch to mek and ensure local branch fast-forwards strictly to origin/mek
git checkout mek
git pull --ff-only origin mek

# Verify exact head SHA against the merged pull request commit:
echo "Current commit: $(git rev-parse HEAD)"
# Expected: matches merged PR head commit SHA on origin/mek
```

### Step 2: Stop and Disable Existing UI-Only Preview Systemd Service
The preview host runs the UI preview as a systemd unit (`kurrier-ui.service`). Stop and disable it to release port 3000 and prevent port conflicts on reboot:
```bash
# Set preview service name (substitute if named differently in host environment):
PREVIEW_SERVICE="${PREVIEW_SYSTEMD_SERVICE:-kurrier-ui.service}"

echo "Stopping preview systemd service: $PREVIEW_SERVICE"
sudo systemctl stop "$PREVIEW_SERVICE"
sudo systemctl disable "$PREVIEW_SERVICE"

# Verify port 3000 is free:
sudo ss -tulpn | grep :3000 || echo "✅ Port 3000 is free"
```

### Step 3: Launch the Full Stack
From the `db` directory:
```bash
cd /path/to/kurrier/db
docker compose up -d
```

### Step 4: Monitor Database Bootstrap
Follow the bootstrap migration logs to ensure successful execution:
```bash
docker compose logs -f migrate
```
Expected output:
```text
✅ Postgres is ready.
🧩 Ensuring auth schema and database roles exist...
🧩 Ensuring migrations table exists...
🚀 Applying new migrations from /scripts/migrations...
🟢 Running 001_migration.sql ...
🟢 Running 002_migration.sql ...
...
🟢 Running 008_migration.sql ...
✅ All migrations done.
✅ Bootstrap complete.
```
The `migrate` container will exit with code 0 once complete. `web` and `worker` will then automatically launch.

### Step 5: Initial Workspace Admin Registration & Disabling Public Signup

1. **Register the Initial Workspace Owner**:
   Because Kurrier does not seed default credentials, open:
   ```text
   https://mail.example.com/en/auth/signup
   ```
   (or click "Create an account" on `/auth/login`).
   Enter your administrator email, a secure password, and workspace name (e.g. `Silicon Familiar`). This first registration establishes the workspace and assigns owner permissions to this account.

2. **Lock Down Public Signup**:
   To prevent unauthorized user registrations across your network or tailnet, lock down signup once the owner account is registered:
   Edit `/path/to/kurrier/db/.env` and set:
   ```bash
   DISABLE_SIGNUP=true
   ```
   Recreate the web container so Docker Compose injects the updated environment variable:
   ```bash
   docker compose up -d --force-recreate web
   ```
   *(Note: `--force-recreate web` updates only the web UI container with the new setting without interrupting PostgreSQL, Redis, or other backing services).*

3. **Verify Signup Lockdown**:
   Confirm that the signup route now redirects with `signup_disabled`:
   ```bash
   curl -s -i http://localhost:3000/en/auth/signup | grep -E "HTTP/|location:"
   ```
   **Expected**: HTTP `307 Temporary Redirect` to `/en/auth/login?message=signup_disabled`.

   Confirm that the login route continues to return HTTP 200:
   ```bash
   curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:3000/en/auth/login
   ```
   **Expected**: `200`.

---

## 6. Health Checks & Verification

Run the following checks on the host to verify system health:

### 1. Container Status Check
```bash
docker compose ps
```
**Expected**: All background services (`web`, `worker`, `postgres`, `redis`, `typesense`, `garage`, `baikal-postgres`, `dav`) display `Up` / `healthy`. The `migrate` container displays `Exited (0)`.

### 2. Core Postgres Database Health
```bash
docker compose exec postgres pg_isready -U postgres -d postgres
```
**Expected**: `postgres:5432 - accepting connections` (Exit code: `0`).

### 3. Baikal Postgres Database Health
```bash
docker compose exec baikal-postgres pg_isready -U baikal -d baikal
```
**Expected**: `baikal-postgres:5432 - accepting connections` (Exit code: `0`).

### 4. Redis Cache Health
Extract the configured Redis password directly from `.env` (since `docker compose` does not export environment variables into the host shell):
```bash
REDIS_PW=$(grep -E '^REDIS_PASSWORD=' .env | head -n1 | cut -d= -f2- | tr -d '\r"')
docker compose exec redis redis-cli -a "$REDIS_PW" ping
```
**Expected**: `PONG` (Exit code: `0`).

### 5. Typesense Search Health
```bash
curl -fsS http://127.0.0.1:8108/health
```
**Expected**: `{"ok":true}`.

### 6. Garage S3 Endpoint Health
```bash
curl -fsS http://127.0.0.1:3900
```
**Expected**: Returns an S3 XML response (e.g. `<ListAllMyBucketsResult>` or `AccessDenied`), confirming the service is listening.

### 7. Web UI Availability & Signup Lockdown
Verify that the login route is available:
```bash
curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:3000/auth/login
```
**Expected**: `200` (or `307` redirecting to `/en/auth/login` which returns `200`).

Verify that public registration is locked down (when `DISABLE_SIGNUP=true`):
```bash
curl -s -i http://localhost:3000/en/auth/signup | grep -i location
```
**Expected**: `location: /en/auth/login?message=signup_disabled` (HTTP 307).

### 8. Worker Proxy Health (Next.js Proxy to Nitro Worker)
Verify that the Next.js API proxy route connects to the worker rather than failing with HTTP 500:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/api/kurrier/me
```
**Expected**: `401` (`Unauthorized: Missing or invalid Authorization header`).
*(Context: Next.js proxies `/api/kurrier/*` directly to `${WORKER_URL}/api/kurrier/*`. When the worker service is absent or down, Next.js returns HTTP 500. Receiving HTTP 401 proves the worker is healthy, receiving proxied traffic from Next.js, and enforcing authentication. With a valid Bearer token, it returns `200` with user details).*

---

## 7. Rollback Plan

If unexpected cutover or runtime issues occur, roll back cleanly without destroying data:

### Step 1: Shut Down Full Stack
```bash
cd /path/to/kurrier/db
docker compose down
```

### Step 2: Restore Previous `.env`
Restore the specific pre-cutover configuration file directly (never rely on ambiguous shell globs like `*.backup.*`):
```bash
# Restore from canonical pre-cutover backup:
cp .env.pre-cutover .env

# Or restore using the exact timestamped backup name recorded during preparation:
# cp .env.backup.<TIMESTAMP> .env
```

### Step 3: Quarantine & Preserve Stack State (Do Not Blindly Wipe)
If the new stack encountered data or runtime errors, do not blindly delete volume directories with `rm -rf`. Instead, quarantine the runtime data directories by renaming them into a timestamped directory, preserving their relative directory paths so separate volume mounts (such as `./data` and `./garage/data`) cannot collide:
```bash
QUARANTINE_DIR="./quarantine_$(date +%Y%m%d%H%M%S)"
for dir in ./data ./redis_data ./typesense-data ./garage/data ./garage/meta ./baikal-data ./dav_data; do
  if [ -d "$dir" ]; then
    mkdir -p "$QUARANTINE_DIR/$(dirname "$dir")"
    mv "$dir" "$QUARANTINE_DIR/$dir"
  fi
done
echo "Attempted stack state safely quarantined in $QUARANTINE_DIR"
```

### Step 4: Re-enable and Restart UI-Only Preview Systemd Service
Re-enable and restart the original preview systemd service:
```bash
PREVIEW_SERVICE="${PREVIEW_SYSTEMD_SERVICE:-kurrier-ui.service}"
sudo systemctl enable "$PREVIEW_SERVICE"
sudo systemctl start "$PREVIEW_SERVICE"
sudo systemctl status "$PREVIEW_SERVICE" --no-pager
```

### Step 5: Verify Preview Health
```bash
curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:3000/auth/login
```
**Expected**: `200`.
