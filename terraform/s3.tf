resource "aws_s3_bucket" "email_bucket" {
  bucket        = "email-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "email-pipeline-email-bucket"
  }
}

resource "aws_s3_bucket_versioning" "email_bucket" {
  bucket = aws_s3_bucket.email_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "email_bucket" {
  bucket = aws_s3_bucket.email_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Public access block omitted: account SCP denies s3:PutBucketPublicAccessBlock.
