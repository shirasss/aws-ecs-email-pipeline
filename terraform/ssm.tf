resource "aws_ssm_parameter" "auth_token" {
  name  = "/email-pipeline/auth-token"
  type  = "SecureString"
  value = var.auth_token

  tags = {
    Name = "email-pipeline-auth-token"
  }
}
