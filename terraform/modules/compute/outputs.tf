output "alb_dns_name" {
  description = "DNS del ALB — URL pública de la API"
  value       = aws_lb.api.dns_name
}
