variable "ami_id"            { type = string }
variable "lab_role_arn"      { type = string }
variable "subnet_id"         { type = string }
variable "security_group_id" { type = string }
variable "project_name"      { type = string }
variable "environment"       { type = string }

variable "postgres_password" {
  type      = string
  sensitive = true
}
