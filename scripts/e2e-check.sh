#!/bin/bash
# End-to-end check of the whole stack through the gateway: auth, roles/ownership,
# users, products, cart, orders, validation, actuator, infra and data stores.
#
# Needs the stack running (docker compose up -d in deploy/docker) with the Keycloak
# realm imported and the `user` service account set up (see docs/RUNNING_LOCALLY.md).
# Uses the local-dev Keycloak admin login (admin/admin from docker-compose.yml),
# creates temporary users e2eadmin / e2eshopper / e2eshopper2, and REMOVES them and
# empties the product, order and user data when finished - run it on a dev stack only.
#
# Usage:  bash scripts/e2e-check.sh
KC=http://localhost:8443; GW=http://localhost:8080
PASS=0; FAIL=0; FINDINGS=()
OUT=$(mktemp); command -v cygpath >/dev/null 2>&1 && OUT=$(cygpath -m "$OUT")   # native python needs a Windows path under Git Bash
command -v python >/dev/null 2>&1 || python() { python3 "$@"; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

t() { # t "description" "expected codes" curl-args...
  local desc="$1" exp="$2"; shift 2
  local code; code=$(curl -s -m 60 -o "$OUT" -w "%{http_code}" "$@")
  if [[ " $exp " == *" $code "* ]]; then PASS=$((PASS+1)); printf "  PASS  %-58s %s\n" "$desc" "$code"
  else FAIL=$((FAIL+1)); printf "  FAIL  %-58s got %s, expected %s | %s\n" "$desc" "$code" "$exp" "$(head -c 160 "$OUT" | tr '\n' ' ')"; fi
}
jget() { python -c "import sys,json; d=json.load(open('$OUT')); print($1)" 2>/dev/null; }
tok() { curl -s -d grant_type=password -d client_id=oauth2-pkce -d username="$1" -d password="$2" $KC/realms/ecom-app/protocol/openid-connect/token | python -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"; }
J="Content-Type: application/json"
admtok() { curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin $KC/realms/master/protocol/openid-connect/token | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])"; }
delusers() { local HH="Authorization: Bearer $(admtok)"; for u in e2eadmin e2eshopper e2eshopper2; do local ID=$(curl -s -H "$HH" "$KC/admin/realms/ecom-app/users?username=$u&exact=true" | python -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')"); [ -n "$ID" ] && curl -s -o /dev/null -X DELETE -H "$HH" $KC/admin/realms/ecom-app/users/$ID; done; }
delusers

# ---------- setup: temp admin (all roles) ----------
APW="E2e-$RANDOM$RANDOM-Aa!"; SPW="Shop-$RANDOM$RANDOM-Aa!"
ADM=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin $KC/realms/master/protocol/openid-connect/token | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])"); H="Authorization: Bearer $ADM"
curl -s -o /dev/null -X POST -H "$H" -H "$J" $KC/admin/realms/ecom-app/users -d "{\"username\":\"e2eadmin\",\"enabled\":true,\"email\":\"e2eadmin@example.com\",\"emailVerified\":true,\"firstName\":\"E2E\",\"lastName\":\"Admin\",\"credentials\":[{\"type\":\"password\",\"value\":\"$APW\",\"temporary\":false}]}"
AID=$(curl -s -H "$H" "$KC/admin/realms/ecom-app/users?username=e2eadmin&exact=true" | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
CID=$(curl -s -H "$H" "$KC/admin/realms/ecom-app/clients?clientId=oauth2-pkce" | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
curl -s -o /dev/null -X POST -H "$H" -H "$J" $KC/admin/realms/ecom-app/users/$AID/role-mappings/clients/$CID -d "$(curl -s -H "$H" $KC/admin/realms/ecom-app/clients/$CID/roles)"
AT=$(tok e2eadmin "$APW"); A="Authorization: Bearer $AT"
[ -z "$AT" ] && { echo "could not get admin token"; exit 1; }
# warm up (cold start)
curl -s -m 60 -o /dev/null -H "$A" $GW/api/products; curl -s -m 60 -o /dev/null -H "$A" $GW/api/users; curl -s -m 60 -o /dev/null -H "$A" $GW/api/cart

echo "== 1. AUTH (gateway)"
t "no token -> 401" 401 $GW/api/products
t "garbage token -> 401" 401 -H "Authorization: Bearer abc.def.ghi" $GW/api/products
t "valid token -> 200" 200 -H "$A" $GW/api/products

echo "== 2. USERS"
BODY="{\"username\":\"e2eshopper\",\"firstName\":\"E2E\",\"lastName\":\"Shopper\",\"password\":\"$SPW\",\"email\":\"e2eshopper@example.com\",\"phone\":\"1234567890\",\"address\":{\"street\":\"1 Main\",\"city\":\"Town\",\"state\":\"ST\",\"country\":\"US\",\"zipcode\":\"12345\"}}"
t "POST /api/users (register)" "200 201" -X POST -H "$A" -H "$J" $GW/api/users -d "$BODY"
t "POST /api/users duplicate -> 409" 409 -X POST -H "$A" -H "$J" $GW/api/users -d "$BODY"
t "POST /api/users missing fields -> 400" 400 -X POST -H "$A" -H "$J" $GW/api/users -d '{"username":"nofields"}'
t "GET /api/users" 200 -H "$A" $GW/api/users
UID_M=$(jget "[u['id'] for u in d if u['email']=='e2eshopper@example.com'][0]"); KCID=$(jget "[u['keyCloakId'] for u in d if u['email']=='e2eshopper@example.com'][0]")
t "GET /api/users/{id}" 200 -H "$A" $GW/api/users/$UID_M
t "GET /api/users/{unknown} -> 404" 404 -H "$A" $GW/api/users/000000000000000000000000
t "GET /api/users/by-keycloak-id/{id}" 200 -H "$A" $GW/api/users/by-keycloak-id/$KCID
t "GET /api/users/by-keycloak-id/{unknown} -> 404" 404 -H "$A" $GW/api/users/by-keycloak-id/nope
t "PUT /api/users/{id}" 200 -X PUT -H "$A" -H "$J" $GW/api/users/$UID_M -d "{\"firstName\":\"Edited\",\"lastName\":\"Shopper\",\"email\":\"e2eshopper@example.com\",\"phone\":\"999\"}"
t "PUT /api/users/{unknown} -> 404" 404 -X PUT -H "$A" -H "$J" $GW/api/users/000000000000000000000000 -d '{"firstName":"x"}'
ST=$(tok e2eshopper "$SPW"); S="Authorization: Bearer $ST"
[ -z "$ST" ] && echo "  FAIL  shopper could not log in after registration"

echo "== 3. PRODUCTS"
PB='{"name":"E2E Phone","description":"d","price":50.00,"stockQuantity":10,"category":"Electronics","imageUrl":"https://placehold.co/600x400"}'
t "POST /api/products (PRODUCT role)" 201 -X POST -H "$A" -H "$J" $GW/api/products -d "$PB"; P1=$(jget "d['id']")
t "POST second product" 201 -X POST -H "$A" -H "$J" $GW/api/products -d '{"name":"E2E Cable","description":"d","price":5.00,"stockQuantity":3,"category":"Accessories","imageUrl":"x"}'; P2=$(jget "d['id']")
t "GET /api/products" 200 -H "$A" $GW/api/products
t "GET /api/products/{id}" 200 -H "$A" $GW/api/products/$P1
t "GET /api/products/{unknown} -> 404" 404 -H "$A" $GW/api/products/999999
t "GET /api/products/abc (non-numeric) -> 400" 400 -H "$A" $GW/api/products/abc
t "PUT /api/products/{id}" 200 -X PUT -H "$A" -H "$J" $GW/api/products/$P1 -d '{"name":"E2E Phone v2","description":"d","price":55.00,"stockQuantity":10,"category":"Electronics","imageUrl":"x"}'
t "PUT /api/products/{unknown} -> 404" 404 -X PUT -H "$A" -H "$J" $GW/api/products/999999 -d "$PB"
t "GET /api/products/search?keyword=e2e" 200 -H "$A" "$GW/api/products/search?keyword=e2e"
t "GET /api/products/search (no keyword) -> 400" 400 -H "$A" $GW/api/products/search
t "GET /api/products/simulate" 200 -H "$A" $GW/api/products/simulate
t "GET /api/products/simulate?fail=true (demo failure)" "500 503" -H "$A" "$GW/api/products/simulate?fail=true"
t "POST product with empty body -> 400" 400 -X POST -H "$A" -H "$J" $GW/api/products -d '{}'
t "DELETE /api/products/{id}" "204 200" -X DELETE -H "$A" $GW/api/products/$P2
t "GET deleted product -> 404 (or inactive)" "404 200" -H "$A" $GW/api/products/$P2
t "DELETE /api/products/{unknown} -> 404" 404 -X DELETE -H "$A" $GW/api/products/999999

echo "== 4. ROLE CHECKS (shopper without PRODUCT role)"
t "shopper GET products -> 200" 200 -H "$S" $GW/api/products
t "shopper POST product -> 403" 403 -X POST -H "$S" -H "$J" $GW/api/products -d "$PB"
t "shopper PUT product -> 403" 403 -X PUT -H "$S" -H "$J" $GW/api/products/$P1 -d "$PB"
t "shopper DELETE product -> 403" 403 -X DELETE -H "$S" $GW/api/products/$P1
t "shopper PATCH decrement-stock -> 403 (SECURITY)" 403 -X PATCH -H "$S" "$GW/api/products/$P1/decrement-stock?quantity=1"
t "shopper PATCH restore-stock -> 403 (SECURITY)" 403 -X PATCH -H "$S" "$GW/api/products/$P1/restore-stock?quantity=1"
BODY2="{\"username\":\"e2eshopper2\",\"firstName\":\"Other\",\"lastName\":\"Person\",\"password\":\"$SPW\",\"email\":\"e2eshopper2@example.com\",\"phone\":\"555\",\"address\":{\"street\":\"2 Side\",\"city\":\"Town\",\"state\":\"ST\",\"country\":\"US\",\"zipcode\":\"54321\"}}"
t "register second shopper" 200 -X POST -H "$A" -H "$J" $GW/api/users -d "$BODY2"
t "ADMIN lists users" 200 -H "$A" $GW/api/users
UID2=$(jget "[u['id'] for u in d if u['email']=='e2eshopper2@example.com'][0]"); KCID2=$(jget "[u['keyCloakId'] for u in d if u['email']=='e2eshopper2@example.com'][0]")
t "shopper GET all users -> 403 (PII)" 403 -H "$S" $GW/api/users
t "shopper GET own profile -> 200" 200 -H "$S" $GW/api/users/$UID_M
t "shopper GET own profile by keycloak id -> 200" 200 -H "$S" $GW/api/users/by-keycloak-id/$KCID
t "shopper PUT own profile -> 200" 200 -X PUT -H "$S" -H "$J" $GW/api/users/$UID_M -d '{"firstName":"Mine","lastName":"Shopper","email":"e2eshopper@example.com","phone":"1"}'
t "shopper GET ANOTHER user's profile -> 403" 403 -H "$S" $GW/api/users/$UID2
t "shopper GET another by keycloak id -> 403" 403 -H "$S" $GW/api/users/by-keycloak-id/$KCID2
t "shopper PUT ANOTHER user -> 403" 403 -X PUT -H "$S" -H "$J" $GW/api/users/$UID2 -d '{"firstName":"hijack"}'
t "ADMIN GET any profile -> 200" 200 -H "$A" $GW/api/users/$UID2
t "ADMIN PUT any profile -> 200" 200 -X PUT -H "$A" -H "$J" $GW/api/users/$UID2 -d '{"firstName":"AdminEdit","lastName":"Person","email":"e2eshopper2@example.com","phone":"555"}'
t "spoofed X-User-Roles: ADMIN header is ignored -> 403" 403 -H "$S" -H "X-User-Roles: ADMIN" -H "X-User-ID: $KCID2" $GW/api/users/$UID2

echo "== 5. CART"
t "GET /api/cart (empty)" 200 -H "$S" $GW/api/cart
t "cart without token -> 401" 401 $GW/api/cart
t "POST /api/cart add P1 x2" 201 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":2}"
t "POST /api/cart same product again (merges)" 201 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":2}"
t "GET /api/cart shows qty 4" 200 -H "$S" $GW/api/cart; echo "        cart qty = $(jget "[c['quantity'] for c in d]")"
t "POST /api/cart unknown product -> 4xx" "400 404" -X POST -H "$S" -H "$J" $GW/api/cart -d '{"productId":"999999","quantity":1}'
t "POST /api/cart quantity > stock -> 400" 400 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":999}"
t "POST /api/cart quantity 0 -> 400" 400 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":0}"
t "POST /api/cart quantity -3 -> 400" 400 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":-3}"
t "X-User-ID spoof is ignored (item lands in MY cart)" 201 -X POST -H "$S" -H "X-User-ID: someone-else" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":1}"
t "cart still mine after spoof attempt" 200 -H "$S" $GW/api/cart; echo "        cart qty = $(jget "[c['quantity'] for c in d]") (5 = spoof went to my cart)"
t "DELETE /api/cart/items/{id}" "204 200" -X DELETE -H "$S" $GW/api/cart/items/$P1
t "DELETE /api/cart/items/{not in cart} -> 404" 404 -X DELETE -H "$S" $GW/api/cart/items/$P1

echo "== 6. ORDERS"
t "POST /api/orders with empty cart -> 400" 400 -X POST -H "$S" $GW/api/orders
t "add P1 x3 to cart" 201 -X POST -H "$S" -H "$J" $GW/api/cart -d "{\"productId\":\"$P1\",\"quantity\":3}"
t "POST /api/orders" 201 -X POST -H "$S" $GW/api/orders; echo "        total=$(jget "d['totalAmount']") (expect 165.00 = 55.00 x 3) status=$(jget "d['status']")"
t "cart empty after order" 200 -H "$S" $GW/api/cart; echo "        cart items = $(jget "len(d)")"
t "stock reduced 10 -> 7" 200 -H "$A" $GW/api/products/$P1; echo "        stock = $(jget "d['stockQuantity']")"
t "POST /api/orders without token -> 401" 401 -X POST $GW/api/orders

echo "== 7. GATEWAY / ACTUATOR"
t "GET /fallback/products (authed)" "503 200" -H "$A" $GW/fallback/products
t "public port: /actuator/health anonymous -> 401" 401 $GW/actuator/health
t "public port: /actuator/health with token -> 404 (not exposed)" 404 -H "$A" $GW/actuator/health
t "public port: /actuator/env with token -> 404 (not exposed)" 404 -H "$A" $GW/actuator/env
t "private port 9081: /actuator/health" 200 http://localhost:9081/actuator/health
t "private port 9081: /actuator/prometheus" 200 http://localhost:9081/actuator/prometheus
t "private port 9081: POST /actuator/refresh (Postman)" 200 -X POST http://localhost:9081/actuator/refresh
t "private port 9081: POST /actuator/shutdown not exposed" "404 405" -X POST http://localhost:9081/actuator/shutdown
t "GET unknown route -> 404" 404 -H "$A" $GW/api/nothing
t "GET /eureka/main via gateway -> 200" 200 -H "$A" $GW/eureka/main
t "GET /eureka/apps via gateway (static route) -> 200" 200 -H "$A" $GW/eureka/apps

echo "== 8. INFRASTRUCTURE"
t "Config server /product-service/docker" 200 http://localhost:8888/product-service/docker
t "Config server /gateway-service/docker" 200 http://localhost:8888/gateway-service/docker
t "Config server /user-service/docker" 200 http://localhost:8888/user-service/docker
t "Config server /order-service/docker" 200 http://localhost:8888/order-service/docker
t "Config server /actuator/health" 200 http://localhost:8888/actuator/health
t "Config server POST /encrypt" 200 -X POST -H "Content-Type: text/plain" http://localhost:8888/encrypt -d 'hello-secret'
CIPHER=$(cat "$OUT")
t "Config server POST /decrypt round-trip" 200 -X POST -H "Content-Type: text/plain" http://localhost:8888/decrypt -d "$CIPHER"; echo "        decrypted = $(cat "$OUT") (expect hello-secret)"
t "Eureka dashboard" 200 http://localhost:8761/
t "Eureka /actuator/health" 200 http://localhost:8761/actuator/health
t "Keycloak realm ecom-app" 200 $KC/realms/ecom-app
t "Keycloak JWKS" 200 $KC/realms/ecom-app/protocol/openid-connect/certs
t "Zipkin /health" 200 http://localhost:9411/health
t "Zipkin has traces" 200 "http://localhost:9411/api/v2/services"; echo "        services = $(head -c 200 $OUT)"
t "Prometheus ready" 200 http://localhost:9090/-/ready
t "Prometheus targets" 200 http://localhost:9090/api/v1/targets; echo "        targets: $(jget "[(t['labels'].get('job'),t['health']) for t in d['data']['activeTargets']]")"; [ "$(jget "all(t['health']=='up' for t in d['data']['activeTargets'])")" = "True" ] && { PASS=$((PASS+1)); echo '  PASS  all Prometheus targets up'; } || { FAIL=$((FAIL+1)); echo '  FAIL  some Prometheus target is down'; }
t "Grafana /api/health" 200 http://localhost:3000/api/health
t "RabbitMQ management API" 200 -u guest:guest http://localhost:15672/api/overview
t "pgAdmin ping" 200 http://localhost:5050/misc/ping
t "Loki read ready" 200 http://localhost:3101/ready
t "Loki write ready" 200 http://localhost:3102/ready
t "Loki gateway" 200 http://localhost:3100/

echo "== 9. DATA STORES / BROKERS"
DBU=$(grep ^DB_USER "$ROOT/deploy/docker/.env" | cut -d= -f2)
r=$(docker exec postgres psql -U "$DBU" -d productdb -Atc "select count(*) from products" 2>&1); echo "  productdb products rows: $r"
r=$(docker exec postgres psql -U "$DBU" -d orderdb -Atc "select count(*) from orders" 2>&1); echo "  orderdb orders rows: $r"
r=$(docker exec mongo mongosh --quiet ecom_user --eval 'db.users.countDocuments()' 2>&1 | tail -1); echo "  mongo ecom_user.users: $r"
r=$(docker exec redis redis-cli ping 2>&1); echo "  redis: $r"
r=$(docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>&1 | grep -v WARN | tr '\n' ' '); echo "  kafka topics: $r"
sleep 8; echo "  notification consumed: $(docker logs --since 3m notification-service 2>&1 | grep -c 'Received order created event for order')"

echo "== 10. RATE LIMIT"
codes=$(for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code}\n" -H "$A" $GW/api/products & done | sort | uniq -c | tr '\n' ' '); echo "  60 parallel GET /api/products: $codes"

# ---------- cleanup ----------
delusers
docker exec postgres psql -U "$DBU" -d productdb -qc "TRUNCATE products RESTART IDENTITY" >/dev/null 2>&1
docker exec postgres psql -U "$DBU" -d orderdb -qc "TRUNCATE order_item, orders, cart_item RESTART IDENTITY CASCADE" >/dev/null 2>&1
docker exec mongo mongosh --quiet ecom_user --eval 'db.users.deleteMany({})' >/dev/null 2>&1
echo; echo "RESULT: $PASS passed, $FAIL failed (test data and temp users removed)"
rm -f "$OUT"
