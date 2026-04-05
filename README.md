# BoxForChopart ⚙️

**Role:** Chopart Node Management & Service Hosting

This repository contains the configuration and deployment logic for the **Chopart Server** of the Aiursoft Hybrid Cloud.

## 🎯 Strategic Objective
To provide a self-contained, high-performance environment for hosting services on the Chopart server, with full integration for FRP, Authentik, and Vikunja.

## 🏗 Architecture Specifics
*   **Infrastructure:** Built on top of the Aiursoft Box project architecture.
*   **Network:** Uses FRP for tunneling and Caddy for domain management.
*   **Authentication:** Fully integrated with Authentik for centralized identity management.
*   **Services:** Currently hosts Vikunja as the primary task management platform.
*   **Domains:** All services are hosted under the `chopinsight.cn` domain.

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
image: hub.chopinsight.cn/<original-path>:<tag>

# Examples
image: hub.chopinsight.cn/mysql
image: hub.chopinsight.cn/vikunja/vikunja:latest
image: hub.chopinsight.cn/ghcr.io/goauthentik/proxy:2026.2.1
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

**`shepherd.autoupdate` rule:** Only add this label when the image comes from `hub.chopinsight.cn`. Locally-built images must **not** have this label since shepherd cannot update them.

---

### 11. MySQL Database Service Pattern

```yaml
db:
  image: hub.chopinsight.cn/mysql
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
  - AppSettings__OIDC__Authority=https://auth.chopinsight.cn/application/o/<app-slug>
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
  image: hub.chopinsight.cn/ghcr.io/goauthentik/proxy:2026.2.1
  environment:
    AUTHENTIK_HOST: "https://auth.chopinsight.cn/"
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
domain.chopinsight.cn {
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
domain.chopinsight.cn {
    log
    import hsts
    encode br gzip
    reverse_proxy http://<stack>_<service>:<port>
}
```

Naming rule: the upstream hostname inside Caddy follows Docker Swarm's DNS convention: `<stack-name>_<service-name>`, e.g. `stathub_app`, `vikunja_db`.

---

### 15. Shepherd Auto-Update Label

Add `shepherd.autoupdate: "true"` to the `deploy.labels` of every service whose image comes from `hub.chopinsight.cn`. Do **not** add it for locally-built images (`localhost:8080/box_starting/...`) because shepherd cannot pull those.

---

## TODO

marktohtml.chopinsight.cn
vault.chopinsight.cn
minio.chopinsight.cn
litellm.chopinsight.cn

## Done

nextcloud.chopinsight.cn
uptime.chopinsight.cn
auth.chopinsight.cn
test.chopinsight.cn
clickhouse.chopinsight.cn
grafana.chopinsight.cn
hub.chopinsight.cn
vikunja.chopinsight.cn
tracer.chopinsight.cn
stathub.chopinsight.cn
employee.chopinsight.cn
ollama.chopinsight.cn
openweb.chopinsight.cn
ocr.chopinsight.cn
gitlab.chopinsight.cn
