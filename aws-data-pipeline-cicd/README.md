# AWS Data Pipeline CI/CD Project

This project demonstrates a fully automated data pipeline deployment on AWS using Terraform and GitHub Actions.

## Architecture Highlights
- **AWS S3 Buckets**: 
  - `Raw Data Bucket`: Where raw `.csv` files are ingested.
  - `Processed Data Bucket`: Where transformed data is saved (e.g., in `.parquet` format)
  - `Scripts Bucket`: Stores PySpark Python scripts for AWS Glue.
- **AWS Lambda**: Subscribes to S3 Event Notifications for the Raw Data bucket. Upon receiving a `.csv` file upload event, it triggers the ETL job.
- **AWS Glue (PySpark)**: Extracts data from the raw bucket, transforms it (example upper-casing logic), and loads it into the processed bucket.
- **CI/CD pipeline**: GitHub Actions manages the automated deployment of all Infrastructure and Source Code. 

## Requirements
- `terraform` v1.x+
- `aws-cli` configured
- AWS Access Keys with sufficient permissions

## How to Run Locally

If you need to test the Terraform configurations locally without the CI/CD pipeline, follow these steps:

1. **Initialize Terraform**
   ```bash
   cd terraform
   terraform init
   ```

2. **Validate Configurations**
   ```bash
   terraform validate
   ```

3. **Plan the Deployment**
   ```bash
   terraform plan
   ```

4. **Deploy to AWS**
   ```bash
   terraform apply -auto-approve
   ```

5. **Deploy the Glue Script Manually (Since GitHub Actions usually handles this)**
   *After apply, grab the `scripts_bucket_name` from Terraform outputs:*
   ```bash
   aws s3 cp ../src/glue/spark_etl.py s3://<YOUR_SCRIPTS_BUCKET_NAME_OUTPUT>/spark_etl.py
   ```

## Testing the Data Pipeline
1. In the AWS Console, upload a sample `.csv` file into the generated `raw` S3 bucket.
2. Check AWS Lambda metrics to see that the `s3:ObjectCreated` event successfully triggered the function.
3. Check AWS Glue Studio to see the ETL Job running.
4. Verify the transformed data appears in your `processed` S3 bucket as a `.parquet` file.

## Expected Interview Discussion Points
* **Why Terraform?** Reproducible, consistent infrastructure. Maintains state.
* **Why PySpark/Glue over just Lambda?** Data engineering at scale requires distributed computing networks like Spark. Lambda has a 15-minute timeframe limit and finite memory constraints; Glue operates on much larger datasets.
* **Security**: The IAM policies created follow the Principle of Least Privilege.
