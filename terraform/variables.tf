variable "aws_region" {
  description = "AWS region for ECS resources"
  type        = string
  default     = "us-east-2"
}

variable "backend_image_tag" {
  description = "Docker tag for the backend API image"
  type        = string
  default     = "latest"
}

variable "worker_image_tag" {
  description = "Docker tag for the worker image"
  type        = string
  default     = "latest"
}

variable "auth_token" {
  description = "Auth token value stored in SSM Parameter Store"
  type        = string
  sensitive   = true
}

variable "desired_count" {
  description = "Desired count for the API ECS service (also used as autoscaling minimum)"
  type        = number
  default     = 1
}

variable "api_max_capacity" {
  description = "Maximum API tasks when scaling on CPU/memory"
  type        = number
  default     = 5
}

variable "worker_desired_count" {
  description = "Desired count for the worker ECS service (also used as autoscaling minimum)"
  type        = number
  default     = 1
}

variable "worker_max_capacity" {
  description = "Maximum worker tasks when scaling on SQS backlog"
  type        = number
  default     = 5
}

variable "worker_scale_target_messages_per_task" {
  description = "Target SQS messages visible per running worker task (scale out when backlog per task exceeds this)"
  type        = number
  default     = 5
}

variable "task_cpu" {
  description = "CPU units for ECS tasks"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Memory (MB) for ECS tasks"
  type        = string
  default     = "512"
}

variable "worker_poll_interval_seconds" {
  description = "Worker SQS polling interval in seconds"
  type        = number
  default     = 10
}

variable "alert_emails" {
  description = "Emails for CloudWatch alarm SNS notifications (each recipient must confirm AWS subscription after apply)"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for email in var.alert_emails : can(regex("^[^@]+@[^@]+\\.[^@]+$", email))
    ])
    error_message = "Each entry in alert_emails must be a valid email address."
  }
}


