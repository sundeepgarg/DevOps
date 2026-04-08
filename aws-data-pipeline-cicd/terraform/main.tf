provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------
# Random Pet for Unique Bucket Naming
# -------------------------------------------------------------
resource "random_pet" "bucket_suffix" {
  length    = 2
  separator = "-"
}

# -------------------------------------------------------------
# S3 Buckets
# -------------------------------------------------------------
resource "aws_s3_bucket" "raw_data" {
  bucket        = "${var.project_name}-raw-${var.environment}-${random_pet.bucket_suffix.id}"
  force_destroy = true
}

resource "aws_s3_bucket" "processed_data" {
  bucket        = "${var.project_name}-processed-${var.environment}-${random_pet.bucket_suffix.id}"
  force_destroy = true
}

resource "aws_s3_bucket" "scripts" {
  bucket        = "${var.project_name}-scripts-${var.environment}-${random_pet.bucket_suffix.id}"
  force_destroy = true
}

# -------------------------------------------------------------
# IAM Role for Glue
# -------------------------------------------------------------
resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_attachment" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_policy" {
  name = "${var.project_name}-glue-s3-policy"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.raw_data.arn}",
          "${aws_s3_bucket.raw_data.arn}/*",
          "${aws_s3_bucket.processed_data.arn}",
          "${aws_s3_bucket.processed_data.arn}/*",
          "${aws_s3_bucket.scripts.arn}",
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      }
    ]
  })
}

# -------------------------------------------------------------
# AWS Glue Job
# -------------------------------------------------------------
resource "aws_glue_job" "spark_etl_job" {
  name     = "${var.project_name}-etl-job"
  role_arn = aws_iam_role.glue_role.arn

  command {
    script_location = "s3://${aws_s3_bucket.scripts.bucket}/spark_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"        = "python"
    "--job-bookmark-option" = "job-bookmark-disable"
    "--RAW_BUCKET_NAME"     = aws_s3_bucket.raw_data.bucket
    "--PROCESSED_BUCKET_NAME" = aws_s3_bucket.processed_data.bucket
  }

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  max_retries       = 0
  timeout           = 15
}

# -------------------------------------------------------------
# IAM Role for Lambda
# -------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-trigger-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_glue_policy" {
  name = "${var.project_name}-lambda-glue-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartJobRun"
        ]
        Resource = [aws_glue_job.spark_etl_job.arn]
      }
    ]
  })
}

# -------------------------------------------------------------
# Lambda Function Configuration
# -------------------------------------------------------------
# Zipping the Lambda Function for deployment
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda"
  output_path = "${path.module}/../lambdas.zip"
}

resource "aws_lambda_function" "trigger_glue" {
  function_name    = "${var.project_name}-trigger-glue"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.10"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = 10
  memory_size = 128

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.spark_etl_job.name
    }
  }
}

# -------------------------------------------------------------
# S3 Event Trigger for Lambda (When file uploaded to raw_data bucket)
# -------------------------------------------------------------
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_glue.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_data.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.raw_data.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger_glue.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}
