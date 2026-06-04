terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ── Storage (S3) ─────────────────────────────────────────────────────────────
module "storage" {
  source       = "./modules/storage"
  project_name = var.project_name
  environment  = var.environment
}

# ── Database (DynamoDB) ───────────────────────────────────────────────────────
module "database" {
  source       = "./modules/database"
  project_name = var.project_name
  environment  = var.environment
}

# ── Networking (Security Groups + VPC Endpoint S3) ────────────────────────────
module "networking" {
  source   = "./modules/networking"
  vpc_id   = data.aws_vpc.default.id
  route_table_id = data.aws_route_table.main.id
}

# ── PostgreSQL EC2 ────────────────────────────────────────────────────────────
module "postgres" {
  source            = "./modules/postgres"
  ami_id            = data.aws_ami.amazon_linux_2023.id
  lab_role_arn      = data.aws_iam_role.lab_role.arn
  subnet_id         = data.aws_subnet.postgres_az.id
  security_group_id = module.networking.postgres_sg_id
  postgres_password = var.postgres_password
  project_name      = var.project_name
  environment       = var.environment
}

# ── Lambda Functions ──────────────────────────────────────────────────────────
module "lambda" {
  source              = "./modules/lambda"
  lab_role_arn        = data.aws_iam_role.lab_role.arn
  sensor_bucket_name  = module.storage.sensor_bucket_name
  sensor_bucket_arn   = module.storage.sensor_bucket_arn
  sqs_queue_url       = module.messaging.queue_url
  sqs_queue_arn       = module.messaging.queue_arn
  postgres_host       = module.postgres.private_ip
  postgres_password   = var.postgres_password
  subnet_ids          = tolist(data.aws_subnets.default.ids)
  lambda_sg_id        = module.networking.lambda_sg_id
}

# ── SQS ───────────────────────────────────────────────────────────────────────
# Solo crea la cola. El Event Source Mapping (SQS→Lambda) vive en el módulo lambda
# para evitar dependencia circular.
module "messaging" {
  source       = "./modules/messaging"
  project_name = var.project_name
  environment  = var.environment
}

# ── IoT Core (Rules + Certificados) ──────────────────────────────────────────
module "iot" {
  source               = "./modules/iot"
  project_name         = var.project_name
  environment          = var.environment
  lab_role_arn         = data.aws_iam_role.lab_role.arn
  account_id           = data.aws_caller_identity.current.account_id
  region               = data.aws_region.current.name
  iot_endpoint         = data.aws_iot_endpoint.iot_endpoint.endpoint_address
  root_ca_pem          = data.http.root_ca.response_body
  sensor_bucket_name   = module.storage.sensor_bucket_name
  sensor_table_name    = module.database.sensor_table_name
  alert_lambda_arn     = module.lambda.alert_lambda_arn
  alert_lambda_name    = module.lambda.alert_lambda_name
  alert_threshold      = var.alert_threshold
}

# ── ECS (API FastAPI) ─────────────────────────────────────────────────────────
module "compute" {
  source                   = "./modules/compute"
  project_name             = var.project_name
  environment              = var.environment
  api_image                = var.api_image
  lab_role_arn             = data.aws_iam_role.lab_role.arn
  vpc_id                   = data.aws_vpc.default.id
  subnet_ids               = tolist(data.aws_subnets.default.ids)
  ecs_sg_id                = module.networking.ecs_sg_id
  alb_sg_id                = module.networking.alb_sg_id
  events_table_name        = module.database.sensor_table_name
  registry_table_name      = module.database.registry_table_name
  postgres_host            = module.postgres.private_ip
  postgres_password        = var.postgres_password
  aws_region               = data.aws_region.current.name
}
