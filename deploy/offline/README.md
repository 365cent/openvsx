# Open VSX Offline Deployment Guide

Deploy a self-hosted Open VSX registry on an air-gapped Ubuntu 22.04 LTS machine, complete with mirrored extensions from open-vsx.org.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Ubuntu 22.04 LTS                   │
│                                                     │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Web UI   │  │   Server     │  │  PostgreSQL  │  │
│  │ :3000    │──│   :8080      │──│  :5432       │  │
│  │ (Node)   │  │ (Spring Boot)│  │              │  │
│  └──────────┘  └──────────────┘  └──────────────┘  │
│                       │                             │
│                ┌──────┴───────┐                     │
│                │ Local Storage│                     │
│                │ (extensions) │                     │
│                └──────────────┘                     │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

**On the target (air-gapped) machine:**
- Ubuntu 22.04 LTS
- Docker CE 24+ and Docker Compose plugin
- 4+ GB RAM, 20+ GB disk (more if mirroring many extensions)

**On the build (internet-connected) machine:**
- Docker CE with buildx plugin
- Internet access to pull base images and build

## Quick Start

### Step 1: Build & Export (on internet-connected machine)

```bash
# Clone and build
cd openvsx/deploy/offline

# Build Docker images (from repo root)
cd ../../server && docker build -t openvsx-server:local .
cd ../webui && docker build -t openvsx-webui:local .
cd ../deploy/offline

# Pull PostgreSQL image
docker pull postgres:16.2

# Export all images as tarballs
bash export-images.sh
```

This creates `images/` directory with compressed tarballs (~500 MB total).

### Step 2: Sync Extensions (on internet-connected machine)

Before going offline, sync extensions from open-vsx.org into your local registry:

```bash
# Start the local registry first
bash deploy.sh

# Sync all extensions from open-vsx.org (this may take hours for the full registry)
bash sync-extensions.sh

# Or sync a limited number for testing
bash sync-extensions.sh --count 100

# Back up the database and extension files
bash backup-data.sh
```

### Step 3: Transfer to Target Machine

Copy the entire `offline/` directory to the target machine:

```
offline/
├── images/                          # Docker image tarballs
│   ├── openvsx-server_local.tar.gz
│   ├── openvsx-webui_local.tar.gz
│   └── postgres_16.2.tar.gz
├── backups/                         # Database + file backups
│   ├── openvsx-db-backup-*.sql.gz
│   └── openvsx-files-backup-*.tar.gz
├── config/
│   └── application.yml
├── docker-compose.yml
├── deploy.sh
├── import-images.sh
├── export-images.sh
├── sync-extensions.sh
├── backup-data.sh
└── restore-data.sh
```

Transfer methods:
- USB drive
- Internal file share
- `scp` / `rsync` over internal network

### Step 4: Deploy (on air-gapped target machine)

```bash
cd offline/

# Import Docker images
bash import-images.sh

# Start all services
bash deploy.sh

# Restore synced extension data
bash restore-data.sh backups/openvsx-db-backup-*.sql.gz backups/openvsx-files-backup-*.tar.gz
```

Open http://localhost:3000 in a browser.

## Mirroring Strategy

There are two approaches to make extensions available:

### Approach A: Pre-sync (Recommended for Air-Gapped)

Sync extensions while you have internet access, then transfer the data:

1. Run `sync-extensions.sh` to download and publish extensions
2. Run `backup-data.sh` to create portable backups
3. Transfer backups to target machine
4. Run `restore-data.sh` on target

**Pros:** Fully offline after setup. Extensions served from local storage.  
**Cons:** Must re-sync to get updates. Large data transfer for full registry.

### Approach B: Upstream Proxy (For Networks with Restricted Access)

If the target machine can reach open-vsx.org (even through a proxy), configure
the server as an upstream proxy. Add to `config/application.yml`:

```yaml
ovsx:
  upstream:
    url: https://open-vsx.org
```

This transparently proxies requests for extensions not found locally to
open-vsx.org. Local extensions take priority.

**Pros:** Always up-to-date. No manual sync needed.  
**Cons:** Requires outbound internet to open-vsx.org.

### Approach C: Mirror Mode (Automatic Periodic Sync)

If you have periodic internet access, use the built-in mirror mode.
Replace `config/application.yml` with mirror-specific config:

```yaml
spring:
  profiles:
    include: ovsx, mirror

ovsx:
  data:
    mirror:
      enabled: true
      server-url: https://open-vsx.org
      requests-per-second: 5
      user-name: mirror_user
      schedule: '0/1 * * * *'    # sync every minute
      exclude-extensions:
        - vscode.*               # skip built-in VS Code extensions
  upstream:
    url: https://open-vsx.org
```

**Pros:** Automatic incremental sync. Keeps up-to-date.  
**Cons:** Requires internet access on a schedule.

## Configuration

### Environment Variables

Create a `.env` file next to `docker-compose.yml` to customize:

```env
POSTGRES_PASSWORD=your_secure_password
SERVER_PORT=8080
WEBUI_PORT=3000
POSTGRES_PORT=5432
```

### Application Settings

Edit `config/application.yml` for server settings. Key sections:

| Setting | Description | Default |
|---------|-------------|---------|
| `spring.datasource.*` | PostgreSQL connection | `postgres:5432/openvsx` |
| `ovsx.databasesearch.enabled` | Use DB for search (no Elasticsearch) | `true` |
| `ovsx.elasticsearch.enabled` | Use Elasticsearch for search | `false` |
| `ovsx.storage.local.directory` | Extension file storage path | `/tmp/extensions` |
| `ovsx.webui.url` | Public URL of the web UI | `http://localhost:3000` |
| `ovsx.upstream.url` | Upstream proxy URL (optional) | not set |

### OAuth (Optional)

For user authentication, configure GitHub OAuth:

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          github:
            client-id: YOUR_CLIENT_ID
            client-secret: YOUR_CLIENT_SECRET
```

Without OAuth, the registry operates in read-only mode (no user login, publishing via API token only).

## Operations

### Viewing Logs

```bash
docker compose logs -f          # all services
docker compose logs -f server   # server only
docker compose logs -f webui    # web UI only
docker compose logs -f postgres # database only
```

### Stopping / Starting

```bash
docker compose down             # stop all
docker compose up -d            # start all
docker compose restart server   # restart server only
```

### Health Checks

```bash
curl http://localhost:8080/actuator/health   # server health
curl http://localhost:8080/api/-/search      # API check
curl http://localhost:3000/                  # web UI check
```

### Updating

1. On the internet-connected machine, rebuild images from updated source
2. Run `export-images.sh` to create new tarballs
3. Transfer to target machine
4. Run `import-images.sh`
5. `docker compose up -d` (images will be replaced)

### Backup / Restore

```bash
# Backup
bash backup-data.sh

# Restore
bash restore-data.sh backups/openvsx-db-backup-TIMESTAMP.sql.gz backups/openvsx-files-backup-TIMESTAMP.tar.gz
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Server won't start | Check `docker compose logs server`. Ensure PostgreSQL is healthy first. |
| Web UI shows blank page | Ensure server is running. Check browser console for API errors. |
| Extensions not showing | Verify data was restored: `curl http://localhost:8080/api/-/search` |
| Out of disk space | Extension storage grows with synced extensions. Monitor with `docker system df`. |
| Database connection refused | Ensure postgres container is running and healthy. |

## VS Code / Compatible Editor Configuration

To use this registry with VS Code or compatible editors, configure the extension gallery URL:

```json
{
  "extensionsGallery": {
    "serviceUrl": "http://YOUR_SERVER:8080/vscode/gallery",
    "itemUrl": "http://YOUR_SERVER:3000/vscode/item"
  }
}
```

For [VSCodium](https://vscodium.com/), set the `VSCODE_GALLERY_SERVICE_URL` environment variable:

```bash
export VSCODE_GALLERY_SERVICE_URL="http://YOUR_SERVER:8080/vscode/gallery"
export VSCODE_GALLERY_ITEM_URL="http://YOUR_SERVER:3000/vscode/item"
```
