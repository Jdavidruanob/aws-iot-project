output "iot_endpoint" {
  description = "Endpoint de AWS IoT Core (inyectado en mosquitto.conf)"
  value       = data.aws_iot_endpoint.iot_endpoint.endpoint_address
}

output "api_url" {
  description = "URL pública de la API REST (ALB)"
  value       = "http://${module.compute.alb_dns_name}"
}

output "sensor_bucket_name" {
  description = "Bucket S3 donde se guardan los datos históricos (cold data)"
  value       = module.storage.sensor_bucket_name
}

output "dynamodb_events_table" {
  description = "Tabla DynamoDB para eventos de sensores (hot data)"
  value       = module.database.sensor_table_name
}

output "dynamodb_registry_table" {
  description = "Tabla DynamoDB para el registro de sensores"
  value       = module.database.registry_table_name
}

output "postgres_private_ip" {
  description = "IP privada del EC2 con PostgreSQL"
  value       = module.postgres.private_ip
}
