"""
Lambda: S3 ObjectCreated → PostgreSQL
Se activa cada vez que IoT Core guarda un JSON en S3.
Lee el archivo, extrae los campos y los inserta en la tabla sensor_events.
También auto-registra el sensor en SensorsRegistry si no existe.
"""
import json
import os
from urllib.parse import unquote_plus
import boto3
import pg8000
from boto3.dynamodb.conditions import Key

s3       = boto3.client("s3")
dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))

POSTGRES_HOST      = os.environ["POSTGRES_HOST"]
POSTGRES_PORT      = int(os.environ.get("POSTGRES_PORT", 5432))
POSTGRES_DB        = os.environ.get("POSTGRES_DB", "iotdb")
POSTGRES_USER      = os.environ.get("POSTGRES_USER", "iotuser")
POSTGRES_PASSWORD  = os.environ["POSTGRES_PASSWORD"]
REGISTRY_TABLE     = os.environ.get("DYNAMODB_REGISTRY_TABLE")


def get_connection():
    return pg8000.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        database=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
    )


def auto_register_sensor(device_id, sensor_type):
    """Registra el sensor en DynamoDB si no existe — evita tener que hacer POST /sensors manual."""
    if not REGISTRY_TABLE:
        return
    table = dynamodb.Table(REGISTRY_TABLE)
    table.put_item(
        Item={"device_id": device_id, "sensor_type": sensor_type},
        ConditionExpression="attribute_not_exists(device_id)",
    )


def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = unquote_plus(record["s3"]["object"]["key"])

        response = s3.get_object(Bucket=bucket, Key=key)
        data = json.loads(response["Body"].read().decode("utf-8"))

        device_id   = data["device_id"]
        sensor_type = data["sensor_type"]
        value       = float(data["value"])
        timestamp   = data["timestamp"]

        # Auto-registrar sensor en DynamoDB registry (idempotente)
        try:
            auto_register_sensor(device_id, sensor_type)
            print(f"Sensor registrado: {device_id}")
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            pass  # ya existía, no hacer nada

        # Insertar en PostgreSQL
        conn   = get_connection()
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO sensor_events (device_id, sensor_type, value, timestamp)
            VALUES (%s, %s, %s, %s)
            """,
            (device_id, sensor_type, value, timestamp),
        )
        conn.commit()
        cursor.close()
        conn.close()

        print(f"Insertado en PostgreSQL: {device_id} | {sensor_type} | {value} | {timestamp}")

    return {"statusCode": 200}
