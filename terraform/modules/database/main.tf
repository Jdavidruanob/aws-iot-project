# Tabla de eventos de sensores — hot data con historial
# hash_key + range_key permiten guardar MÚLTIPLES eventos por sensor.
# Sin range_key (como en el lab base), DynamoDB sobrescribiría el evento anterior.
# Con range_key (timestamp), cada evento es único → podemos pedir los últimos N.
resource "aws_dynamodb_table" "sensor_data" {
  name         = "SensorData-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"
  range_key    = "timestamp"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Tabla de registro de sensores — catálogo de dispositivos conocidos
# POST /sensors crea un ítem aquí; GET /sensors hace un Scan sobre esta tabla.
resource "aws_dynamodb_table" "sensors_registry" {
  name         = "SensorsRegistry-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}
