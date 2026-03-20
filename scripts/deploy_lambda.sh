#!/bin/bash

set -euo pipefail

# Resolve all project paths once so the script can be run from any directory.
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$APP_ROOT/build"
PACKAGE_DIR="$BUILD_DIR/package"
ZIP_FILE="$APP_ROOT/deployment_package.zip"
ROLE_POLICY_NAME="s3-read-access"
TRUST_POLICY_FILE="$BUILD_DIR/trust-policy.json"
INLINE_POLICY_FILE="$BUILD_DIR/s3-access-policy.json"

# These values are shared by both environments.
LAMBDA_HANDLER="${LAMBDA_HANDLER:-lambda_function.lambda_handler}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.12}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-60}"
LAMBDA_MEMORY="${LAMBDA_MEMORY:-512}"

# CodeBuild provides the source branch via CODEBUILD_WEBHOOK_HEAD_REF.
# The branch decides whether we deploy the dev or prod Lambda.
BRANCH_REF="${CODEBUILD_WEBHOOK_HEAD_REF:-}"
DEPLOY_ENV="${DEPLOY_ENV:-}"

if [[ -z "$DEPLOY_ENV" ]]; then
  case "$BRANCH_REF" in
    refs/heads/dev)
      DEPLOY_ENV="DEV"
      ;;
    refs/heads/main)
      DEPLOY_ENV="PROD"
      ;;
    *)
      echo "Unsupported branch ref: ${BRANCH_REF:-unknown}. Only dev and main are supported."
      exit 1
      ;;
  esac
fi

# Look up environment-specific variables such as DEV_FUNCTION_NAME or
# PROD_FUNCTION_NAME using the resolved DEPLOY_ENV prefix.
S3_SOURCE_BUCKET_VAR="${DEPLOY_ENV}_S3_SOURCE_BUCKET"
FUNCTION_NAME_VAR="${DEPLOY_ENV}_FUNCTION_NAME"
IAM_ROLE_NAME_VAR="${DEPLOY_ENV}_IAM_ROLE_NAME"
AWS_REGION_VAR="${DEPLOY_ENV}_AWS_REGION"

S3_SOURCE_BUCKET="${!S3_SOURCE_BUCKET_VAR:-}"
FUNCTION_NAME="${!FUNCTION_NAME_VAR:-}"
IAM_ROLE_NAME="${!IAM_ROLE_NAME_VAR:-}"
AWS_REGION="${!AWS_REGION_VAR:-}"

if [[ -z "$S3_SOURCE_BUCKET" || -z "$FUNCTION_NAME" || -z "$IAM_ROLE_NAME" || -z "$AWS_REGION" ]]; then
  echo "Missing environment configuration for $DEPLOY_ENV"
  echo "Required variables: $S3_SOURCE_BUCKET_VAR, $FUNCTION_NAME_VAR, $IAM_ROLE_NAME_VAR, $AWS_REGION_VAR"
  exit 1
fi

echo "Resolved deployment environment: $DEPLOY_ENV"
echo "Target Lambda function: $FUNCTION_NAME"
echo "Target IAM role: $IAM_ROLE_NAME"
echo "Target S3 bucket permission: $S3_SOURCE_BUCKET"
echo "Target AWS region: $AWS_REGION"

echo "Preparing deployment package for $FUNCTION_NAME"
rm -rf "$BUILD_DIR" "$ZIP_FILE"
mkdir -p "$PACKAGE_DIR"

# Install pandas and any future dependencies into the Lambda package directory.
pip install --upgrade pip
pip install --target "$PACKAGE_DIR" -r "$APP_ROOT/requirements.txt"
cp "$APP_ROOT/src/lambda_function.py" "$PACKAGE_DIR/"

(
  cd "$PACKAGE_DIR"
  zip -rq "$ZIP_FILE" .
)

# Trust policy: allows AWS Lambda to assume the execution role.
cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Inline policy: allows the Lambda to read objects from the environment bucket.
cat > "$INLINE_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_SOURCE_BUCKET}/*"
      ]
    }
  ]
}
EOF

# Reuse the role if it already exists; otherwise create it and attach the
# standard CloudWatch logging policy used by Lambda execution roles.
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role $IAM_ROLE_NAME already exists"
else
  echo "Creating IAM role $IAM_ROLE_NAME"
  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY_FILE" >/dev/null

  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
fi

aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "$ROLE_POLICY_NAME" \
  --policy-document "file://$INLINE_POLICY_FILE" >/dev/null

ROLE_ARN="$(aws iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.Arn' --output text)"

# IAM changes are not always visible immediately, so wait briefly before
# creating or updating the Lambda function with the role ARN.
echo "Waiting briefly for IAM role propagation"
sleep 10

# Update the function if it exists; otherwise create it from scratch.
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Updating existing Lambda function $FUNCTION_NAME"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_FILE" \
    --region "$AWS_REGION" >/dev/null

  # Lambda blocks configuration changes while a code update is still being
  # applied, so wait until the previous update finishes before continuing.
  echo "Waiting for code update to complete before updating configuration"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER" \
    --runtime "$LAMBDA_RUNTIME" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for configuration update to complete"
  aws lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION"
else
  echo "Creating Lambda function $FUNCTION_NAME"
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$LAMBDA_HANDLER" \
    --zip-file "fileb://$ZIP_FILE" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "Variables={MAX_PREVIEW_ROWS=5}" \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for new Lambda function to become active"
  aws lambda wait function-active-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION"
fi

echo "Deployment completed for Lambda function $FUNCTION_NAME"
