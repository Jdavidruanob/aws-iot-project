output "postgres_sg_id"  { value = aws_security_group.postgres.id }
output "lambda_sg_id"   { value = aws_security_group.lambda.id }
output "alb_sg_id"      { value = aws_security_group.alb.id }
output "ecs_sg_id"      { value = aws_security_group.ecs_tasks.id }
