#!/usr/bin/env bash
# test_deploy.sh — Verifica que toda la infraestructura IoT esté funcionando.
# Ejecutar dentro del contenedor de desarrollo con credenciales AWS configuradas.
#
# Uso básico (sin verificar contenedores locales):
#   docker run --rm -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
#     -e AWS_SESSION_TOKEN=... -e AWS_DEFAULT_REGION=us-east-1 \
#     -v $(pwd):/workspace:Z iot-dev bash /workspace/test_deploy.sh
#
# Uso completo (incluye verificar contenedores locales):
#   Añadir: -v /var/run/docker.sock:/var/run/docker.sock

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}[OK]${NC}"; FAIL="${RED}[FAIL]${NC}"; INFO="${YELLOW}[INFO]${NC}"
PASS=0; FAIL_COUNT=0

check() {
    local label="$1" result="$2" detail="${3:-}"
    if [ "$result" = "ok" ]; then
        echo -e "$OK  $label${detail:+  →  $detail}"; PASS=$((PASS+1))
    else
        echo -e "$FAIL $label${detail:+  →  $detail}"; FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

echo ""; echo "══════════════════════════════════════════════════════"
echo "   TEST SUITE — IoT SaaS Platform en AWS"
echo "══════════════════════════════════════════════════════"

# ── 1. Credenciales AWS ───────────────────────────────────────────────────────
echo ""; echo "▶ AWS"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [ -n "$ACCOUNT" ]; then
    check "Credenciales AWS válidas" "ok" "cuenta $ACCOUNT"
else
    check "Credenciales AWS válidas" "fail"
    echo -e "$INFO Sin credenciales AWS. Exporta AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN."
    exit 1
fi

# ── 2. S3 — bucket con archivos de datos ─────────────────────────────────────
echo ""; echo "▶ S3 (cold storage)"
S3_BUCKET=$(aws s3 ls 2>/dev/null | grep "iot-saas" | awk '{print $3}' | head -1 || true)
if [ -n "$S3_BUCKET" ]; then
    check "Bucket S3 existe" "ok" "$S3_BUCKET"
    S3_COUNT=$(aws s3 ls "s3://$S3_BUCKET/" --recursive 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "${S3_COUNT:-0}" -gt 0 ]; then
        check "Archivos en S3" "ok" "$S3_COUNT archivos"
    else
        check "Archivos en S3 (¿sensores enviando datos?)" "fail" "bucket vacío"
    fi
else
    check "Bucket S3 existe" "fail"
fi

# ── 3. DynamoDB — tablas activas ─────────────────────────────────────────────
echo ""; echo "▶ DynamoDB"
for TABLE in "SensorData-lab" "SensorsRegistry-lab"; do
    STATUS=$(aws dynamodb describe-table --table-name "$TABLE" \
        --query 'Table.TableStatus' --output text 2>/dev/null || true)
    COUNT=$(aws dynamodb describe-table --table-name "$TABLE" \
        --query 'Table.ItemCount' --output text 2>/dev/null || echo "?")
    if [ "$STATUS" = "ACTIVE" ]; then
        check "Tabla $TABLE" "ok" "ACTIVE, ~$COUNT items"
    else
        check "Tabla $TABLE" "fail" "status=${STATUS:-no encontrada}"
    fi
done

# ── 4. Lambda — funciones en estado Active ────────────────────────────────────
echo ""; echo "▶ Lambda"
for FN in "iot-s3-to-postgres" "iot-alert" "iot-cloudwatch-logger"; do
    STATE=$(aws lambda get-function-configuration --function-name "$FN" \
        --query 'State' --output text 2>/dev/null || true)
    if [ "$STATE" = "Active" ]; then
        check "Lambda $FN" "ok"
    else
        check "Lambda $FN" "fail" "state=${STATE:-no encontrada}"
    fi
done

# ── 5. EC2 — instancia PostgreSQL corriendo ───────────────────────────────────
echo ""; echo "▶ EC2 PostgreSQL"
EC2_STATE=$(aws ec2 describe-instances \
    --filters "Name=instance-type,Values=t3.micro" \
              "Name=instance-state-name,Values=running,stopped,terminated" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || true)
if [ "$EC2_STATE" = "running" ]; then
    check "Instancia EC2 PostgreSQL" "ok" "running"
else
    check "Instancia EC2 PostgreSQL" "fail" "state=${EC2_STATE:-not found}"
fi

# ── 6. ECS — servicio con tareas corriendo ────────────────────────────────────
echo ""; echo "▶ ECS Fargate (API)"
RUNNING=$(aws ecs describe-services \
    --cluster "iot-saas-cluster-lab" --services "iot-saas-api-service-lab" \
    --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
if [ "${RUNNING:-0}" -ge 1 ] 2>/dev/null; then
    check "ECS Service corriendo" "ok" "$RUNNING tarea(s) activa(s)"
else
    check "ECS Service corriendo" "fail" "runningCount=${RUNNING:-0}"
fi

# ── 7. API REST — 5 endpoints ─────────────────────────────────────────────────
echo ""; echo "▶ API REST (FastAPI via ALB)"
API_URL=$(aws elbv2 describe-load-balancers \
    --query 'LoadBalancers[?contains(LoadBalancerName, `iot-saas`)].DNSName' \
    --output text 2>/dev/null | head -1 || true)

if [ -z "${API_URL:-}" ]; then
    echo -e "$INFO No se encontró el ALB — saltando pruebas de API"
    FAIL_COUNT=$((FAIL_COUNT+5))
else
    API_BASE="http://$API_URL"

    # /health
    HEALTH=$(curl -sf --max-time 8 "$API_BASE/health" 2>/dev/null || true)
    if echo "${HEALTH:-}" | grep -q '"ok"'; then
        check "GET /health" "ok"
    else
        check "GET /health" "fail" "no responde en $API_BASE"
    fi

    # /sensors — respuesta: {"sensors": [...]}
    SENSORS_RESP=$(curl -sf --max-time 8 "$API_BASE/sensors" 2>/dev/null || echo '{"sensors":[]}')
    SENSOR_COUNT=$(echo "$SENSORS_RESP" | python3 -c \
        "import sys,json; print(len(json.load(sys.stdin).get('sensors',[])))" 2>/dev/null || echo "0")
    IDS=$(echo "$SENSORS_RESP" | python3 -c \
        "import sys,json; print(', '.join(s['device_id'] for s in json.load(sys.stdin).get('sensors',[])))" \
        2>/dev/null || echo "?")
    if [ "${SENSOR_COUNT:-0}" -gt 0 ]; then
        check "GET /sensors" "ok" "$SENSOR_COUNT sensores: $IDS"
    else
        check "GET /sensors (ningún sensor registrado)" "fail" \
            "POST /sensors para registrar sensor-temp-01 etc."
    fi

    # Tomar el primer sensor para las pruebas de /current /recent /history
    FIRST_ID=$(echo "$SENSORS_RESP" | python3 -c \
        "import sys,json; d=json.load(sys.stdin).get('sensors',[]); print(d[0]['device_id'] if d else '')" \
        2>/dev/null || true)
    FIRST_ID="${FIRST_ID:-}"

    if [ -n "$FIRST_ID" ]; then
        # /current — último evento desde DynamoDB (Sort Key timestamp DESC Limit 1)
        CURRENT=$(curl -sf --max-time 8 "$API_BASE/sensor/$FIRST_ID/current" 2>/dev/null || true)
        if echo "${CURRENT:-}" | grep -q '"device_id"'; then
            VAL=$(echo "$CURRENT" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(f\"{d['sensor_type']}={d['value']:.2f}\")" \
                2>/dev/null || echo "?")
            check "GET /sensor/$FIRST_ID/current" "ok" "$VAL"
        else
            check "GET /sensor/$FIRST_ID/current" "fail" "sin datos en DynamoDB"
        fi

        # /recent — últimos 10 eventos desde DynamoDB
        RECENT=$(curl -sf --max-time 8 "$API_BASE/sensor/$FIRST_ID/recent" 2>/dev/null || true)
        RECENT_N=$(echo "${RECENT:-}" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin).get('events',[])))" 2>/dev/null || echo "0")
        if [ "${RECENT_N:-0}" -gt 0 ]; then
            check "GET /sensor/$FIRST_ID/recent" "ok" "$RECENT_N eventos"
        else
            check "GET /sensor/$FIRST_ID/recent" "fail" "0 eventos en DynamoDB"
        fi

        # /history — histórico desde PostgreSQL (via Lambda s3_to_postgres)
        HISTORY=$(curl -sf --max-time 12 "$API_BASE/sensor/$FIRST_ID/history" 2>/dev/null || true)
        HIST_N=$(echo "${HISTORY:-}" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "0")
        if [ "${HIST_N:-0}" -gt 0 ]; then
            check "GET /sensor/$FIRST_ID/history (PostgreSQL)" "ok" "$HIST_N registros"
        else
            check "GET /sensor/$FIRST_ID/history (PostgreSQL)" "fail" \
                "0 registros — ¿Lambda s3_to_postgres procesó archivos S3?"
        fi
    else
        echo -e "$INFO  Saltando /current /recent /history — registra primero el sensor con POST /sensors"
        FAIL_COUNT=$((FAIL_COUNT+3))
    fi
fi

# ── 8. Sistema de alertas — SQS + CloudWatch ─────────────────────────────────
echo ""; echo "▶ Sistema de Alertas (IoT Rule 3 → Lambda → SQS → CloudWatch)"

SQS_URL=$(aws sqs list-queues \
    --query 'QueueUrls[?contains(@, `iot`)]' \
    --output text 2>/dev/null | head -1 || true)
if [ -n "${SQS_URL:-}" ]; then
    check "Cola SQS alertas" "ok" "$(basename "$SQS_URL")"
else
    check "Cola SQS alertas" "fail"
fi

# Buscar alertas HIGH_TEMPERATURE en CloudWatch de la última hora
NOW_MS=$(date +%s%3N)
ONE_HOUR_AGO_MS=$((NOW_MS - 3600000))
CW_ALERTS=$(aws logs filter-log-events \
    --log-group-name /aws/lambda/iot-cloudwatch-logger \
    --filter-pattern "HIGH_TEMPERATURE" \
    --start-time "$ONE_HOUR_AGO_MS" \
    --query 'length(events)' --output text 2>/dev/null || echo "0")

if [ "${CW_ALERTS:-0}" -gt 0 ] 2>/dev/null; then
    LAST=$(aws logs filter-log-events \
        --log-group-name /aws/lambda/iot-cloudwatch-logger \
        --filter-pattern "HIGH_TEMPERATURE" \
        --start-time "$ONE_HOUR_AGO_MS" \
        --query 'events[-1].message' --output text 2>/dev/null | cut -c1-70 || echo "?")
    check "Alertas HIGH_TEMPERATURE en CloudWatch" "ok" \
        "$CW_ALERTS alerta(s) | última: $LAST"
else
    check "Alertas HIGH_TEMPERATURE en CloudWatch" "fail" \
        "0 en última hora — ¿sensores encendidos? ¿temp>35°C?"
fi

# ── 9. Contenedores locales (requiere socket Docker montado) ──────────────────
echo ""; echo "▶ Contenedores locales (sensores + gateway)"
if ! command -v docker &>/dev/null; then
    echo -e "$INFO  Docker no disponible en este contexto."
    echo -e "$INFO  Para verificar contenedores locales añade al docker run:"
    echo -e "$INFO    -v /var/run/docker.sock:/var/run/docker.sock"
else
    for CONTAINER in "sensor-temp-01" "sensor-humidity-01" "sensor-co2-01" "edge-gateway-mosquitto"; do
        STATE=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "not found")
        STATE=$(echo "$STATE" | tr -d '\n')
        if [ "$STATE" = "running" ]; then
            check "Contenedor $CONTAINER" "ok"
        else
            check "Contenedor $CONTAINER" "fail" "state=$STATE  →  ejecuta: make local-up"
        fi
    done
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""; echo "══════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}  RESULTADO: $PASS/$TOTAL OK — Todo funcionando ✓${NC}"
else
    echo -e "${RED}  RESULTADO: $FAIL_COUNT fallo(s) de $TOTAL checks${NC}"
    echo -e "${GREEN}  Pasaron: $PASS/$TOTAL${NC}"
fi
echo "══════════════════════════════════════════════════════"; echo ""
