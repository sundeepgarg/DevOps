output "raw_bucket_name" {
  description = "The name of the S3 bucket for raw data"
  value       = aws_s3_bucket.raw_data.id
}

output "processed_bucket_name" {
  description = "The name of the S3 bucket for processed data"
  value       = aws_s3_bucket.processed_data.id
}

output "scripts_bucket_name" {
  description = "The name of the S3 bucket for Glue scripts"
  value       = aws_s3_bucket.scripts.id
}

output "glue_job_name" {
  description = "The name of the Glue job"
  value       = aws_glue_job.spark_etl_job.name
}

output "lambda_function_name" {
  description = "The name of the Lambda function"
  value       = aws_lambda_function.trigger_glue.function_name
}
