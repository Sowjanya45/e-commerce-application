# Running the E-Commerce Microservices Locally

A complete, step-by-step guide to getting the whole system running on your own machine with
Docker. Commands are given for **Windows PowerShell**; macOS/Linux equivalents are noted where
they differ.

- [1. What you will end up with](#1-what-you-will-end-up-with)
- [2. Prerequisites](#2-prerequisites)
- [3. Step-by-step setup](#3-step-by-step-setup)
- [4. Verify it works](#4-verify-it-works)
- [5. Calling the API](#5-calling-the-api)
- [6. Day-to-day usage](#6-day-to-day-usage)
- [7. URLs and ports](#7-urls-and-ports)
- [8. Databases and data persistence](#8-databases-and-data-persistence)
- [9. How configuration works](#9-how-configuration-works)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Running a single service from your IDE](#11-running-a-single-service-from-your-ide)

---

## 1. What you will end up with

About 20 containers on one Docker network:

```
                        ┌──────────── Keycloak (login / JWT) ────────────┐
Client ─► Gateway :8080 ┤                                                │
          (JWT check,   └─► user-service :8082 ───► MongoDB              │
           routing,         product-service :8081 ─► PostgreSQL (productdb)
           rate limit)      order-service :8083 ───► PostgreSQL (orderdb)
                               │   └─ calls product + user over HTTP
                               └─ publishes order events ─► Kafka ─► notification-service
Support: Eureka :8761 (discovery) · Config Server :8888 (config) · RabbitMQ (config refresh bus)
         · Redis (gateway rate limiting)
Observability: Prometheus · Grafana · Zipkin · Loki + Alloy (+ MinIO for Loki storage)
```

Every service gets its configuration from the Config Server at startup and registers itself in
Eureka. The Gateway validates the caller's Keycloak JWT before routing anything.

## 2. Prerequisites

| Need | Why | Check |
|---|---|---|
| **Docker Desktop** (Windows/macOS) or Docker Engine + Compose v2 (Linux) | Runs everything | `docker --version` |
| **JDK 21** | To build the service images (the project targets Java 21) | `java -version` → 21 |
| **~8 GB RAM free for Docker**, ~10 GB disk | ~20 containers; first run downloads several GB | Docker Desktop → Settings → Resources |
| Git | Clone the repo | `git --version` |

> **Use JDK 21, not a newer one.** Newer JDKs (e.g. 25) break Lombok annotation processing, so
> the `user`, `product`, `order` and `notification` builds fail with confusing errors. Having
> several JDKs installed side by side is fine — see step 2 below.

Free these host ports before starting (stop anything using them, e.g. a local Postgres or Mongo):
`5432, 27017, 5672, 15672, 9092, 2181, 8080, 8081*, 8761, 8888, 8443, 5050, 3000, 9090, 9411`.
(\* 8081–8083 are not published to the host by default; everything goes through the gateway.)

## 3. Step-by-step setup

### Step 1 — Get the code and create your `.env`

```powershell
git clone https://github.com/Sowjanya45/e-commerce-application.git
cd e-commerce-application\deploy\docker
Copy-Item .env.example .env        # macOS/Linux: cp .env.example .env
```

Open `deploy/docker/.env` and set `DB_USER` and `DB_PASSWORD` to whatever you like. They are
used to create the Postgres container **and** by the product/order services, so they always
match. Leave the other lines as they are — `mongo`, `rabbitmq` and `zipkin` are the container
names on the Docker network, which is how containers reach each other (inside a container,
`localhost` means *that* container).

| Variable | Used by | Value |
|---|---|---|
| `DB_USER`, `DB_PASSWORD` | postgres, product, order | your choice |
| `MONGO_URI` | user-service | `mongodb://mongo:27017/ecom_user` |
| `RABBITMQ_*` | config server, user, product | `rabbitmq`, `5672`, `guest`/`guest`, vhost `/` |
| `ZIPKIN_URL` | gateway, user, product, order | `http://zipkin:9411/api/v2/spans` |

`.env` is gitignored on purpose — never commit it.

### Step 2 — Install and select JDK 21

```powershell
winget install EclipseAdoptium.Temurin.21.JDK
```

Open a **new** terminal afterwards, then point that terminal at JDK 21 (this only affects the
current window, so your other JDKs are untouched):

```powershell
$env:JAVA_HOME = (Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Directory | Where-Object Name -like "jdk-21*" | Select-Object -First 1).FullName
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
java -version     # must report 21
```

macOS/Linux: install a JDK 21 (e.g. Temurin) and `export JAVA_HOME=<path>`.

### Step 3 — Build the service images

The compose file uses images named `dcode007/<service>`. Those on Docker Hub belong to the
original course author and may not match this code, so build your own. This builds into your
local Docker (nothing is pushed anywhere):

```powershell
cd <repo-root>
foreach ($m in "eureka","configserver","gateway","user","product","order","notification") {
  Push-Location $m
  .\mvnw.cmd clean compile jib:dockerBuild
  Pop-Location
}
```

macOS/Linux:

```bash
for m in eureka configserver gateway user product order notification; do
  (cd $m && ./mvnw clean compile jib:dockerBuild)
done
```

Look for `BUILD SUCCESS` seven times (the first run downloads Maven dependencies and is slow).
Then confirm:

```powershell
docker images | findstr dcode007      # should list 7 images (use grep on macOS/Linux)
```

### Step 4 — Start Keycloak first and configure it

Keycloak holds the logins. Its configuration is **not** automatic yet, so do it once before
starting the rest.

```powershell
cd deploy\docker
docker compose up -d keycloak
```

Wait ~30–60 seconds (the log line `Keycloak ... started` appears), then open
<http://localhost:8443> and log in as **`admin` / `admin`**. If the browser says
`ERR_EMPTY_RESPONSE`, Keycloak is still booting — wait and refresh.

**4a. Import the realm**

1. Top-left dropdown (shows *Keycloak* / *master*) → **Create realm**.
2. **Resource file → Browse** → select `deploy/docker/keycloak/realm-export-ecom-app.json`.
   The realm name fills in as `ecom-app`.
3. **Create**. You are now inside the `ecom-app` realm (check the top-left name).

This gives you the `oauth2-pkce` client and its `PRODUCT`, `ORDER`, `USER` roles. It contains
**no users**.

**4b. Create the service-account user** (used by `user-service` to create Keycloak accounts)

In realm `ecom-app`:

1. **Users → Create new user**. Username `user`. **Fill in Email, First name and Last name**
   (anything, e.g. `user@example.com` / `Service` / `Account`) and click **Create**.
   > Keycloak 26 refuses to log in accounts missing these fields ("Account is not fully set
   > up"), which would make user creation fail later.
2. **Credentials → Set password**: `user`, **Temporary = OFF**, Save.
3. **Role mapping → Assign role → Filter by clients**: tick `manage-users` and `view-users`
   (client **realm-management**) → Assign.

These must match `keycloak.admin.username/password` in
`configserver/src/main/resources/config/user-service*.yml` (`user` / `user` by default).

**4c. Create a test customer**

Same as 4b, with username `testuser` and a password of your choice (Temporary OFF, and fill in
Email / First / Last name). Under **Role mapping → Assign role → Filter by clients**, assign the
client roles of **`oauth2-pkce`**: `USER` and `ORDER`, plus `PRODUCT` if this account should be
able to create/update/delete products.

> Every account must have **at least one** `oauth2-pkce` client role. The gateway reads roles
> from the token's `resource_access.oauth2-pkce` claim; a token without it is rejected.

### Step 5 — Start everything else

```powershell
cd deploy\docker
docker compose up -d
```

The first run pulls many images and can take a while. If a pull is interrupted, just run the
command again. Services depend on the config server and Eureka, so some will restart a few
times while those come up — that is normal (`restart: on-failure`). Watch progress:

```powershell
docker compose ps
docker compose logs -f gateway-service
```

Allow **2–4 minutes** for everything to settle on the first start.

## 4. Verify it works

1. **Config server** — <http://localhost:8888/product-service/docker> returns JSON with the
   product-service properties.
2. **Eureka** — <http://localhost:8761> lists `GATEWAY-SERVICE`, `USER-SERVICE`,
   `PRODUCT-SERVICE`, `ORDER-SERVICE`. (`notification` does not register with Eureka — check
   `docker compose logs notification-service` instead.)
3. **All containers running** — `docker compose ps` shows nothing in `Restarting` for more than
   a minute or two.
4. **Gateway rejects anonymous calls** — `curl http://localhost:8080/api/products` returns
   `401`. That is correct: it proves the JWT check is on.

## 5. Calling the API

Everything goes through the gateway at `http://localhost:8080`; every request needs a Bearer
token from Keycloak.

### Get a token (PowerShell)

The `oauth2-pkce` client has direct access grants enabled, so the simplest way to get a token
for testing is the password grant:

```powershell
$resp = Invoke-RestMethod -Method Post `
  -Uri "http://localhost:8443/realms/ecom-app/protocol/openid-connect/token" `
  -Body @{ grant_type="password"; client_id="oauth2-pkce"; username="testuser"; password="<your password>" }
$token = $resp.access_token
```

curl equivalent:

```bash
curl -s -X POST http://localhost:8443/realms/ecom-app/protocol/openid-connect/token \
  -d grant_type=password -d client_id=oauth2-pkce -d username=testuser -d password='<your password>'
```

> Always fetch the token from `localhost:8443`, not `keycloak:8080`. The gateway only accepts
> tokens whose issuer is `http://localhost:8443/realms/ecom-app`.

### Call an endpoint

```powershell
Invoke-RestMethod http://localhost:8080/api/products -Headers @{ Authorization = "Bearer $token" }
```

An empty list `[]` means the whole chain works (gateway → Eureka → product-service →
PostgreSQL). Routes exposed by the gateway:

| Path | Service | Notes |
|---|---|---|
| `/api/products/**` | product | `POST/PUT/DELETE` require the `PRODUCT` role; `GET` needs any valid token |
| `/api/users/**` | user | |
| `/api/orders/**`, `/api/cart/**` | order | |

### Postman

Import `ecommerce.postman_collection.json`. To log in with the **Authorization Code (PKCE)**
flow from Postman you must first add Postman's callback
`https://oauth.pstmn.io/v1/callback` to **Clients → oauth2-pkce → Valid redirect URIs** in
Keycloak (the realm export only allows `http://localhost:5173/*`). Using the password grant
above avoids this.

## 6. Day-to-day usage

| Task | Command (from `deploy/docker`) |
|---|---|
| Stop everything, keep data | `docker compose stop` |
| Start again | `docker compose start` |
| See logs | `docker compose logs -f <service>` (e.g. `order-service`) |
| Restart one service | `docker compose restart order-service` |
| Rebuild one service after a code change | rebuild its image (step 3 for that module), then `docker compose up -d --force-recreate order-service` |
| Full reset (wipes Postgres data) | `docker compose down -v` |

> **Avoid `docker compose down`** for normal stops. Keycloak and MongoDB have no volumes, so
> `down` deletes the Keycloak realm/users and all user profiles, and you must redo step 4.
> Use `stop`/`start`.

## 7. URLs and ports

| What | URL | Login |
|---|---|---|
| API Gateway | <http://localhost:8080> | Bearer token |
| Eureka dashboard | <http://localhost:8761> | — |
| Config Server | <http://localhost:8888> | — |
| Keycloak admin | <http://localhost:8443> | `admin` / `admin` |
| pgAdmin | <http://localhost:5050> | `pgadmin4@pgadmin.org` / `admin` (or your `.env` values) |
| RabbitMQ management | <http://localhost:15672> | `guest` / `guest` |
| Grafana | <http://localhost:3000> | anonymous admin |
| Prometheus | <http://localhost:9090> | — |
| Zipkin | <http://localhost:9411> | — |
| PostgreSQL | `localhost:5432` | `DB_USER` / `DB_PASSWORD` |
| MongoDB | `localhost:27017` | none |

## 8. Databases and data persistence

| Service | Database | Container | Survives `down`? |
|---|---|---|---|
| product | PostgreSQL `productdb` | `postgres` | Yes (named volume) |
| order | PostgreSQL `orderdb` | `postgres` | Yes (named volume) |
| user | MongoDB `ecom_user` | `mongo` | **No** (no volume) |
| Keycloak | built-in H2 | `keycloak` | **No** (no volume) |

Tables are created automatically by Hibernate on first start (`ddl-auto: update`); the two
Postgres databases are created by `deploy/docker/init-multi-db.sql`.

Postgres reads `DB_USER`/`DB_PASSWORD` **only when its volume is first created**. If you change
them later, run `docker compose down -v` (this wipes Postgres data) and start again.

To inspect data:

- **pgAdmin** (<http://localhost:5050>): add a server with host `postgres`, port `5432`, and
  your `DB_USER`/`DB_PASSWORD`.
- **MongoDB Compass**: connect to `mongodb://localhost:27017`.

## 9. How configuration works

- Each service's own `application.yml` / `application-docker.yml` only contains its name and
  the Config Server address (`http://config-server:8888` in Docker).
- The real settings live in `configserver/src/main/resources/config/`:
  `<service>.yml` (non-Docker) and `<service>-docker.yml` (Docker profile — what compose uses).
- Compose mounts that folder into the config-server container, so **edits take effect after a
  restart** of the affected service (`docker compose restart <service>`), with no image rebuild.
- Live refresh without restarting is available through Spring Cloud Bus (RabbitMQ): call
  `POST http://localhost:8080/actuator/busrefresh` (see the Postman collection). Services have
  to be reachable for the actuator call; restarting is the simpler option locally.
- Secrets are injected from `.env` through compose `environment:` entries
  (`${DB_USER}` → container env → `${DB_USER}` in the YAML).

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERR_EMPTY_RESPONSE` at `localhost:8443` | Keycloak is still starting. Wait ~30–60 s, refresh. Check `docker logs keycloak`. |
| `pull access denied for minio/minio` | Official MinIO images were removed from Docker Hub. The compose file uses `bitnamilegacy/minio`; make sure you have the latest version of `docker-compose.yml`. |
| `container name "/kafka" is already in use` (or another name) | An old container from a different project has that name. Remove it: `docker rm kafka` (only if you don't need it). |
| `port is already allocated` | Something else uses that host port (a local Postgres/Mongo/Grafana, or another project's containers). Stop it or change the left-hand port in compose. |
| Build errors in `user`/`product`/`order`/`notification` mentioning Lombok / `TypeTag` | You are building with a JDK newer than 21. Redo step 2 in that terminal. |
| `no such image` / Docker tries to pull `dcode007/...` | You skipped step 3 (building the images). |
| Services stuck restarting | Usually waiting for the config server or Eureka. Give it a few minutes; then `docker compose logs <service>`. |
| Config-related startup failure (`Could not locate PropertySource`, or defaults used) | Config server not healthy: `docker compose logs config-server`, and check <http://localhost:8888/actuator/health>. |
| `401 Unauthorized` through the gateway | No/expired token, or token fetched from the wrong host. Fetch from `localhost:8443` (section 5); tokens expire after a few minutes. |
| `403 Forbidden` on product `POST/PUT/DELETE` | Your user lacks the `PRODUCT` client role. Assign it in Keycloak and fetch a **new** token. |
| Token request: *"Account is not fully set up"* | The Keycloak user is missing Email / First name / Last name. Fill them in. |
| Token request: *invalid_grant / Invalid user credentials* | Wrong password, or the password was saved as Temporary. |
| User creation via API fails | The `user` service account in realm `ecom-app` is missing or lacks `manage-users` / `view-users` (step 4b), or was lost after `docker compose down` — recreate it. |
| Realm/users disappeared | `docker compose down` was used. Redo step 4 and use `stop`/`start` from now on. |
| Gateway logs "Error determining if user allowed from redis" | The `redis` container isn't reachable. Check `docker compose ps redis` and that the gateway got the latest config (`docker compose restart gateway-service`). Requests are still allowed meanwhile (the limiter fails open). |
| Everything is slow / containers killed | Docker is out of memory. Raise it in Docker Desktop → Settings → Resources. |

## 11. Running a single service from your IDE

Useful for debugging one service while the rest run in Docker.

1. Start the infrastructure in Docker (postgres, mongo, rabbitmq, kafka, keycloak, eureka,
   config-server) as above, and stop the Docker copy of the service you will run yourself
   (`docker compose stop order-service`).
2. Run the service with JDK 21 **without** the `docker` profile. It will fetch config from
   `http://localhost:8888`.
3. The non-Docker config files in `configserver/.../config/*.yml` still use Docker hostnames
   (`postgres`, `eureka`, `kafka`, `keycloak`). From your host those names do not resolve. Add
   them to your hosts file pointing at `127.0.0.1`
   (`C:\Windows\System32\drivers\etc\hosts`: `127.0.0.1 postgres eureka kafka keycloak mongo rabbitmq`),
   or change those values to `localhost` in the non-Docker config files.
4. Required environment variables for the run configuration: `DB_USER`, `DB_PASSWORD`,
   `MONGO_URI` (use `mongodb://localhost:27017/ecom_user`), and the `RABBITMQ_*` values
   (`RABBITMQ_HOST=localhost`).
