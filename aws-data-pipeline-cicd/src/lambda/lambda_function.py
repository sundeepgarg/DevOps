import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS Glue client
glue_client = boto3.client('glue')

def lambda_handler(event, context):
    """
    Triggered by S3 ObjectCreated event. Starts the configured AWS Glue Job.
    """
    job_name = os.environ.get("GLUE_JOB_NAME")
    
    if not job_name:
        logger.error("GLUE_JOB_NAME environment variable is not set.")
        return {
            'statusCode': 500,
            'body': json.dumps('GLUE_JOB_NAME configuration missing.')
        }

    try:
        # Extract bucket and file info from the S3 event (optional logging)
        for record in event.get('Records', []):
            bucket_name = record['s3']['bucket']['name']
            object_key = record['s3']['object']['key']
            logger.info(f"New file detected: s3://{bucket_name}/{object_key}")

        logger.info(f"Starting AWS Glue Job: {job_name}")
        
        # Start the Glue job
        response = glue_client.start_job_run(JobName=job_name)
        job_run_id = response['JobRunId']
        
        logger.info(f"Successfully started Glue Job. RunId: {job_run_id}")
        
        return {
            'statusCode': 200,
            'body': json.dumps(f"Started Glue job {job_name} with RunId {job_run_id}")
        }
        
    except Exception as e:
        logger.error(f"Error starting Glue Job: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error starting Glue Job: {str(e)}")
        }
