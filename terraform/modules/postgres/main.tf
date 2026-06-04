# Instance profile para que EC2 use el LabRole
resource "aws_iam_instance_profile" "postgres" {
  name = "iot-postgres-profile-${var.environment}"
  role = split("/", var.lab_role_arn)[1]
}

resource "aws_instance" "postgres" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.postgres.name
  associate_public_ip_address = true

  # UserData: instala Docker, levanta PostgreSQL y crea el esquema de la base de datos
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Instalar Docker
    yum update -y
    yum install -y docker
    systemctl start docker
    systemctl enable docker

    # Levantar contenedor PostgreSQL
    docker run -d \
      --name postgres \
      --restart unless-stopped \
      -e POSTGRES_DB=iotdb \
      -e POSTGRES_USER=iotuser \
      -e POSTGRES_PASSWORD=${var.postgres_password} \
      -p 5432:5432 \
      postgres:15-alpine

    # Esperar que PostgreSQL arranque
    sleep 30

    # Crear esquema: tabla de eventos históricos
    docker exec postgres psql -U iotuser -d iotdb -c "
      CREATE TABLE IF NOT EXISTS sensor_events (
        id          SERIAL PRIMARY KEY,
        device_id   VARCHAR(255) NOT NULL,
        sensor_type VARCHAR(100) NOT NULL,
        value       DECIMAL(10, 2) NOT NULL,
        timestamp   TIMESTAMPTZ NOT NULL,
        created_at  TIMESTAMPTZ DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS idx_device_id ON sensor_events(device_id);
      CREATE INDEX IF NOT EXISTS idx_timestamp  ON sensor_events(timestamp);
    "
  EOF

  tags = {
    Name        = "${var.project_name}-postgres-${var.environment}"
    Environment = var.environment
  }
}
