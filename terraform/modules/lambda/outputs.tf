output "alert_lambda_arn"         { value = aws_lambda_function.alert.arn }
output "alert_lambda_name"        { value = aws_lambda_function.alert.function_name }
output "cloudwatch_logger_arn"    { value = aws_lambda_function.cloudwatch_logger.arn }
output "cloudwatch_logger_name"   { value = aws_lambda_function.cloudwatch_logger.function_name }
