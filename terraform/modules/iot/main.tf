# ── Thing + Certificados mTLS ────────────────────────────────────────────────

resource "aws_iot_thing" "edge_gateway" {
  name = "edge-gateway-01-${var.environment}"
}

resource "aws_iot_certificate" "cert" {
  active = true
}

# Política IoT: solo permite al Edge Gateway conectarse y publicar en lab/sensors/*
resource "aws_iot_policy" "sensor_policy" { # que puede hacer el dispositivo thing
  name = "EdgeGatewayPolicy-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["iot:Connect"]
        Effect   = "Allow"
        Resource = ["arn:aws:iot:${var.region}:${var.account_id}:client/${aws_iot_thing.edge_gateway.name}"]
      },
      {
        Action   = ["iot:Publish", "iot:Receive"]
        Effect   = "Allow"
        Resource = ["arn:aws:iot:${var.region}:${var.account_id}:topic/lab/sensors/*"]
      },
      {
        Action   = ["iot:Subscribe"]
        Effect   = "Allow"
        Resource = ["arn:aws:iot:${var.region}:${var.account_id}:topicfilter/lab/sensors/*"]
      }
    ]
  })
}

resource "aws_iot_policy_attachment" "att" {
  policy = aws_iot_policy.sensor_policy.name
  target = aws_iot_certificate.cert.arn
}

resource "aws_iot_thing_principal_attachment" "att" {
  principal = aws_iot_certificate.cert.arn
  thing     = aws_iot_thing.edge_gateway.name
}

# ── Certificados guardados localmente (para Mosquitto) ───────────────────────

resource "local_file" "certificate_pem" {
  content  = aws_iot_certificate.cert.certificate_pem
  filename = "${path.root}/../edge_gateway/certs/certificate.pem.crt"
}

resource "local_file" "private_key" {
  content  = aws_iot_certificate.cert.private_key
  filename = "${path.root}/../edge_gateway/certs/private.pem.key"
}

resource "local_file" "public_key" {
  content  = aws_iot_certificate.cert.public_key
  filename = "${path.root}/../edge_gateway/certs/public.pem.key"
}

resource "local_file" "root_ca" {
  content  = var.root_ca_pem
  filename = "${path.root}/../edge_gateway/certs/AmazonRootCA1.pem"
}

# Genera mosquitto.conf con el endpoint real de AWS inyectado
resource "local_file" "mosquitto_conf" {
  content  = <<-EOT
# Mosquitto — configuración local
listener 1883 0.0.0.0
allow_anonymous true

# Bridge hacia AWS IoT Core (puerto 8883 con mTLS)
connection awsiot
address ${var.iot_endpoint}:8883
topic lab/sensors/data out 1 "" ""
bridge_protocol_version mqttv311
bridge_insecure false
cleansession true
clientid ${aws_iot_thing.edge_gateway.name}
start_type automatic
notifications false
keepalive_interval 60
bridge_cafile  /mosquitto/certs/AmazonRootCA1.pem
bridge_certfile /mosquitto/certs/certificate.pem.crt
bridge_keyfile  /mosquitto/certs/private.pem.key
EOT
  filename = "${path.root}/../edge_gateway/mosquitto.conf"
}

# ── Regla 1: DynamoDB (hot data) ─────────────────────────────────────────────
# Guarda cada evento en DynamoDB. Con hash+range key (device_id+timestamp),
# cada mensaje crea un nuevo ítem (no sobrescribe).

resource "aws_iot_topic_rule" "dynamodb_rule" {
  name        = "SensorDataToDynamoDB_${var.environment}"
  description = "Guarda eventos de sensores en DynamoDB (hot data)"
  enabled     = true
  sql         = "SELECT * FROM 'lab/sensors/data'"
  sql_version = "2016-03-23"

  dynamodbv2 {
    role_arn = var.lab_role_arn
    put_item {
      table_name = var.sensor_table_name
    }
  }
}

# ── Regla 2: S3 (cold data) ──────────────────────────────────────────────────
# Guarda cada mensaje como archivo JSON en S3, particionado por fecha.

resource "aws_iot_topic_rule" "s3_rule" {
  name        = "SensorDataToS3_${var.environment}"
  description = "Guarda eventos de sensores en S3 particionados por fecha (cold data)"
  enabled     = true
  sql         = "SELECT * FROM 'lab/sensors/data'"
  sql_version = "2016-03-23"

  s3 {
    bucket_name = var.sensor_bucket_name
    key         = "data/year=$${parse_time(\"yyyy\", timestamp())}/month=$${parse_time(\"MM\", timestamp())}/day=$${parse_time(\"dd\", timestamp())}/$${topic(3)}_$${newuuid()}.json"
    role_arn    = var.lab_role_arn
  }
}

# ── Regla 3: Alerta de temperatura crítica ────────────────────────────────────
# Dispara la Lambda de alerta cuando la temperatura supera el umbral.
# Esto es lo único verdaderamente nuevo respecto al lab base.

resource "aws_iot_topic_rule" "alert_rule" {
  name        = "SensorAlertRule_${var.environment}"
  description = "Dispara alerta cuando temperatura supera ${var.alert_threshold}°C"
  enabled     = true
  sql         = "SELECT * FROM 'lab/sensors/data' WHERE sensor_type = 'temperature' AND value > ${var.alert_threshold}"
  sql_version = "2016-03-23"

  lambda {
    function_arn = var.alert_lambda_arn
  }
}

# Permiso para que IoT Core invoque la Lambda de alerta
resource "aws_lambda_permission" "iot_invoke_alert" {
  statement_id  = "AllowIoTCoreInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.alert_lambda_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.alert_rule.arn
}
