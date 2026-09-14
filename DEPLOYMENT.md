# Deployment & Cutover Guide: Moving to Full Gmail-Capable Stack

This guide provides concrete host instructions for transitioning an existing UI-only preview deployment to a full, self-hosted, Gmail-capable Kurrier stack using Docker Compose.

---

## 1. Architectural Overview & Changes

The existing preview environment runs only the web frontend (`kurrier-web`), with API routes proxying to a backend worker (`http://worker:3001`) that was previously absent, resulting in HTTP 500 errors on API requests.

The full stack introduces:
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

1. **Create a Timestamped Backup of `.env`**:
   ```bash
   cp /path/to/kurrier/db/.env /path/to/kurrier/db/.env.backup.$(date +%Y%m%d%H%M%S)
   ```

2. **Verify Required Secret Variables**:
   Ensure the following keys are preserved with their original values in `db/.env`:
   - `JWT_SECRET`: Used for session authentication tokens.
   - `APP_SECRET_ENCRYPTION_KEY`: AES encryption key for Vault secrets.
   - `REDIS_PASSWORD`: Password for Redis authentication.
   - `POSTGRES_PASSWORD`: Postgres superuser password.
   - `DATABASE_URL`: `postgresql://postgres:<POSTGRES_PASSWORD>@postgres:5432/postgres`
   - `DATABASE_RLS_URL`: `postgresql://kurrier:<POSTGRES_PASSWORD>@postgres:5432/postgres`

3. **Confirm Additional Variables**:
   Ensure the following additions are present in `db/.env`:
   ```bash
   BAIKAL_POSTGRES_PASSWORD=strong_baikal_password
   GOOGLE_MAIL_CLIENT_ID=
   GOOGLE_MAIL_CLIENT_SECRET=
   ```

---

## 3. Google Cloud OAuth Prerequisites & Setup Sequence

Before connecting Gmail or Google Workspace accounts, you must create and register an OAuth 2.0 Web Application in the Google Cloud Console.

> [!WARNING]
> **No Usable OAuth Link Prior to Configuration**:
> The interactive "Add Google Account" authorization link (`/api/oauth/google/connect`) requires valid Google OAuth application credentials. If you click the link before configuring a Client ID and Client Secret, the server will raise an error (`Google Mail OAuth is not configured`). The Kurrier UI displays a configuration modal until credentials exist.

### Google Cloud Console Steps

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

### Applying Credentials to Kurrier

Choose one of two configuration methods:

- **Method A (Environment Variables - Recommended for Self-Hosting)**:
  Add the credentials to `db/.env`:
  ```bash
  GOOGLE_MAIL_CLIENT_ID=123456789-abcdef.apps.googleusercontent.com
  GOOGLE_MAIL_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxx
  ```
  Restart the stack (`docker compose restart web worker`).

- **Method B (Dashboard Vault)**:
  Log into Kurrier as a workspace admin, navigate to **Dashboard → Providers → Google**, click **Configure Google OAuth**, enter your Client ID and Client Secret, and click **Save**. Credentials will be stored in the workspace Vault.

Once credentials are saved, the dashboard activates the **Add Google Account** button.

---

## 4. Host Cutover & Start Procedure

### Step 1: Update Repository on Host
Fetch the updated `mek` branch containing the bootstrap and port fixes:
```bash
cd /path/to/kurrier
git fetch origin
git checkout mek
```

### Step 2: Stop Existing UI-Only Preview
Identify and stop the preview container:
```bash
# If running via standalone docker run:
docker stop kurrier-preview && docker rm kurrier-preview

# If running via compose in preview directory:
docker compose down
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
🟢 Running 001_migration ...
🟢 Running 002_migration ...
...
🟢 Running 008_migration ...
✅ All migrations done.
✅ Bootstrap complete.
```
The `migrate` container will exit with code 0 once complete. `web` and `worker` will then automatically launch.

---

## 5. Health Checks & Verification

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
```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" ping
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

### 7. Web UI Availability
```bash
curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:3000/auth/login
```
**Expected**: `200`.

### 8. Worker Proxy Health (Verify UI Proxy to Worker)
Verify that API routes no longer return HTTP 500:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/api/v1/health
```
**Expected**: `200` or valid API response (non-500).

---

## 6. Rollback Plan

If migration fails or stack stability issues arise:

### Step 1: Shut Down Full Stack
```bash
cd /path/to/kurrier/db
docker compose down
```

### Step 2: Restore Previous `.env`
```bash
cp .env.backup.* .env
```

### Step 3: (Optional) Revert Volumes
If database corruption occurred during initial testing, reset the local volume directories:
```bash
rm -rf ./data ./redis_data ./typesense-data ./garage/data ./garage/meta ./baikal-data ./dav_data
```

### Step 4: Relaunch UI-Only Preview
Restart the preview container:
```bash
docker run -d \
  --name kurrier-preview \
  --restart unless-stopped \
  -p 3000:3000 \
  --env-file .env \
  ghcr.io/kurrier-org/kurrier-web:v4.1.0
```

### Step 5: Verify Preview Health
```bash
curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:3000/auth/login
```
**Expected**: `200`.
