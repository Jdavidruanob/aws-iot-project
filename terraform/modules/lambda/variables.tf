variable "lab_role_arn"       { type = string }
variable "sensor_bucket_name" { type = string }
variable "sensor_bucket_arn"  { type = string }
variable "sqs_queue_url"      { type = string }
variable "sqs_queue_arn"      { type = string }
variable "postgres_host"      { type = string }
variable "subnet_ids"         { type = list(string) }
variable "lambda_sg_id"       { type = string }

variable "postgres_password" {
  type      = string
  sensitive = true
}
