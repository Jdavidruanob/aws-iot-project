resource "random_id" "id" {
  byte_length = 4
}

# Bucket para cold data (archivos JSON de IoT Core, particionados por fecha)
resource "aws_s3_bucket" "sensor_data" {
  bucket        = "${var.environment}-${var.project_name}-sensor-data-${random_id.id.hex}"
  force_destroy = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}
