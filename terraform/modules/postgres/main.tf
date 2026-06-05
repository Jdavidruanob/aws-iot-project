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

  user_data = templatefile("${path.module}/user_data.sh", {
    postgres_password = var.postgres_password
  })

  tags = {
    Name        = "${var.project_name}-postgres-${var.environment}"
    Environment = var.environment
  }
}
