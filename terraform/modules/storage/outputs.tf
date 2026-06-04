output "sensor_bucket_name" {
  value = aws_s3_bucket.sensor_data.id
}

output "sensor_bucket_arn" {
  value = aws_s3_bucket.sensor_data.arn
}
