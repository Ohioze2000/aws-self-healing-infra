output "cloudwatch_alarms_topic_arn" {
  description = "ARN of the SNS topic for CloudWatch alarms"
  value       = aws_sns_topic.cloudwatch_alarms_topic.arn
}


output "high_cpu_alarm_arn" {
  description = "ARN of the High CPU alarm"
  value       = aws_cloudwatch_metric_alarm.high_cpu_alarm.arn
}

output "high_disk_alarm_arn" {
  description = "ARN of the High Disk Usage alarm"
  value       = length(aws_cloudwatch_metric_alarm.high_disk_alarm) > 0 ? aws_cloudwatch_metric_alarm.high_disk_alarm[0].arn : null
}

output "log_error_alarm_arn" {
  description = "ARN of the Log Error alarm"
  value       = length(aws_cloudwatch_metric_alarm.app_error_alarm) > 0 ? aws_cloudwatch_metric_alarm.app_error_alarm[0].arn : null
}
output "app_log_group_name" {
  description = "CloudWatch log group used by the application error metric filter"
  value       = aws_cloudwatch_log_group.app_log_group.name
}

output "cw_agent_config_parameter_arn" {
  description = "ARN of the SSM Parameter Store entry containing the CloudWatch agent configuration"
  value       = aws_ssm_parameter.cw_agent_config.arn
}

output "remediation_incident_table_name" {
  description = "DynamoDB table storing bounded remediation incident state"
  value       = aws_dynamodb_table.remediation_incidents.name
}

output "remediation_dispatcher_function_name" {
  description = "Name of the SNS-triggered remediation dispatcher Lambda"
  value       = aws_lambda_function.remediation_dispatcher.function_name
}
