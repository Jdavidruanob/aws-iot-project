output "sensor_table_name" {
  value = aws_dynamodb_table.sensor_data.name
}

output "registry_table_name" {
  value = aws_dynamodb_table.sensors_registry.name
}
