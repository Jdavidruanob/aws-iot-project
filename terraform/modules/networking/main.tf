# VPC Gateway Endpoint para S3 (gratuito)
# Permite que Lambda (dentro de la VPC) acceda a S3 sin pasar por internet.
# Lambda en VPC no tiene IP pública, así que necesita este endpoint para leer objetos de S3.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.route_table_id]

  tags = { Name = "s3-vpc-endpoint" }
}

# Security Group: PostgreSQL EC2
# Solo acepta conexiones en puerto 5432 desde Lambda y ECS dentro de la VPC.
resource "aws_security_group" "postgres" {
  name        = "iot-postgres-sg"
  description = "PostgreSQL: acepta 5432 desde Lambda y ECS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL desde Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  ingress {
    description     = "PostgreSQL desde ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iot-postgres-sg" }
}

# Security Group: Lambda s3_to_postgres
# Lambda necesita salida a PostgreSQL (5432) y al endpoint de S3 (443, vía VPC endpoint).
resource "aws_security_group" "lambda" {
  name        = "iot-lambda-sg"
  description = "Lambda en VPC: puede hablar con PostgreSQL"
  vpc_id      = var.vpc_id

  egress {
    description = "Salida total (S3 via VPC endpoint, PostgreSQL, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iot-lambda-sg" }
}

# Security Group: ALB (Application Load Balancer)
# Acepta tráfico HTTP público en puerto 80.
resource "aws_security_group" "alb" {
  name        = "iot-alb-sg"
  description = "ALB: acepta HTTP desde internet"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iot-alb-sg" }
}

# Security Group: ECS Tasks (FastAPI)
# Solo acepta tráfico en puerto 8000 proveniente del ALB.
resource "aws_security_group" "ecs_tasks" {
  name        = "iot-ecs-tasks-sg"
  description = "ECS tasks: acepta 8000 desde ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "FastAPI desde ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iot-ecs-tasks-sg" }
}
