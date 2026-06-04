"""
Lambda: SQS → CloudWatch Logs
Consume mensajes de la cola SQS de alertas y los escribe como logs de urgencia.
CloudWatch captura automáticamente todo lo que se imprime en Lambda.
"""
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.WARNING)


def lambda_handler(event, context):
    for record in event.get("Records", []):
        message = json.loads(record["body"])
        logger.warning(
            "ALERTA DE URGENCIA | device=%s | value=%s | timestamp=%s | msg=%s",
            message.get("device_id"),
            message.get("value"),
            message.get("timestamp"),
            message.get("message"),
        )

    return {"statusCode": 200}
