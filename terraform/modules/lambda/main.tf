# ── Lambda 1: S3 → PostgreSQL ─────────────────────────────────────────────────
# Se activa cuando IoT Core guarda un JSON en S3 (s3:ObjectCreated:*).
# Lee el objeto, extrae los campos y los inserta en la tabla sensor_events de PostgreSQL.
# Necesita estar en la VPC para conectarse al EC2 de PostgreSQL por IP privada.

data "archive_file" "s3_to_postgres" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/s3_to_postgres"
  output_path = "/tmp/s3_to_postgres.zip"
  excludes    = ["requirements.txt"]
}

resource "aws_lambda_function" "s3_to_postgres" {
  function_name    = "iot-s3-to-postgres"
  role             = var.lab_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30

  filename         = data.archive_file.s3_to_postgres.output_path
  source_code_hash = data.archive_file.s3_to_postgres.output_base64sha256

  # En VPC para acceder a PostgreSQL por IP privada.
  # El VPC Gateway Endpoint de S3 (creado en networking) permite llamar a S3 sin salir a internet.
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      POSTGRES_HOST     = var.postgres_host
      POSTGRES_PORT     = "5432"
      POSTGRES_DB       = "iotdb"
      POSTGRES_USER     = "iotuser"
      POSTGRES_PASSWORD = var.postgres_password
    }
  }
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_postgres.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.sensor_bucket_arn
}

resource "aws_s3_bucket_notification" "s3_trigger" {
  bucket = var.sensor_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_postgres.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "data/"
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}

# ── Lambda 2: Alerta de temperatura ──────────────────────────────────────────
# Invocada por IoT Core Regla 3 cuando value > threshold.
# No necesita VPC porque SQS es un endpoint público de AWS.

data "archive_file" "alert" {
  type        = "zip"
  source_file = "${path.root}/../lambda/alert/handler.py"
  output_path = "/tmp/alert.zip"
}

resource "aws_lambda_function" "alert" {
  function_name    = "iot-alert"
  role             = var.lab_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10

  filename         = data.archive_file.alert.output_path
  source_code_hash = data.archive_file.alert.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL = var.sqs_queue_url
    }
  }
}

# ── Lambda 3: CloudWatch Logger ───────────────────────────────────────────────
# Disparada por SQS (Event Source Mapping definido abajo).
# Los logs de Lambda van automáticamente a CloudWatch Logs — no hace falta configuración extra.

data "archive_file" "cloudwatch_logger" {
  type        = "zip"
  source_file = "${path.root}/../lambda/cloudwatch_logger/handler.py"
  output_path = "/tmp/cloudwatch_logger.zip"
}

resource "aws_lambda_function" "cloudwatch_logger" {
  function_name    = "iot-cloudwatch-logger"
  role             = var.lab_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10

  filename         = data.archive_file.cloudwatch_logger.output_path
  source_code_hash = data.archive_file.cloudwatch_logger.output_base64sha256
}

# Event Source Mapping: SQS → Lambda CloudWatch Logger
# AWS hace polling automático de la cola y entrega los mensajes a la Lambda.
# No es necesario un aws_lambda_permission para ESM — la integración es gestionada por el servicio Lambda.
resource "aws_lambda_event_source_mapping" "sqs_to_logger" {
  event_source_arn = var.sqs_queue_arn
  function_name    = aws_lambda_function.cloudwatch_logger.arn
  batch_size       = 1
  enabled          = true
}
