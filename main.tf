terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region     = var.region
  access_key = var.access_key
  secret_key = var.secret_key
}

# SQS Queue
resource "aws_sqs_queue" "egoistdlq" {
  name = "egoist-${var.env}-dlq"

  tags = {
    env = var.env
  }
}

resource "aws_sqs_queue" "egoistsqsqueue" {
  name = "egoist${var.env}queue"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.egoistdlq.arn
    maxReceiveCount = 5
  })
  visibility_timeout_seconds = 60

  tags = {
    env = var.env
  }
}

# ECR
resource "aws_ecr_repository" "egoist-monthly-cron" {
  name = "egoist-${var.env}-monthly-cron"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  tags = {
    env = var.env
  }
}
resource "aws_ecr_repository" "egoist-weekly-cron" {
  name = "egoist-${var.env}-weekly-cron"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  tags = {
    env = var.env
  }
}
resource "aws_ecr_repository" "egoist-sqs-ffmpeg" {
  name = "egoist-${var.env}-sqs-ffmpeg"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  tags = {
    env = var.env
  }
}

# Common Lambda Policies
resource "aws_iam_policy" "aws-lambda-basic-exec" {
  name = "aws-lambda-basic-exec"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        }
    ]
  })
}

resource "aws_iam_policy" "aws-lambda-sqs-basic-exec" {
  name = "aws-lambda-sqs-basic-exec"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
            ],
            "Resource": "*"
        }
    ]
})
}

data "aws_iam_policy_document" "assume_lambda_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "assume_scheduler_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}



# Monthly Lambda
resource "aws_iam_role" "egoist-monthly-cron-lambda-role" {
  name = "egoist-monthly-cron-lambda-role"
  description = "allow lambda to create cloud watch stuff"
  force_detach_policies = true
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_role.json
}
resource "aws_iam_policy_attachment" "monthly-cron-role-attachment" {
  name       = "monthly-cron-role-attachment"
  roles      = [aws_iam_role.egoist-monthly-cron-lambda-role.name]
  policy_arn = aws_iam_policy.aws-lambda-basic-exec.arn
}
resource "aws_lambda_function" "egoist-monthly-cron" {
  function_name = "egoist-${var.env}-monthly-cron"
  package_type = "Image"
  image_uri = "${var.aws_account_url}${aws_ecr_repository.egoist-monthly-cron.name}:latest"
  role = aws_iam_role.egoist-monthly-cron-lambda-role.arn

  environment {
     variables = {
      SQS_QUEUE_URL = aws_sqs_queue.egoistsqsqueue.id
      MYSQL_CONNECTION_STRING = local.envs["MYSQL_CONNECTION_STRING"]
    }
  }

  tags = {
    env = var.env
  }
}

# Monthly Cron Lambda Scheduler
resource "aws_iam_role" "egoist-monthly-lambda-schedule-role" {
  name = "egoist-monthly-lambda-schedule-role"
  description = "Allows Event Bridge Scheduler to invoke monthly cron lambda"
  force_detach_policies = true
  assume_role_policy = data.aws_iam_policy_document.assume_scheduler_role.json
  inline_policy {
    policy = jsonencode({
    Version = "2012-10-17"
    Statement: [
        {
            Action: "lambda:InvokeFunction",
            Resource: "${aws_lambda_function.egoist-monthly-cron.arn}",
            Effect: "Allow"
        }
    ]
  })
  }
}
resource "aws_scheduler_schedule" "egoist-monthly-cron-schedule" {
  name       = "egoist-monthly-cron-schedule"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 5 1 * ? *)" // monthly
  schedule_expression_timezone = "America/Chicago"

  target {
    arn      = aws_lambda_function.egoist-monthly-cron.arn
    role_arn = aws_iam_role.egoist-monthly-lambda-schedule-role.arn
  }
}

# Weekly Lambda
resource "aws_iam_role" "egoist-weekly-cron-lambda-role" {
  name = "egoist-weekly-cron-lambda-role"
  description = "allow lambda to create cloud watch stuff"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_role.json
}
resource "aws_iam_policy_attachment" "weekly-cron-role-attachment" {
  name       = "weekly-cron-role-attachment"
  roles      = [aws_iam_role.egoist-weekly-cron-lambda-role.name]
  policy_arn = aws_iam_policy.aws-lambda-basic-exec.arn
}
resource "aws_lambda_function" "egoist-weekly-cron" {
  function_name = "egoist-${var.env}-weekly-cron"
  package_type = "Image"
  image_uri = "${var.aws_account_url}${aws_ecr_repository.egoist-weekly-cron.name}:latest"
  role = aws_iam_role.egoist-weekly-cron-lambda-role.arn

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.egoistsqsqueue.id
      MYSQL_CONNECTION_STRING = local.envs["MYSQL_CONNECTION_STRING"]
    }
  }

  tags = {
    env = var.env
  }
}

# Weekly Cron Lambda Scheduler
resource "aws_iam_role" "egoist-weekly-lambda-schedule-role" {
  name = "egoist-weekly-lambda-schedule-role"
  description = "Allows Event Bridge Scheduler to invoke weekly cron lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_scheduler_role.json
  inline_policy {
    policy = jsonencode({
    Version = "2012-10-17"
    Statement: [
        {
            Action: "lambda:InvokeFunction",
            Resource: "${aws_lambda_function.egoist-weekly-cron.arn}",
            Effect: "Allow"
        }
    ]
  })
  }
}
resource "aws_scheduler_schedule" "egoist-weekly-cron-schedule" {
  name       = "egoist-weekly-cron-schedule"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 5 ? * SUN *)" // weekly
  schedule_expression_timezone = "America/Chicago"

  target {
    arn      = aws_lambda_function.egoist-weekly-cron.arn
    role_arn = aws_iam_role.egoist-weekly-lambda-schedule-role.arn
  }
}

# SQS Triggered Lambda
resource "aws_iam_role" "egoist-sqs-ffmpeg-lambda-role" {
  name = "egoist-sqs-ffmpeg-lambda-role"
  description = "allow lambda to create cloud watch stuff and do sqs stuff"
  force_detach_policies = true
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_role.json
}
resource "aws_iam_policy_attachment" "sqs-ffmpeg-role-cloud-watch-attachment" {
  name       = "sqs-ffmpeg-role-cloud-watch-attachment"
  roles      = [aws_iam_role.egoist-sqs-ffmpeg-lambda-role.name]
  policy_arn = aws_iam_policy.aws-lambda-basic-exec.arn
}
resource "aws_iam_policy_attachment" "sqs-ffmpeg-role-sqs-attachment" {
  name       = "sqs-ffmpeg-role-sqs-attachment"
  roles      = [aws_iam_role.egoist-sqs-ffmpeg-lambda-role.name]
  policy_arn = aws_iam_policy.aws-lambda-sqs-basic-exec.arn
}
resource "aws_lambda_function" "egoist-sqs-ffmpeg" {
  function_name = "egoist-${var.env}-sqs-ffmpeg"
  package_type = "Image"
  image_uri = "${var.aws_account_url}${aws_ecr_repository.egoist-sqs-ffmpeg.name}:latest"
  role = aws_iam_role.egoist-sqs-ffmpeg-lambda-role.arn

  memory_size = 1000
  timeout = 60

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.egoist-s3-bucket.bucket
      MYSQL_CONNECTION_STRING = local.envs["MYSQL_CONNECTION_STRING"]
    }
  }

  tags = {
    env = var.env
  }
}
resource "aws_lambda_event_source_mapping" "sqs-ffmpeg-event-source-mapping" {
  event_source_arn = aws_sqs_queue.egoistsqsqueue.arn
  function_name    = aws_lambda_function.egoist-sqs-ffmpeg.arn
}

# S3 Bucket

resource "aws_s3_bucket" "egoist-s3-bucket" {
  bucket = "egoist${var.env}s3"

  tags = {
    env = var.env
  }
}
