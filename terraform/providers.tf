terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "terraform-state-email-pipeline"
    key            = "email-pipeline/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}


data "aws_caller_identity" "current" {}

provider "aws" {
  region = var.aws_region
}