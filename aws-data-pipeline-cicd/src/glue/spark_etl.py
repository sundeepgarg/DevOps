import sys
import os
import boto3
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

# Get arguments passed from Terraform/Lambda
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'RAW_BUCKET_NAME',
    'PROCESSED_BUCKET_NAME'
])

raw_bucket = args['RAW_BUCKET_NAME']
processed_bucket = args['PROCESSED_BUCKET_NAME']

# Initialize context and job
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f"Starting ETL Job: Processing data from s3://{raw_bucket} to s3://{processed_bucket}")

# 1. Read input data from raw bucket
# Assuming CSV files are uploaded to the root of the raw bucket
try:
    df_raw = spark.read.option("header", "true") \
                       .option("inferSchema", "true") \
                       .csv(f"s3://{raw_bucket}/*.csv")
    
    print(f"Successfully read data from raw bucket with {df_raw.count()} records.")
except Exception as e:
    print(f"Error reading from raw bucket or no data found: {e}")
    job.commit()
    sys.exit(0)

# 2. Perform Transformations
# In a real scenario, you would clean and transform data here.
# For demo purposes, we will convert column names to uppercase and add a processing timestamp.
from pyspark.sql.functions import current_timestamp

df_transformed = df_raw.select([col.alias(col.upper()) for col in df_raw.columns]) \
                       .withColumn("PROCESSED_AT", current_timestamp())

print("Transformations completed successfully.")

# 3. Write data to processed bucket in Parquet format
output_path = f"s3://{processed_bucket}/reports/"

df_transformed.write \
              .mode("append") \
              .parquet(output_path)

print(f"Data successfully written to {output_path}")

job.commit()
