#!/bin/bash

# setup.sh
#
# Parameters:
#   --stack-name <name>                     CloudFormation stack name override. Default: AWSTransform-Deploy-IAM-Role-Stack
#   --disable-bucket-creation <true|false>  Whether to create the S3 bucket required for AWS Transform to store build artifacts in deployment. Default: false
#
# Usage:
#   ./setup.sh --stack-name MyStack --disable-bucket-creation false
#

set -e

TEMPLATE_FILE="iam_roles.yml"

STACK_NAME="AWSTransform-Deploy-IAM-Role-Stack"
DISABLE_BUCKET_CREATION="false"

log() {
  local message="$1"
  local severity="${2:-INFO}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$severity] $message"
}

prefix_output() {
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      log "$line" "AWS CLI"
    fi
  done
}

usage() {
  log "Usage: $0 [--stack-name <STACK_NAME>] [--disable-bucket-creation <true|false>] [--help|-h]"
  exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --disable-bucket-creation)
      DISABLE_BUCKET_CREATION="$2"
      if [[ "$DISABLE_BUCKET_CREATION" != "true" && "$DISABLE_BUCKET_CREATION" != "false" ]]; then
        log "--disable-bucket-creation must be 'true' or 'false'" "ERROR"
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
    	log "Unknown option: $1" "ERROR"
      usage
      ;;
  esac
done

if ! command -v aws &> /dev/null; then
  log "AWS CLI is not installed or not in PATH. Please install it first." "ERROR"
  exit 1
fi

CREATE_S3_BUCKET=$([ "$DISABLE_BUCKET_CREATION" = "false" ] && echo "true" || echo "false")

log "Stack Name: $STACK_NAME"
log "Bucket Creation: $CREATE_S3_BUCKET"

if [[ "$CREATE_S3_BUCKET" != "true" ]]; then
  log "Bucket creation is disabled. The S3 bucket is required for AWS Transform to deploy applications." "WARN"
fi

echo
log "=== Checking ECS Service-Linked Role ==="

set +e
CREATE_OUTPUT=$(aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>&1)
CREATE_EXIT_CODE=$?
set -e

if [[ $CREATE_EXIT_CODE -ne 0 ]]; then
  if echo "$CREATE_OUTPUT" | grep -q "Service role name .* has been taken"; then
    log "ECS service-linked role already exists."
  else
    log "Failed to create service-linked role:" "ERROR"
    echo "$CREATE_OUTPUT" | prefix_output
    exit 1
  fi
else
  log "Service-linked role created successfully."
fi

echo
log "=== Deploying CloudFormation Stack ==="

PARAM_OVERRIDES="CreateS3Bucket=$CREATE_S3_BUCKET"

aws cloudformation deploy \
  --template-file "$TEMPLATE_FILE" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides $PARAM_OVERRIDES \
  --tags CreatedFor=AWSTransform | prefix_output

echo
log "=== Deployment Complete ==="

log "Next steps:"
log "- Return to the AWS Transform website and select 'Continue' to configure application infrastructure if not done yet."
log "- Once infrastructure is configured, deploy your application by selecting the 'Deploy' button in the AWS Transform website."
log "- Alternatively, consult the README located in the 'aws-transform-deploy' folder of your project’s parent directory if"
log "  you prefer self-managed deployment or no further configuration is needed."
log "- Optionally, review and update IAM role permissions if your application requires further customization."