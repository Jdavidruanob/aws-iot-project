output "private_ip" {
  description = "IP privada del EC2 con PostgreSQL (usada por Lambda y ECS dentro de la VPC)"
  value       = aws_instance.postgres.private_ip
}
