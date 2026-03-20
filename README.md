# S3 CSV Lambda CI/CD

This project deploys a Python Lambda function that is triggered by S3 object creation events and reads uploaded CSV files with `pandas`.

It supports two deployment targets:

- `dev` branch -> deploys to the development Lambda and uses development AWS settings
- `main` branch -> deploys to the production Lambda and uses production AWS settings

## Project Layout

```text
Showcase-Projects/s3-csv-lambda-cicd/
├── buildspec.yml
├── README.md
├── requirements.txt
├── scripts/
│   └── deploy_lambda.sh
├── sample-data/
│   └── orders.csv
└── src/
    └── lambda_function.py
```

## How It Works

1. A CSV file is uploaded to an S3 bucket.
2. S3 sends an `ObjectCreated` event to Lambda.
3. Lambda downloads the file from S3 using `boto3`.
4. Lambda reads the file with `pandas.read_csv`.
5. Lambda logs file metadata, column names, row count, and a small preview of the records.

## Branch Deployment Rules

- Push to `dev` -> CodeBuild deploys the `dev` Lambda
- Push to `main` -> CodeBuild deploys the `prod` Lambda

Typical flow:

1. Work in `dev`
2. Push changes to `dev`
3. Verify the `dev` deployment
4. Open a pull request from `dev` to `main`
5. Merge the pull request
6. Verify the `prod` deployment

## What You Create Manually

Create the following items manually in AWS Console:

1. The `dev` S3 bucket
2. The `prod` S3 bucket
3. The CodeBuild project
4. The GitHub connection for the repository
5. The CodeBuild webhook filters for `dev` and `main`
6. The S3 trigger on the `dev` Lambda after the first deployment
7. The S3 trigger on the `prod` Lambda after the first deployment

## What CodeBuild Creates or Updates Automatically

When a qualifying push happens, CodeBuild and the deployment script handle the following automatically:

1. Packages the Lambda source code with dependencies
2. Creates the target Lambda function if it does not already exist
3. Updates the target Lambda function if it already exists
4. Creates the target Lambda execution role if it does not already exist
5. Attaches the basic Lambda execution managed policy to that role
6. Adds or updates an inline IAM policy that allows the Lambda to read from the correct S3 bucket
7. Updates Lambda configuration such as runtime, handler, timeout, and memory

## AWS Console Setup

### 1. Create the S3 buckets

Create one bucket for development and one bucket for production.

Example:

```bash
aws s3 mb s3://your-dev-csv-source-bucket --region ap-south-1
aws s3 mb s3://your-prod-csv-source-bucket --region ap-south-1
```

### 2. Create the CodeBuild service role

Create a service role for CodeBuild.

If you want the quickest path to a working deployment, you can temporarily attach `AdministratorAccess` to the CodeBuild role. If you want to scope it down later, the role will need access to:

- Lambda create and update actions
- IAM role create, read, update, and `iam:PassRole`
- S3 access for the source buckets
- CloudWatch Logs access

### 3. Create the CodeBuild project

In AWS Console:

1. Open `CodeBuild`
2. Click `Create build project`
3. Set the source provider to `GitHub`
4. Connect the repository
5. Use the repository that contains this project
6. Choose a managed image
7. Use the standard runtime
8. Select the CodeBuild service role created earlier
9. Choose `Use a buildspec file`
10. Leave artifacts as `No artifacts`

### 4. Add CodeBuild environment variables

Add these environment variables in the CodeBuild project.

These variables are required because the deployment script reads them dynamically based on the branch that triggered the build.

Development:

- `DEV_S3_SOURCE_BUCKET`
- `DEV_FUNCTION_NAME`
- `DEV_IAM_ROLE_NAME`
- `DEV_AWS_REGION`

Production:

- `PROD_S3_SOURCE_BUCKET`
- `PROD_FUNCTION_NAME`
- `PROD_IAM_ROLE_NAME`
- `PROD_AWS_REGION`

Example values:

```text
DEV_S3_SOURCE_BUCKET=your-dev-csv-source-bucket
DEV_FUNCTION_NAME=s3-csv-reader-dev
DEV_IAM_ROLE_NAME=s3-csv-reader-dev-role
DEV_AWS_REGION=ap-south-1

PROD_S3_SOURCE_BUCKET=your-prod-csv-source-bucket
PROD_FUNCTION_NAME=s3-csv-reader-prod
PROD_IAM_ROLE_NAME=s3-csv-reader-prod-role
PROD_AWS_REGION=ap-south-1
```

### 5. Configure the webhook

In the same CodeBuild project:

1. Open `Edit`
2. Open the `Webhook` section
3. Enable webhook
4. Set the event type to `Push`
5. Add a `HEAD_REF` filter with this pattern:

```text
^refs/heads/(dev|main)$
```

This ensures:

- pushes to `dev` trigger development deployment
- pushes to `main` trigger production deployment

## Lambda Trigger Setup

The deployment script creates the Lambda function, but it does not create the S3 trigger. Add that manually after each environment has been deployed once.

For `dev`:

1. Open the Lambda function named in `DEV_FUNCTION_NAME`
2. Click `Add trigger`
3. Choose `S3`
4. Select the bucket in `DEV_S3_SOURCE_BUCKET`
5. Choose `All object create events`
6. Optionally add a suffix filter of `.csv`
7. Save

For `prod`:

1. Open the Lambda function named in `PROD_FUNCTION_NAME`
2. Click `Add trigger`
3. Choose `S3`
4. Select the bucket in `PROD_S3_SOURCE_BUCKET`
5. Choose `All object create events`
6. Optionally add a suffix filter of `.csv`
7. Save

## What the Build Does

The build runs [buildspec.yml](/Users/shashankmishra/Desktop/AWS_Services_Mastery_Bootcamp/Showcase-Projects/s3-csv-lambda-cicd/buildspec.yml), which calls [deploy_lambda.sh](/Users/shashankmishra/Desktop/AWS_Services_Mastery_Bootcamp/Showcase-Projects/s3-csv-lambda-cicd/scripts/deploy_lambda.sh).

The deployment script:

1. Detects whether the current branch is `dev` or `main`
2. Resolves the correct environment variables for that branch
3. Installs `pandas` into the deployment package
4. Creates `deployment_package.zip`
5. Creates or updates the IAM role
6. Creates or updates the Lambda function

## Test the Deployment

After the first `dev` deployment:

1. Upload [orders.csv](/Users/shashankmishra/Desktop/AWS_Services_Mastery_Bootcamp/Showcase-Projects/s3-csv-lambda-cicd/sample-data/orders.csv) to the `dev` bucket
2. Open CloudWatch Logs for the `dev` Lambda
3. Confirm that the logs show the CSV columns, row count, and preview rows

Example:

```bash
aws s3 cp sample-data/orders.csv s3://your-dev-csv-source-bucket/orders.csv
```

After the first `main` deployment:

1. Upload the same file to the `prod` bucket
2. Open CloudWatch Logs for the `prod` Lambda
3. Confirm the same output pattern

## Notes

- This setup uses one CodeBuild project for both environments.
- The branch name decides which environment variables are used.
- If a branch other than `dev` or `main` triggers the build, the deployment script exits without deploying.
- The sample CSV file in [orders.csv](/Users/shashankmishra/Desktop/AWS_Services_Mastery_Bootcamp/Showcase-Projects/s3-csv-lambda-cicd/sample-data/orders.csv) is only for testing the trigger and log output.
