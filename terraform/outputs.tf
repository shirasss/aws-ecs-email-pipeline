output "alb_dns_name" {
  description = "ALB DNS name for the API service"
  value       = aws_lb.alb.dns_name
}

output "api_endpoint" {
  description = "HTTP endpoint for the API service"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "s3_bucket_name" {
  description = "S3 bucket name for processed emails"
  value       = aws_s3_bucket.email_bucket.bucket
}

output "sqs_queue_url" {
  description = "SQS queue URL for the email pipeline"
  value       = aws_sqs_queue.email_queue.url
}

output "ssm_token_parameter_name" {
  description = "SSM parameter name for the API auth token (not the secret value)"
  value       = aws_ssm_parameter.auth_token.name
}

output "api_ecr_repository" {
  description = "ECR repository URL for the API"
  value       = aws_ecr_repository.api.repository_url
}

output "worker_ecr_repository" {
  description = "ECR repository URL for the worker"
  value       = aws_ecr_repository.worker.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.cluster.name
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch dashboard for ECS microservices (ALB, SQS, ECS)"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "cloudwatch_log_groups" {
  description = "CloudWatch log groups (ECS services)"
  value = {
    api    = aws_cloudwatch_log_group.api.name
    worker = aws_cloudwatch_log_group.worker.name
  }
}

