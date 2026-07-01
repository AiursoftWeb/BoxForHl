# BoxForHlart ⚙️

**Role:** Hlart Node Management & Service Hosting

This repository contains the configuration and deployment logic for the **Hlart Server** of the Aiursoft Hybrid Cloud.

## 🎯 Strategic Objective
To provide a self-contained, high-performance environment for hosting services on the Hlart server, with full integration for FRP, Authentik, and Vikunja.

## 🏗 Architecture Specifics
*   **Infrastructure:** Built on top of the Aiursoft Box project architecture.
*   **Network:** Uses FRP for tunneling and Caddy for domain management.
*   **Authentication:** Fully integrated with Authentik for centralized identity management.
*   **Services:** Currently hosts Vikunja as the primary task management platform.
*   **Domains:** All services are hosted under the `hlwuxi.com` domain.

## 📦 Stacks Included
*   **Stage 0:** Local Registry for bootstrapping.
*   **Stage 1:** Image Mirroring for essential services.
*   **Stage 2:** Network infrastructure (Caddy, FRP, PySyncer).
*   **Stage 3:** Advanced registries and Identity management (Zot, Puller, Authentik).
*   **Stage 4:** Business applications (Vikunja, StatHub, Tracer, etc.).

## 🚀 Deployment
Run `./deploy.sh` to start the deployment process. Ensure your `.env` file is properly configured.

---

## 📐 Authoring Paradigms

This project enforces a strict set of conventions for all `docker-compose.yml` and Caddy `.conf` files. Every new service **must** follow these paradigms exactly.

---

### 1. Compose File Version

Always use version `3.9`.

```yaml
version: '3.9'
```

---

### 2. Service Field Order

Fields inside each service block must appear in this canonical order (omit fields that are not needed):

```yaml
services:
  my-service:
    depends_on:      # 1. dependencies first
    image:           # 2. image
    volumes:         # 3. volumes
    environment:     # 4. environment
    networks:        # 5. networks
    ports:           # 6. ports (only if truly needed — see §6)
    healthcheck:     # 7. healthcheck (databases and long-start services)
    command:         # 8. command / entrypoint override
    stop_grace_period: # 9. grace period
    deploy:          # 10. deploy block (always last)
```

---

### 3. Image Naming

All images **must** be pulled from the local registry mirror, never directly from Docker Hub.

```yaml
image: hub.hlwuxi.com/<original-path>:<tag>

# Examples
image: hub.hlwuxi.com/mysql
image: hub.hlwuxi.com/vikunja/vikunja:latest
image: hub.hlwuxi.com/ghcr.io/goauthentik/proxy:2026.2.1
```

Exception: bootstrap-phase images (before the hub is available) use `localhost:8080/...`.

---

### 4. Volume Pattern

Every named volume **must** be a bind-mount backed by a path under `/swarm-vol/`. Anonymous volumes and plain named Docker volumes are forbidden.

```yaml
# In service definition:
volumes:
  - my-volume:/container/path

# In top-level volumes block:
volumes:
  my-volume:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/<stack-name>/<purpose>
```

Path convention: `/swarm-vol/<stack-name>/<purpose>`, e.g. `/swarm-vol/stathub-data/mysql`.

Direct host paths (e.g. `/var/run/docker.sock`, `/etc/localtime`) are allowed inline without a named volume declaration.

---

### 5. Network Pattern

There are four well-known external networks. Assign networks according to this table:

| Network | Type | Usage |
| --- | --- | --- |
| `proxy_app` | external | Service must be reachable by Caddy (the reverse proxy) |
| `internal` | `driver: overlay` (local to stack) | Inter-service communication within the same stack |
| `frp_net` | external | Expose a port through the FRP tunnel |
| `clickhouse_net` | external | Connect to the ClickHouse logging cluster |

Rules:

* **Database / cache services** (`db`, `redis`, `postgresql`) get **only** `internal`. They are never attached to `proxy_app`.
* **Application services** that are reverse-proxied get **both** `proxy_app` and `internal`.
* **Application services** that ship logs to ClickHouse also get `clickhouse_net`.
* `internal` is always declared locally: `driver: overlay`. All other networks are `external: true`.

```yaml
# Top-level networks block example
networks:
  proxy_app:
    external: true
  clickhouse_net:
    external: true
  internal:
    driver: overlay
```

---

### 6. How to Expose a Service

#### 6a. Exposing a Web Service (the easy path)

For any HTTP-based service, **do not publish ports 80 or 443**. Caddy is already listening on those ports on the host and handles all TLS termination. The only thing needed is:

1. Attach the service to the `proxy_app` network.
2. Create a `<stack>.conf` file with a `reverse_proxy` block pointing at the container (see §14).

Caddy will pick up the new `.conf` file on next deploy and start routing traffic. No port mapping, no firewall changes.

#### 6b. Exposing a Non-HTTP Port (the painful path)

Exposing a raw TCP/UDP port (e.g. SSH, PostgreSQL) requires **two things** to work together:

**Step 1 — Publish the port on the Swarm node** (so the host OS listens):

```yaml
ports:
  - target: 2202
    published: 2202
    protocol: tcp
    mode: host
```

**Step 2 — Add an FRP inbound rule** so external traffic is tunneled from the public IP to this port via `frp_net`. The service must also be attached to `frp_net`.

Both steps are required. Publishing the port alone only makes it reachable on the private node IP. Adding FRP alone has nothing to forward to. If either is missing, the port will not be reachable externally.

Always use the long-form port syntax with `mode: host`.

---

### 7. Secret / Credential Syntax

Two distinct placeholder styles are used — **never mix them up**:

| Style | Example | Meaning |
| --- | --- | --- |
| `{{UPPER_SNAKE_CASE}}` | `{{STATHUB_CLIENT_SECRET}}` | External secret — injected from outside the repo (Authentik client ID/secret, API tokens, SMTP passwords). These must never be committed as plaintext. |
| `<lower_snake_case>` | `<stathub_password>` | Intra-stack shared credential — a password generated once and used by both the app and its database within the same compose file. Not externally injected, but must be consistent across the services that share it. |

```yaml
# External secret (OIDC, tokens, etc.)
- AppSettings__OIDC__ClientSecret={{STATHUB_CLIENT_SECRET}}

# Intra-stack password (app ↔ db, same file)
- MYSQL_PASSWORD=<stathub_password>
- ConnectionStrings__DefaultConnection=Server=db;...Pwd=<stathub_password>;
```

---

### 8. `stop_grace_period`

| Service type | Value |
| --- | --- |
| Stateful (databases, apps with in-flight state) | `60s` |
| Stateless / proxy / sidecar services | `20s` |

---

### 9. Healthcheck Pattern

Healthchecks are required for all database services and any service that other services `depends_on`.

**MySQL:**

```yaml
healthcheck:
  test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root --silent"]
  start_period: 20s
  interval: 30s
  retries: 5
  timeout: 5s
```

**PostgreSQL:**

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
  start_period: 20s
  interval: 30s
  retries: 5
  timeout: 5s
```

**HTTP service:**

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:<port>/health || exit 1"]
  start_period: 30s
  interval: 30s
  retries: 3
  timeout: 10s
```

---

### 10. `deploy` Block

Every service **must** have a `deploy` block. The structure is:

```yaml
deploy:
  labels:
    shepherd.autoupdate: "true"   # Omit only for locally-built images (localhost:8080/box_starting/...)
  resources:
    limits:
      cpus: '<n>.0'
      memory: <N>G   # Use M for values under 1G
  update_config:
    order: stop-first   # or start-first — see rule below
    delay: 60s          # or 5s — see rule below
```

**`update_config` rule:**

| Service character | `order` | `delay` |
| --- | --- | --- |
| Stateful (database, persistent app) | `stop-first` | `60s` |
| Stateless / proxy / sidecar | `start-first` | `5s` |

**`shepherd.autoupdate` rule:** Only add this label when the image comes from `hub.hlwuxi.com`. Locally-built images must **not** have this label since shepherd cannot update them.

---

### 11. MySQL Database Service Pattern

```yaml
db:
  image: hub.hlwuxi.com/mysql
  volumes:
    - <app>-db:/var/lib/mysql
  environment:
    - MYSQL_RANDOM_ROOT_PASSWORD=true
    - MYSQL_DATABASE=<dbname>
    - MYSQL_USER=<dbuser>
    - MYSQL_PASSWORD=<app_password>
  networks:
    - internal
  stop_grace_period: 60s
  healthcheck:
    test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root --silent"]
    start_period: 20s
    interval: 30s
    retries: 5
    timeout: 5s
  deploy:
    labels:
      shepherd.autoupdate: "true"
    resources:
      limits:
        cpus: '2.0'
        memory: 4G
    update_config:
      order: stop-first
      delay: 60s
```

Always use `MYSQL_RANDOM_ROOT_PASSWORD=true`. Never hardcode the root password.

---

### 12. Aiursoft ASP.NET Core App Pattern

Aiursoft apps (StatHub, Tracer, EmployeeCenter, OllamaGateway, …) share a common env-var shape:

```yaml
environment:
  - ConnectionStrings__DefaultConnection=Server=db;Database=<db>;Uid=<user>;Pwd=<app_password>;
  - ConnectionStrings__DbType=MySql
  - Storage__Path=/data/files
  - AppSettings__AuthProvider=OIDC
  - AppSettings__OIDC__Authority=https://auth.hlwuxi.com/application/o/<app-slug>
  - AppSettings__OIDC__ClientId={{APP_CLIENT_ID}}
  - AppSettings__OIDC__ClientSecret={{APP_CLIENT_SECRET}}
  - Logging__Clickhouse__Enabled=true
  - Logging__Clickhouse__ConnectionString=Host=clickhouse;User=default;Password=123456;Database=AspNetCoreLogs
  - Logging__Clickhouse__TableName=<AppName>Logs
```

Standard volumes:

```yaml
volumes:
  - <app>-aspnet:/data/.aspnet/
  - <app>-files:/data/files
```

The app service connects to `proxy_app`, `internal`, and `clickhouse_net`.

---

### 13. Authentik Proxy Sidecar Pattern

For services that do **not** have native OIDC support, add an `authentik_proxy` sidecar and protect the route in Caddy.

**In `docker-compose.yml`:**

```yaml
authentik_proxy:
  image: hub.hlwuxi.com/ghcr.io/goauthentik/proxy:2026.2.1
  environment:
    AUTHENTIK_HOST: "https://auth.hlwuxi.com/"
    AUTHENTIK_INSECURE: "false"
    AUTHENTIK_TOKEN: "{{APP_OUTPOST_TOKEN}}"
  stop_grace_period: 20s
  networks:
    - proxy_app
    - internal
  deploy:
    labels:
      shepherd.autoupdate: "true"
    resources:
      limits:
        cpus: '2.0'
        memory: 2G
    update_config:
      order: start-first
      delay: 5s
```

**In `<stack>.conf` (Caddy):**

```caddyfile
domain.hlwuxi.com {
    log
    import hsts
    encode br gzip

    route {
        reverse_proxy /outpost.goauthentik.io/* http://<stack>_authentik_proxy:9000 {
            header_up Host {http.reverse_proxy.upstream.host}
        }

        forward_auth http://<stack>_authentik_proxy:9000 {
            uri /outpost.goauthentik.io/auth/caddy
            copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider X-Authentik-Meta-App X-Authentik-Meta-Version
        }

        reverse_proxy http://<stack>_<service>:<port> {
        }
    }
}
```

---

### 14. Caddy Reverse Proxy Config Pattern

Every service exposed to the internet gets a `<stack>.conf` file placed in `stage4/stacks/<stack>/`. The file is included by the Caddy container.

Standard block (no auth proxy needed):

```caddyfile
domain.hlwuxi.com {
    log
    import hsts
    encode br gzip
    reverse_proxy http://<stack>_<service>:<port>
}
```

Naming rule: the upstream hostname inside Caddy follows Docker Swarm's DNS convention: `<stack-name>_<service-name>`, e.g. `stathub_app`, `vikunja_db`.

---

### 15. Shepherd Auto-Update Label

Add `shepherd.autoupdate: "true"` to the `deploy.labels` of every service whose image comes from `hub.hlwuxi.com`. Do **not** add it for locally-built images (`localhost:8080/box_starting/...`) because shepherd cannot pull those.

---

### 16. Project Directory Structure & Stage System

The repository is organized into five sequential stages. Each stage is deployed in order by `deploy.sh` and builds upon the previous one.

```
.
├── stage0/                 # Bootstrap: local Docker registry
│   └── registry/
├── stage1/                 # Image mirroring: pull public images into local registry
│   └── mirror.sh
├── stage2/                 # Network infrastructure
│   ├── images/             #   Custom Dockerfiles (ubuntu, caddy, frp, pysyncer)
│   └── stacks/             #   Stack definitions (incoming proxy)
├── stage3/                 # Advanced registries & Identity
│   ├── images/             #   Custom Dockerfiles (zot, puller)
│   └── stacks/             #   Stack definitions (zot, puller, authentik)
├── stage4/                 # Business applications
│   ├── images/             #   Custom Dockerfiles (runner)
│   └── stacks/             #   Stack definitions (all business services)
├── deploy.sh               # Main deployment script
├── lint.py                 # Compose file validation
├── alldrop.sh              # Teardown all stacks
├── .env                    # Environment variables (template placeholders)
└── .gitlab-ci.yml          # CI pipeline definition
```

**Stage dependencies:** Stage 0 starts a local registry → Stage 1 mirrors public images into it → Stage 2 deploys Caddy + FRP networking → Stage 3 deploys Authentik + Zot registry → Stage 4 deploys all business apps.

---

### 17. Stack File Organization

Each stack lives in its own directory and follows this convention:

```
stage<N>/stacks/<stack-name>/
├── docker-compose.yml      # Stack definition (required)
├── <stack-name>.conf       # Caddy reverse proxy config (required if web-exposed)
└── ...                     # Optional: config overrides, prometheus configs, etc.
```

Rules:

* The directory name **is** the stack name. E.g., `stage4/stacks/stathub/` → stack name = `stathub`.
* The `.conf` file name **must** match the directory name: `stage4/stacks/stathub/stathub.conf`.
* Custom images for a stage go in `stage<N>/images/<image-name>/`, not inside `stacks/`.

---

### 18. Container DNS Resolution

Docker Swarm assigns DNS names using the pattern `<stack>_<service>`. This is how containers address each other within the swarm network. This naming convention is critical in Caddy configs and inter-service communication.

```
# Compose service definition
services:
  app:           # service name: app
# Stack name: vikunja (from directory name)

# DNS name within the swarm:
# → vikunja_app
```

In Caddy `.conf` files, always use this DNS name for `reverse_proxy` targets:

```caddyfile
reverse_proxy http://vikunja_app:3456
reverse_proxy http://ai_ollama-gateway-app:5000
reverse_proxy http://stathub_app:80
```

---

### 19. PostgreSQL Database Service Pattern

```yaml
postgresql:
  image: hub.hlwuxi.com/postgres:16-alpine
  volumes:
    - <app>-database:/var/lib/postgresql/data
  environment:
    - POSTGRES_PASSWORD=<app_pg_password>
    - POSTGRES_USER=<dbuser>
    - POSTGRES_DB=<dbname>
  networks:
    - internal
  stop_grace_period: 60s
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
    start_period: 20s
    interval: 30s
    retries: 5
    timeout: 5s
  deploy:
    labels:
      shepherd.autoupdate: "true"
    resources:
      limits:
        cpus: '4.0'
        memory: 8G
    update_config:
      order: stop-first
      delay: 60s
```

Note: The `$$` double-dollar escape is required in `docker-compose.yml` to prevent Compose from interpreting `${POSTGRES_DB}` as a variable substitution. PostgreSQL's environment variables use `UPPER_SNAKE_CASE`.

---

### 20. Redis Cache Service Pattern

```yaml
redis:
  image: hub.hlwuxi.com/redis:alpine
  volumes:
    - <app>-redis:/data
  networks:
    - internal
  stop_grace_period: 60s
  command: --save 60 1 --loglevel warning
  healthcheck:
    test: ["CMD-SHELL", "redis-cli ping | grep PONG"]
    start_period: 20s
    interval: 30s
    retries: 5
    timeout: 3s
  deploy:
    resources:
      limits:
        cpus: '2.0'
        memory: 4G
    update_config:
      order: stop-first
      delay: 60s
```

Redis is used primarily by Authentik for session and cache storage. It is attached **only** to the `internal` network.

---

### 21. GPU Configuration Pattern

Services requiring NVIDIA GPUs (Ollama, OCR) must declare GPU resources via `generic_resources` in the `deploy.resources.reservations` block. The host must have `nvidia-container-runtime` configured.

```yaml
deploy:
  resources:
    limits:
      cpus: '8.0'
      memory: 50G
    reservations:
      generic_resources:
        - discrete_resource_spec:
            kind: "NVIDIA-GPU"
            value: 0
        - discrete_resource_spec:
            kind: "NVIDIA-GPU"
            value: 1
```

GPU-using services also commonly set these Ollama environment variables for optimal performance:

```yaml
environment:
  - OLLAMA_FLASH_ATTENTION=1
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - OLLAMA_KEEP_ALIVE=-1
  - OLLAMA_HOST=0.0.0.0
```

**Important:** The host ID (e.g., `Hlart-NUC`) in `env` files **must** match the hostname returned by `hostname -s` — this is how `deploy.sh` identifies which node gets GPU-constrained services.

---

### 22. Restart Policy Pattern

Use `deploy.restart_policy` for services that need automatic recovery. Choose the condition based on service criticality:

| `condition` | When to use | Example services |
| --- | --- | --- |
| `any` | Critical stateful services that must always run | ClickHouse, Ollama, OCR |
| `on-failure` | Worker/stateless services that should retry on crash but not on deliberate stop | ETL, sync, initializer, operation-engine |
| *(omitted)* | Services where Docker Swarm's default behavior is sufficient | Most stateless apps |

```yaml
# Critical stateful service
deploy:
  restart_policy:
    condition: any
    delay: 5s
    max_attempts: 3

# Worker/stateless retry-on-error
deploy:
  restart_policy:
    condition: on-failure
    delay: 10s
    max_attempts: 3
```

---

### 23. tmpfs Configuration

Memory-intensive services (AI/OCR) and CI runners use `tmpfs` to mount RAM-backed temporary filesystems, avoiding disk I/O for ephemeral data.

```yaml
# Shared memory for GPU/ML workloads
volumes:
  - type: tmpfs
    target: /dev/shm

# Large temp space for CI runners
tmpfs:
  - /tmp:size=4096m
```

Use `tmpfs` in the volumes list for `/dev/shm` mounts. Use the dedicated `tmpfs:` key for other paths when you need size limits (e.g., GitLab's `/tmp`).

---

### 24. deploy Block Field Order

Fields inside the `deploy` block must appear in this canonical order:

```yaml
deploy:
  mode: replicated          # 1. mode (only when set explicitly)
  replicas:                 # 2. replicas (only when > 2)
  labels:                   # 3. labels (shepherd.autoupdate)
  placement:                # 4. placement constraints (e.g., manager-only)
  resources:                # 5. resources
    limits:
      cpus: '<n>.0'
      memory: <N>G
    reservations:           #   5a. reservations (CPU/memory + GPU)
  update_config:            # 6. update_config
    order: stop-first | start-first
    delay: <duration>
  restart_policy:           # 7. restart_policy (only for non-default)
    condition: any | on-failure
    delay: <duration>
    max_attempts: <n>
```

---

### 25. Environment File Convention

The project supports two environment files:

| File | Priority | Purpose |
| --- | --- | --- |
| `.env.prod` | High | Production secrets (not committed to git) |
| `.env` | Fallback | Development / template (committed with placeholder values) |

`deploy.sh` substitutes `{{VARIABLE_NAME}}` placeholders in compose files with values from the active env file:

```bash
# .env file line:
STATHUB_CLIENT_ID=YOUR_STATHUB_CLIENT_ID_HERE

# docker-compose.yml before substitution:
- AppSettings__OIDC__ClientId={{STATHUB_CLIENT_ID}}

# After substitution (at deploy time):
- AppSettings__OIDC__ClientId=the-actual-client-id
```

**Rules:**

* Never commit real secrets to `.env`. The committed `.env` should only contain placeholder values (`YOUR_..._HERE`).
* Each variable must have exactly one definition; duplicate keys are not allowed.
* Placeholder names in compose files must match the env file key exactly (case-sensitive).
* `deploy.sh` creates a temporary copy of the compose file during substitution — originals are never modified.

---

### 26. Shell Script Standards

All shell scripts in this repository (`deploy.sh`, `alldrop.sh`, `mirror.sh`, `generate_compose.sh`, `build_proxy.sh`, entrypoint scripts) follow these conventions:

**Header:**
```bash
#!/bin/bash
set -euo pipefail    # Mandatory: exit on error, undefined var, pipe failure
```

**Color codes** (defined in `deploy.sh`, usable by all scripts):
```bash
export Green="\033[32m"
export Red="\033[31m"
export Yellow="\033[33m"
export Blue="\033[36m"
export Font="\033[0m"
export OK="${Green}[  OK  ]${Font}"
export ERROR="${Red}[FAILED]${Font}"
export WARNING="${Yellow}[ WARN ]${Font}"
export INFO="${Blue}[ INFO ]${Font}"
```

**Helper functions** (available in `deploy.sh`):

* `judge "<description>"` — Check the previous command's exit code; print OK or ERROR and exit on failure.
* `print_ok "<message>"` / `print_error "<message>"` / `print_warn "<message>"` / `print_info "<message>"` — Color-coded log output.

**Idempotency:** All scripts must be safe to run repeatedly. Use checks like `if ! command -v ...; then install; fi` and compare hashes before overwriting config files.

**Shepherd annotation:** Locally-built images must have a comment explaining why the shepherd label is omitted:
```yaml
# Do NOT auto redeploy this. Because this is built locally.
# Every time we run the deploy.sh will update the image.
```

---

### 27. Dockerfile Conventions

Custom Dockerfiles in `stage<N>/images/<name>/` follow these rules:

**Base images:** Always pull from the local registry (`localhost:8080/...`), never from Docker Hub directly.

```dockerfile
# Bootstrap base (stage 2+)
FROM localhost:8080/box_starting/local_ubuntu

# Mirrored public image
FROM localhost:8080/public_mirror/ubuntu:26.04
```

**Multi-stage builds:** Use `AS <stage-name>` to name build stages:
```dockerfile
FROM localhost:8080/public_mirror/caddy:builder AS caddy-build-env
# ... build steps ...

FROM localhost:8080/box_starting/local_ubuntu AS config-build-env
# ... config generation ...

FROM localhost:8080/public_mirror/caddy:latest
COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY --from=config-build-env /app/Dist/Caddyfile /etc/caddy/Caddyfile
```

**Image naming:**
* Locally-built images: `localhost:8080/box_starting/local_<name>:latest`
* Mirrored public images: `localhost:8080/public_mirror/<original-name>:<tag>`

---

### 28. CI/CD Pipeline

The `.gitlab-ci.yml` defines a single lint stage that validates all compose files against the conventions documented here:

```yaml
stages:
  - lint

lint-compose:
  stage: lint
  image: python:3.13
  before_script:
    - python3 -m pip install --disable-pip-version-check pyyaml
  script:
    - python3 ./lint.py
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
```

The lint job runs on:
* Every merge request (before merging)
* Every push to the default branch

To run the linter locally:
```bash
python3 ./lint.py
# Or with a specific target directory:
python3 ./lint.py ./stage4
```

The linter checks:
* Services connected to `frp_net` have matching entries in `frpc.toml` (and vice versa)
* Service type classification (stateful vs stateless) and validates corresponding `stop_grace_period`, `deploy.update_config.order`, and `deploy.update_config.delay` values

---

### 29. Adding a New Service — Checklist

When adding a new business service, follow this checklist in order:

1. **Create the stack directory:** `stage4/stacks/<stack-name>/`
2. **Write `docker-compose.yml`** following §2 (service field order), §10 (deploy block), and §24 (deploy field order)
3. **Image source:** Use `hub.hlwuxi.com/<path>` (§3). If the image is not yet mirrored, add it to `stage1/mirror.sh`
4. **Volumes:** Bind-mount under `/swarm-vol/<stack-name>/<purpose>` (§4)
5. **Networks:** Assign according to the network table (§5)
6. **Secrets:** Use `{{UPPER_SNAKE_CASE}}` for external secrets, `<lower_snake_case>` for intra-stack passwords (§7)
7. **Exposure:** If the service is web-facing, attach to `proxy_app` (§6a). If it needs a raw TCP port, publish with `mode: host` AND add an FRP proxy entry (§6b)
8. **Database:** Follow the MySQL (§11) or PostgreSQL (§19) pattern depending on the service's database type
9. **Aiursoft apps:** Follow the ASP.NET Core app pattern (§12)
10. **Authentik proxy:** If the service lacks native OIDC, add the Authentik sidecar pattern (§13)
11. **Write `<stack-name>.conf`:** Create the Caddy reverse proxy config (§14, §17)
12. **Healthcheck:** Add healthchecks for all `depends_on` sources (§9)
13. **Resource limits:** Set appropriate CPU/memory limits. Use `reservations` for GPU services (§21)
14. **`stop_grace_period`:** Stateful → `60s`, Stateless → `20s` (§8)
15. **`deploy.update_config`:** Stateful → `stop-first` / `60s`, Stateless → `start-first` / `5s` (§10)
16. **Shepherd label:** Add `shepherd.autoupdate: "true"` for hub images, omit for locally-built images (§15)
17. **Environment variables:** Add new `{{PLACEHOLDER}}` entries to `.env` (§25)
18. **Run the linter:** `python3 ./lint.py` to verify compliance (§28)
19. **Deploy:** Run `./deploy.sh --filter <stack-name>` for a targeted deploy, or `./deploy.sh` for a full deployment

---

## TODO

marktohtml.hlwuxi.com
vault.hlwuxi.com
minio.hlwuxi.com
litellm.hlwuxi.com

## Done

nextcloud.hlwuxi.com
uptime.hlwuxi.com
auth.hlwuxi.com
test.hlwuxi.com
clickhouse.hlwuxi.com
grafana.hlwuxi.com
hub.hlwuxi.com
vikunja.hlwuxi.com
tracer.hlwuxi.com
stathub.hlwuxi.com
employee.hlwuxi.com
ollama.hlwuxi.com
openweb.hlwuxi.com
ocr.hlwuxi.com
gitlab.hlwuxi.com
tty.hlwuxi.com
