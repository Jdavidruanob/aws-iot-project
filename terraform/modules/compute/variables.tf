variable "project_name"         { type = string }
variable "environment"          { type = string }
variable "api_image"            { type = string }
variable "lab_role_arn"         { type = string }
variable "vpc_id"               { type = string }
variable "subnet_ids"           { type = list(string) }
variable "ecs_sg_id"            { type = string }
variable "alb_sg_id"            { type = string }
variable "events_table_name"    { type = string }
variable "registry_table_name"  { type = string }
variable "postgres_host"        { type = string }
variable "aws_region"           { type = string }

variable "postgres_password" {
  type      = string
  sensitive = true
}
