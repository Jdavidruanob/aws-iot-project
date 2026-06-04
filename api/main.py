import os
import json
from datetime import datetime, timezone

import boto3
import pg8000
from boto3.dynamodb.conditions import Key
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="IoT SaaS API")

# ── Configuración ────────────────────────────────────────────────────────────

AWS_REGION         = os.environ.get("AWS_REGION", "us-east-1")
EVENTS_TABLE       = os.environ.get("DYNAMODB_TABLE_NAME")        # SensorData-lab
REGISTRY_TABLE     = os.environ.get("DYNAMODB_REGISTRY_TABLE")    # SensorsRegistry-lab
POSTGRES_HOST      = os.environ.get("POSTGRES_HOST")
POSTGRES_PORT      = int(os.environ.get("POSTGRES_PORT", 5432))
POSTGRES_DB        = os.environ.get("POSTGRES_DB", "iotdb")
POSTGRES_USER      = os.environ.get("POSTGRES_USER", "iotuser")
POSTGRES_PASSWORD  = os.environ.get("POSTGRES_PASSWORD")

# ── Clientes AWS ─────────────────────────────────────────────────────────────

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
events_table   = dynamodb.Table(EVENTS_TABLE)   if EVENTS_TABLE   else None
registry_table = dynamodb.Table(REGISTRY_TABLE) if REGISTRY_TABLE else None

# ── Helpers de base de datos ─────────────────────────────────────────────────

def get_pg_connection():
    return pg8000.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        database=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
    )

def decimal_to_float(obj):
    """DynamoDB devuelve Decimal; lo convertimos a float para JSON."""
    from decimal import Decimal
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError

# ── Modelos ──────────────────────────────────────────────────────────────────

class SensorIn(BaseModel):
    device_id: str
    sensor_type: str
    description: str = ""

# ── Endpoints ────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/sensors")
def list_sensors():
    """Lista todos los sensores registrados (DynamoDB registry)."""
    response = registry_table.scan()
    sensors = response.get("Items", [])
    return {"sensors": json.loads(json.dumps(sensors, default=decimal_to_float))}


@app.post("/sensors", status_code=201)
def create_sensor(sensor: SensorIn):
    """Registra un nuevo sensor en la tabla de registro."""
    item = {
        "device_id":   sensor.device_id,
        "sensor_type": sensor.sensor_type,
        "description": sensor.description,
        "registered_at": datetime.now(timezone.utc).isoformat(),
    }
    registry_table.put_item(Item=item)
    return item


@app.get("/sensor/{device_id}/current")
def get_current(device_id: str):
    """Devuelve el último evento del sensor desde DynamoDB."""
    response = events_table.query(
        KeyConditionExpression=Key("device_id").eq(device_id),
        ScanIndexForward=False,   # más nuevo primero
        Limit=1,
    )
    items = response.get("Items", [])
    if not items:
        raise HTTPException(status_code=404, detail=f"Sin datos para {device_id}")
    return json.loads(json.dumps(items[0], default=decimal_to_float))


@app.get("/sensor/{device_id}/recent")
def get_recent(device_id: str):
    """Devuelve los últimos 10 eventos del sensor desde DynamoDB."""
    response = events_table.query(
        KeyConditionExpression=Key("device_id").eq(device_id),
        ScanIndexForward=False,   # más nuevo primero
        Limit=10,
    )
    items = response.get("Items", [])
    if not items:
        raise HTTPException(status_code=404, detail=f"Sin datos para {device_id}")
    return {"device_id": device_id, "events": json.loads(json.dumps(items, default=decimal_to_float))}


@app.get("/sensor/{device_id}/history")
def get_history(device_id: str):
    """Devuelve el histórico completo del sensor desde PostgreSQL."""
    conn = get_pg_connection()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT device_id, sensor_type, value, timestamp FROM sensor_events "
        "WHERE device_id = %s ORDER BY timestamp DESC",
        (device_id,),
    )
    rows = cursor.fetchall()
    cursor.close()
    conn.close()

    events = [
        {"device_id": r[0], "sensor_type": r[1], "value": float(r[2]), "timestamp": str(r[3])}
        for r in rows
    ]
    return {"device_id": device_id, "total": len(events), "events": events}
