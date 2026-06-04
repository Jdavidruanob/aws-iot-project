data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# LabRole predefinido del AWS Learner Lab — se usa en lugar de crear roles IAM
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# Endpoint único de IoT Core de esta cuenta (se inyecta en mosquitto.conf)
data "aws_iot_endpoint" "iot_endpoint" {
  endpoint_type = "iot:Data-ATS"
}

# Amazon Root CA para que Mosquitto verifique la identidad de AWS
data "http" "root_ca" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}

# VPC por defecto del Learner Lab
data "aws_vpc" "default" {
  default = true
}

# Subnets de la VPC por defecto
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Subnet específica en us-east-1a para el EC2 de PostgreSQL
# (us-east-1e no soporta t3.micro en el Learner Lab)
data "aws_subnet" "postgres_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availabilityZone"
    values = ["us-east-1a"]
  }
}

# Route table principal de la VPC (para el VPC endpoint de S3)
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# AMI más reciente de Amazon Linux 2023 para EC2 de PostgreSQL
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
