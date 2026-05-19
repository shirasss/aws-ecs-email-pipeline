locals {
  alert_emails_enabled = length(var.alert_emails) > 0
  alarm_sns_actions    = local.alert_emails_enabled ? [aws_sns_topic.alarm_notifications[0].arn] : []
}

resource "aws_sns_topic" "alarm_notifications" {
  count = local.alert_emails_enabled ? 1 : 0
  name  = "email-pipeline-alarms"

  tags = {
    Name = "email-pipeline-alarms"
  }
}

resource "aws_sns_topic_subscription" "alarm_email" {
  for_each  = local.alert_emails_enabled ? toset(var.alert_emails) : toset([])
  topic_arn = aws_sns_topic.alarm_notifications[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_policy" "alarm_notifications" {
  count = local.alert_emails_enabled ? 1 : 0
  arn   = aws_sns_topic.alarm_notifications[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alarm_notifications[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/email-pipeline-api"
  retention_in_days = 30

  tags = {
    Name = "email-pipeline-api-logs"
  }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/email-pipeline-worker"
  retention_in_days = 30

  tags = {
    Name = "email-pipeline-worker-logs"
  }
}

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "email-pipeline-api-log-errors"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "ERROR"

  metric_transformation {
    name          = "LogErrorCount"
    namespace     = "EmailPipeline/Logs"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "worker_errors" {
  name           = "email-pipeline-worker-log-errors"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "ERROR"

  metric_transformation {
    name          = "WorkerLogErrorCount"
    namespace     = "EmailPipeline/Logs"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "ecs-email-pipeline-dashboards"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Request Count"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.alb.arn_suffix]
          ]
          stat   = "Sum"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB 5XX Errors"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.alb.arn_suffix]
          ]
          stat   = "Sum"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "SQS Throughput (Sent / Received / Deleted)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.email_queue.name, { label = "Sent (API → queue)" }],
            ["...", "NumberOfMessagesReceived", ".", ".", { label = "Received (worker polled)" }],
            ["...", "NumberOfMessagesDeleted", ".", ".", { label = "Deleted (worker processed)" }]
          ]
          stat   = "Sum"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "SQS Main Queue Backlog"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.email_queue.name, { label = "Visible (waiting)", stat = "Average" }],
            ["...", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "In-flight (being processed)", stat = "Average" }],
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.email_queue.name, { label = "Oldest msg age (s)", stat = "Maximum", yAxis = "right" }]
          ]
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "SQS DLQ (failed messages)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.email_dlq.name, { label = "DLQ depth", stat = "Average" }],
            ["...", "NumberOfMessagesSent", ".", ".", { label = "Arrived in DLQ", stat = "Sum" }],
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.email_dlq.name, { label = "Oldest DLQ msg age (s)", stat = "Maximum", yAxis = "right" }]
          ]
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "ECS API CPU Utilization"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.cluster.name, "ServiceName", aws_ecs_service.api.name]
          ]
          stat   = "Average"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "ECS Worker CPU Utilization"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.cluster.name, "ServiceName", aws_ecs_service.worker.name]
          ]
          stat   = "Average"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "ECS API Memory Utilization"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.cluster.name, "ServiceName", aws_ecs_service.api.name]
          ]
          stat   = "Average"
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "ECS Worker Memory Utilization"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.cluster.name, "ServiceName", aws_ecs_service.worker.name]
          ]
          stat   = "Average"
          period = 60
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "email-pipeline-sqs-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Alert when failed messages appear in the DLQ"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    QueueName = aws_sqs_queue.email_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "email-pipeline-alb-target-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Alert when ALB target 5XX errors exceed threshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    LoadBalancer = aws_lb.alb.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "api_cpu_high" {
  alarm_name          = "email-pipeline-api-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Alert when API service CPU is consistently high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.api.name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_memory_high" {
  alarm_name          = "email-pipeline-api-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Alert when API service memory is consistently high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.api.name
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  alarm_name          = "email-pipeline-sqs-backlog-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Alert when the main SQS queue backlog is high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    QueueName = aws_sqs_queue.email_queue.name
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_cpu_high" {
  alarm_name          = "email-pipeline-worker-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Alert when worker service CPU is consistently high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.worker.name
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_memory_high" {
  alarm_name          = "email-pipeline-worker-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Alert when worker service memory is consistently high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions

  dimensions = {
    ClusterName = aws_ecs_cluster.cluster.name
    ServiceName = aws_ecs_service.worker.name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_log_errors" {
  alarm_name          = "email-pipeline-api-log-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "LogErrorCount"
  namespace           = "EmailPipeline/Logs"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Elevated ERROR lines in API CloudWatch logs"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions
}

resource "aws_cloudwatch_metric_alarm" "worker_log_errors" {
  alarm_name          = "email-pipeline-worker-log-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "WorkerLogErrorCount"
  namespace           = "EmailPipeline/Logs"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Elevated ERROR lines in worker CloudWatch logs"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_sns_actions
  ok_actions          = local.alarm_sns_actions
}
