# ==============================================================================
# 1. CORE NOTIFICATION INFRASTRUCTURE
# ==============================================================================

resource "aws_sns_topic" "cloudwatch_alarms_topic" {
  name              = "${var.env_prefix}-cloudwatch-alarms"
  display_name      = "${var.env_prefix} CloudWatch Alarms"
  kms_master_key_id = var.sns_kms_key_id

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-cloudwatch-alarms"
    }
  )
}

# SNS Topic Policy allowing CloudWatch to publish alarms securely
resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.cloudwatch_alarms_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchToPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.cloudwatch_alarms_topic.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:*:*:alarm:${var.env_prefix}-*"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email_subscription" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.cloudwatch_alarms_topic.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ==============================================================================
# 2. SSM PARAMETER STORE (CLOUDWATCH AGENT CONFIGURATION)
# ==============================================================================

resource "aws_ssm_parameter" "cw_agent_config" {
  name        = var.cloudwatch_agent_parameter_name
  description = "CloudWatch Agent configuration JSON for EC2 instances in Auto Scaling Group"
  type        = "String"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60,
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "CWAgent"
      append_dimensions = {
        InstanceId           = "$${aws:InstanceId}"
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
      }
      aggregation_dimensions = [
        ["InstanceId"],
        ["AutoScalingGroupName", "path", "fstype"]
      ]
      metrics_collected = {
        cpu = {
          metrics_collection_interval = 60
          measurement = [
            "cpu_usage_idle",
            "cpu_usage_iowait",
            "cpu_usage_user",
            "cpu_usage_system"
          ]
          totalcpu = true
        }
        disk = {
          metrics_collection_interval = 60
          resources                   = ["/"]
          measurement                 = ["disk_used_percent", "inodes_free"]
          ignore_file_system_types    = ["sysfs", "devtmpfs", "tmpfs"]
          drop_device                 = true
        }
        mem = {
          metrics_collection_interval = 60
          measurement                 = ["mem_used_percent"]
        }
        swap = {
          metrics_collection_interval = 60
          measurement                 = ["swap_used_percent"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path         = "/var/log/cloud-init-output.log"
              log_group_name    = "/ec2/cloud-init-output"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/user-data.log"
              log_group_name    = "/ec2/user-data"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/nginx/access.log"
              log_group_name    = "/ec2/nginx/access"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/nginx/error.log"
              log_group_name    = "/ec2/nginx/error"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/app/*.log"
              log_group_name    = "/ec2/app-logs"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            }
          ]
        }
      }
    }
  })
}

resource "aws_cloudwatch_log_group" "app_log_group" {
  name              = var.app_log_group_name
  retention_in_days = var.log_retention_in_days

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-app-logs"
    }
  )
}

# ==============================================================================
# 3. METRIC ALARMS
# ==============================================================================

# --- HIGH CPU ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "${var.env_prefix}-ASG-High-CPU-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.cpu_evaluation_periods
  datapoints_to_alarm = var.cpu_datapoints_to_alarm
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = var.cpu_alarm_period
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "Alarm when average CPU utilization across Auto Scaling Group '${var.asg_name}' exceeds ${var.cpu_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-ASG-High-CPU-Alarm"
    }
  )
}

# --- HIGH MEMORY ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_memory_alarm" {
  alarm_name          = "${var.env_prefix}-ASG-High-Memory-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.memory_evaluation_periods
  datapoints_to_alarm = var.memory_datapoints_to_alarm
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = var.memory_alarm_period
  statistic           = "Average"
  threshold           = var.memory_alarm_threshold
  alarm_description   = "Alarm when average memory utilization across the Auto Scaling Group reaches ${var.memory_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"
  dimensions = {
    AutoScalingGroupName = var.asg_name
  }
  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags = merge(var.tags, { Name = "${var.env_prefix}-ASG-High-Memory-Alarm" })
}

# --- UNHEALTHY TARGET ALARM ---
resource "aws_cloudwatch_metric_alarm" "unhealthy_target_alarm" {
  alarm_name          = "${var.env_prefix}-ALB-Unhealthy-Targets"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "Alarm when one or more targets in the application target group remain unhealthy."
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = var.target_group_arn
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(var.tags, { Name = "${var.env_prefix}-ALB-Unhealthy-Targets-Alarm" })
}

# --- HIGH DISK UTILIZATION ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_disk_alarm" {
  count               = var.enable_disk_alarm ? 1 : 0
  alarm_name          = "${var.env_prefix}-ASG-High-Disk-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.disk_evaluation_periods
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = var.disk_alarm_period
  statistic           = "Average"
  threshold           = var.disk_alarm_threshold
  alarm_description   = "Alarm when root disk utilization exceeds ${var.disk_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.asg_name
    path                 = "/"
    fstype               = var.disk_fstype # Default variable e.g. "ext4" or "xfs"
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-ASG-High-Disk-Alarm"
    }
  )
}

# ==============================================================================
# 4. LOG ERROR MONITORING (FILTER + ALARM)
# ==============================================================================

resource "aws_cloudwatch_log_metric_filter" "app_error_filter" {
  count          = var.enable_log_error_alarm ? 1 : 0
  name           = "${var.env_prefix}-app-error-filter"
  pattern        = var.log_error_pattern
  log_group_name = aws_cloudwatch_log_group.app_log_group.name

  metric_transformation {
    name          = "${var.env_prefix}-AppErrorCount"
    namespace     = "CustomAppMetrics"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_alarm" {
  count               = var.enable_log_error_alarm ? 1 : 0
  alarm_name          = "${var.env_prefix}-App-Log-Errors-Spike"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.app_error_filter[0].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.app_error_filter[0].metric_transformation[0].namespace
  period              = var.log_error_alarm_period
  statistic           = "Sum"
  threshold           = var.log_error_threshold
  alarm_description   = "Alarm when application error occurrences in log group '${var.app_log_group_name}' exceed ${var.log_error_threshold}"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-App-Log-Errors-Alarm"
    }
  )
}

# ==============================================================================
# ==============================================================================
# 5. EVENT-DRIVEN BOUNDED REMEDIATION WITH DYNAMODB INCIDENT STATE
# ============================================================================

data "archive_file" "remediation_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/remediation_lambda.zip"
}

resource "aws_dynamodb_table" "remediation_incidents" {
  name         = "${var.env_prefix}-remediation-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.env_prefix}-remediation-incidents" })
}

resource "aws_iam_role" "remediation_worker_role" {
  name = "${var.env_prefix}-remediation-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "remediation_worker_logs" {
  role       = aws_iam_role.remediation_worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediation_worker_policy" {
  name = "${var.env_prefix}-remediation-worker-policy"
  role = aws_iam_role.remediation_worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DeregisterTargets",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:DetachInstances",
          "ec2:CreateTags",
          "ssm:SendCommand"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.remediation_incidents.arn
      }
    ]
  })
}

resource "aws_iam_role" "remediation_dispatcher_role" {
  name = "${var.env_prefix}-remediation-dispatcher-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "remediation_dispatcher_logs" {
  role       = aws_iam_role.remediation_dispatcher_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediation_dispatcher_policy" {
  name = "${var.env_prefix}-remediation-dispatcher-policy"
  role = aws_iam_role.remediation_dispatcher_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.remediation_incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.remediation_worker.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ssm_remediation_logs" {
  name              = "/aws/ssm/${var.env_prefix}/remediation"
  retention_in_days = var.log_retention_in_days
  tags              = var.tags
}

resource "aws_lambda_function" "remediation_worker" {
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-remediation-worker"
  role             = aws_iam_role.remediation_worker_role.arn
  handler          = "worker.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 120
  environment {
    variables = {
      SLACK_WEBHOOK_URL       = var.slack_webhook_url
      TARGET_GROUP_ARN        = var.target_group_arn
      ASG_NAME                = var.asg_name
      ENV_PREFIX              = var.env_prefix
      MAX_CAPACITY            = tostring(var.remediation_max_capacity)
      INCIDENT_TABLE_NAME     = aws_dynamodb_table.remediation_incidents.name
      VERIFICATION_DELAY_SECONDS = tostring(var.remediation_verification_delay_seconds)
    }
  }
  tags = var.tags
}

resource "aws_lambda_function" "remediation_dispatcher" {
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-remediation-dispatcher"
  role             = aws_iam_role.remediation_dispatcher_role.arn
  handler          = "dispatcher.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = {
      INCIDENT_TABLE_NAME = aws_dynamodb_table.remediation_incidents.name
      WORKER_FUNCTION_NAME = aws_lambda_function.remediation_worker.function_name
      ENV_PREFIX           = var.env_prefix
    }
  }
  tags = var.tags
}

resource "aws_sns_topic_subscription" "dispatcher_subscription" {
  topic_arn = aws_sns_topic.cloudwatch_alarms_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.remediation_dispatcher.arn
}

resource "aws_lambda_permission" "allow_sns_dispatcher" {
  statement_id  = "AllowExecutionFromSNSDispatcher"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_dispatcher.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cloudwatch_alarms_topic.arn
}
