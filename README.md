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

## TODO

gitlab.chopinsight.cn
marktohtml.chopinsight.cn
ocr.chopinsight.cn
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
