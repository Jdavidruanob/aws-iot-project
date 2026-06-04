"""
Lambda: IoT Core Regla 3 → SQS
Se activa cuando la temperatura supera el umbral definido en la regla SQL.
Formatea un mensaje de alerta y lo envía a la cola SQS.
"""
import json
import os
import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["SQS_QUEUE_URL"]


def lambda_handler(event, context):
    device_id   = event.get("device_id", "desconocido")
    value       = event.get("value", 0)
    sensor_type = event.get("sensor_type", "temperature")
    timestamp   = event.get("timestamp", "")

    message = {
        "alert_type":  "HIGH_TEMPERATURE",
        "device_id":   device_id,
        "sensor_type": sensor_type,
        "value":       value,
        "timestamp":   timestamp,
        "message":     f"ALERTA CRITICA: {value}°C en {device_id}",
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
    )

    print(f"Alerta enviada a SQS: {message}")
    return {"statusCode": 200}
