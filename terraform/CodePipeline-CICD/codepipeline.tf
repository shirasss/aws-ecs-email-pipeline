# =============================================================================
# Alternative CI/CD: AWS CodePipeline + CodeBuild
# -----------------------------------------------------------------------------
# Primary CI/CD lives in .github/workflows. This file is a fully written
# AWS-native reference implementation kept in place as an optional alternative.


locals {
  api_pipeline_path_includes = [
    "service1/**",
    "terraform/CodePipeline-CICD/buildspec.ci-api.yml",
    "scripts/trivy-scan.sh",
  ]

  worker_pipeline_path_includes = [
    "service2/**",
    "terraform/CodePipeline-CICD/buildspec.ci-worker.yml",
    "scripts/trivy-scan.sh",
  ]
}

resource "aws_codestarconnections_connection" "github" {
  name          = "email-pipeline-github"
  provider_type = "GitHub"

  tags = {
    Name = "email-pipeline-github"
  }
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "email-pipeline-codepipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "email-pipeline-codepipeline-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name = "email-pipeline-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "email-pipeline-codepipeline-role"
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "email-pipeline-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection"
        ]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = [
          aws_codebuild_project.ci_api.arn,
          aws_codebuild_project.ci_worker.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.ecs_api_task_role.arn,
          aws_iam_role.ecs_worker_task_role.arn
        ]
      }
    ]
  })
}

# Pipeline 1 — service1 (REST API)
resource "aws_codepipeline" "service1" {
  name           = "email-pipeline-service1"
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.github_branch]
        }

        file_paths {
          includes = local.api_pipeline_path_includes
        }
      }
    }
  }

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository_id
        BranchName       = var.github_branch
        DetectChanges    = "false"
      }
    }
  }

  stage {
    name = "CI"

    action {
      name             = "CI"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["ci_output"]

      configuration = {
        ProjectName = aws_codebuild_project.ci_api.name
      }
    }
  }

  # Optional (enterprise): manual production approval before deploy 
  # stage {
  #   name = "Approval"
  #
  #   action {
  #     name     = "ProductionApproval"
  #     category = "Approval"
  #     owner    = "AWS"
  #     provider = "Manual"
  #     version  = "1"
  #
  #     configuration = {
  #       CustomData = "Approve production deployment of service1 (API)."
  #     }
  #   }
  # }

  stage {
    name = "CD"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["ci_output"]

      configuration = {
        ClusterName = aws_ecs_cluster.cluster.name
        ServiceName = aws_ecs_service.api.name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  tags = {
    Name = "email-pipeline-service1"
  }
}

# Pipeline 2 — service2 (SQS worker)
resource "aws_codepipeline" "service2" {
  name           = "email-pipeline-service2"
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.github_branch]
        }

        file_paths {
          includes = local.worker_pipeline_path_includes
        }
      }
    }
  }

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository_id
        BranchName       = var.github_branch
        DetectChanges    = "false"
      }
    }
  }

  stage {
    name = "CI"

    action {
      name             = "CI"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["ci_output"]

      configuration = {
        ProjectName = aws_codebuild_project.ci_worker.name
      }
    }
  }

  # Optional (enterprise): manual production approval before deploy
  # stage {
  #   name = "Approval"
  #
  #   action {
  #     name     = "ProductionApproval"
  #     category = "Approval"
  #     owner    = "AWS"
  #     provider = "Manual"
  #     version  = "1"
  #
  #     configuration = {
  #       CustomData = "Approve production deployment of service2 (worker)."
  #     }
  #   }
  # }

  stage {
    name = "CD"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["ci_output"]

      configuration = {
        ClusterName = aws_ecs_cluster.cluster.name
        ServiceName = aws_ecs_service.worker.name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  tags = {
    Name = "email-pipeline-service2"
  }
}

resource "aws_codebuild_project" "ci_api" {
  name          = "email-pipeline-ci-api"
  description   = "CI service1 — service1/tests, build, scan, push to ECR"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 25

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      status      = "ENABLED"
      stream_name = "ci-api"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/CodePipeline-CICD/buildspec.ci-api.yml"
  }

  tags = {
    Name = "email-pipeline-ci-api"
  }
}

resource "aws_codebuild_project" "ci_worker" {
  name          = "email-pipeline-ci-worker"
  description   = "CI service2 — service2/tests, build, scan, push to ECR"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 25

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      status      = "ENABLED"
      stream_name = "ci-worker"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/CodePipeline-CICD/buildspec.ci-worker.yml"
  }

  tags = {
    Name = "email-pipeline-ci-worker"
  }
}

resource "aws_iam_role" "codebuild" {
  name = "email-pipeline-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "email-pipeline-codebuild-role"
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name = "email-pipeline-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/codebuild/email-pipeline"
  retention_in_days = 14

  tags = {
    Name = "email-pipeline-codebuild-logs"
  }
}
