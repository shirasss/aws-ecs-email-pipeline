resource "aws_sqs_queue" "email_dlq" {
  name                      = "email-pipeline-queue-dlq"
  message_retention_seconds = 1209600

  tags = {
    Name = "email-pipeline-queue-dlq"
  }
}

resource "aws_sqs_queue" "email_queue" {
  name                       = "email-pipeline-queue"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 1209600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.email_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "email-pipeline-queue"
  }
}
