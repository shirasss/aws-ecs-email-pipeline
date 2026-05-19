# GitHub Actions OIDC trust for short-lived AWS credentials.
#
# Lets GitHub Actions assume an IAM role using a signed JWT instead of
# storing long-lived AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in GitHub
# secrets. Each workflow run gets a fresh STS session that auto-expires.

variable "github_actions_repository" {
  description = "GitHub repo allowed to assume the deploy role, in 'owner/repo' format. Leave empty to disable OIDC role creation."
  type        = string
  default     = ""

  validation {
    condition     = var.github_actions_repository == "" || can(regex("^[^/]+/[^/]+$", var.github_actions_repository))
    error_message = "github_actions_repository must be empty or in the form owner/repo."
  }
}

locals {
  enable_github_oidc = var.github_actions_repository != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "email-pipeline-github-oidc"
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  count = local.enable_github_oidc ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only allow workflows from this repository (any branch / tag / PR).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_actions_repository}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  count = local.enable_github_oidc ? 1 : 0

  name               = "email-pipeline-github-actions-deploy"
  description        = "Assumed by GitHub Actions via OIDC to build images and deploy ECS services."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "email-pipeline-github-actions-deploy"
  }
}

data "aws_iam_policy_document" "github_actions_deploy" {
  count = local.enable_github_oidc ? 1 : 0

  # ECR auth + read + push for the two service repos.
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      aws_ecr_repository.api.arn,
      aws_ecr_repository.worker.arn,
    ]
  }

  # ECS describe + register + update for the two services.
  statement {
    sid    = "ECSDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
    ]
    resources = ["*"]
  }

  # The deploy step registers a new task definition that references the
  # task role and execution role, which requires PassRole.
  statement {
    sid    = "PassTaskRoles"
    effect = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_task_execution_role.arn,
      aws_iam_role.ecs_api_task_role.arn,
      aws_iam_role.ecs_worker_task_role.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  count = local.enable_github_oidc ? 1 : 0

  name   = "email-pipeline-github-actions-deploy-policy"
  role   = aws_iam_role.github_actions_deploy[0].id
  policy = data.aws_iam_policy_document.github_actions_deploy[0].json
}

output "github_actions_role_arn" {
  description = "ARN to set as the GitHub Actions secret AWS_DEPLOY_ROLE_ARN. Empty if OIDC is disabled."
  value       = local.enable_github_oidc ? aws_iam_role.github_actions_deploy[0].arn : ""
}
