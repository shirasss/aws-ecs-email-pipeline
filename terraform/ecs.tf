resource "aws_ecs_cluster" "cluster" {
  name = "email-pipeline-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "email-pipeline-api-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_api_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "email-pipeline-api-container"
      image     = "${aws_ecr_repository.api.repository_url}:${var.backend_image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 5000
          hostPort      = 5000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "QUEUE_URL", value = aws_sqs_queue.email_queue.url },
        { name = "TOKEN_PARAMETER_NAME", value = aws_ssm_parameter.auth_token.name }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:5000/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "api" {
  name                               = "email-pipeline-api-service"
  cluster                            = aws_ecs_cluster.cluster.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 50

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs_tasks_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api_tg.arn
    container_name   = "email-pipeline-api-container"
    container_port   = 5000
  }

  # CI/CD owns the task definition's image tag (registers a new revision on
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "email-pipeline-worker-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_worker_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "email-pipeline-worker-container"
      image     = "${aws_ecr_repository.worker.repository_url}:${var.worker_image_tag}"
      essential = true
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "QUEUE_URL", value = aws_sqs_queue.email_queue.url },
        { name = "BUCKET_NAME", value = aws_s3_bucket.email_bucket.bucket },
        { name = "POLL_INTERVAL_SECONDS", value = tostring(var.worker_poll_interval_seconds) }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:5000/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 5
        startPeriod = 120
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  name                               = "email-pipeline-worker-service"
  cluster                            = aws_ecs_cluster.cluster.id
  task_definition                    = aws_ecs_task_definition.worker.arn
  desired_count                      = var.worker_desired_count
  launch_type                        = "FARGATE"
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 50

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs_tasks_sg.id]
    assign_public_ip = false
  }

  # See API service: CI/CD owns task_definition revisions; autoscaling owns
  # desired_count.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
