# Cola SQS para alertas de temperatura crítica.
# El Event Source Mapping (SQS→Lambda) se crea en el módulo lambda
# para evitar dependencia circular.
resource "aws_sqs_queue" "alerts" {
  name                       = "${var.project_name}-alerts-${var.environment}"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}
