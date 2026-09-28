# E-Commerce Microservices

A Spring Boot microservices e-commerce backend: service discovery, centralized config, an API
gateway with JWT auth, and independent services for users, products, orders/cart, and
notifications — wired together with Kafka, RabbitMQ, Keycloak, and a full observability stack
(Prometheus, Grafana, Zipkin, Loki).

## Architecture

| Service | Port | Responsibility |
|---|---|---|
| `eureka` | 8761 | Service discovery (Netflix Eureka) |
| `configserver` | 8888 | Centralized externalized config (native/file-backed), refreshable via Spring Cloud Bus |
| `gateway` | 8080 | Single entry point: routing, JWT validation (OAuth2 resource server), rate limiting, circuit breaking |
| `user` | 8082 | User profiles (MongoDB) + Keycloak account provisioning |
| `product` | 8081 | Product catalog (PostgreSQL) |
| `order` | 8083 | Cart, checkout, stock reservation, publishes order events |
| `notification` | 8084 | Consumes order events off Kafka |

**Request flow:** clients hit the `gateway`, which validates the caller's JWT (issued by
Keycloak), injects a trusted user identity header, and routes to `user`/`product`/`order` via
Eureka-based load balancing. `order` calls `product` and `user` synchronously over HTTP for cart
operations, reserves stock atomically on checkout, then publishes an `OrderCreatedEvent` to Kafka,
which `notification` consumes asynchronously.

## Tech stack

- **Spring Boot 3 / Spring Cloud** — Eureka, Config Server, Gateway, OpenFeign-style HTTP
  interfaces, Resilience4j (circuit breaker, retry, rate limiter)
- **Keycloak** — identity provider (OAuth2/OIDC), JWT issuance and role management
- **PostgreSQL** (product, order) and **MongoDB** (user) — polyglot persistence
- **Kafka** — async order events; **RabbitMQ** — Spring Cloud Bus config-refresh broadcasts
- **Redis** — gateway rate limiting
- **Prometheus + Grafana** — metrics; **Zipkin** — distributed tracing; **Loki + Grafana Alloy** —
  centralized logs

## Running locally

### 1. Prerequisites

- Docker + Docker Compose
- (Optional, for building from source instead of the prebuilt images) Java 21 and Maven

### 2. Create the environment file

Docker Compose expects `deploy/docker/.env` (not committed — it holds credentials). Copy the
template and adjust as needed:

```
cd deploy/docker
cp .env.example .env
```

### 3. Set up Keycloak

The app expects a Keycloak realm named `ecom-app` with an `oauth2-pkce` client and `PRODUCT` /
`ORDER` / `USER` client roles already defined, plus an admin user `user-service` can use to call
Keycloak's Admin REST API when provisioning new accounts.

Start Keycloak, then run the setup script, which imports the realm
([`realm-export-ecom-app.json`](deploy/docker/keycloak/realm-export-ecom-app.json)) and creates
that admin user — both steps are safe to re-run:

```
docker compose up -d keycloak
./keycloak/setup-realm.sh
```

By default it creates the user `user`/`user`, matching `keycloak.admin.username`/`password` in
`configserver/src/main/resources/config/user-service.yml`. Override via env vars
(`APP_ADMIN_USERNAME`, `APP_ADMIN_PASSWORD`, etc. — see the script's header comment) if you want
different credentials, and update that config file to match.

### 4. Start everything

```
cd deploy/docker
docker compose up
```

### 5. Useful endpoints once it's up

| What | URL |
|---|---|
| API Gateway | http://localhost:8080 |
| Eureka dashboard | http://localhost:8761 |
| Keycloak admin console | http://localhost:8443 |
| pgAdmin | http://localhost:5050 |
| RabbitMQ management | http://localhost:15672 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Zipkin | http://localhost:9411 |

A ready-to-import Postman collection covering the main API flows is at
[`ecommerce.postman_collection.json`](ecommerce.postman_collection.json).

## Known limitations

- Stock reservation on checkout uses a best-effort compensating rollback, not a full
  saga/orchestrated transaction — see `OrderService.createOrder()`.
- `notification-service` currently only logs consumed events; it doesn't yet send real emails or
  write to a database.
- The Gateway's `PRODUCT` role restriction on product-management endpoints has no account holding
  that role by default — grant it manually in Keycloak to whichever account should manage the
  catalog.
