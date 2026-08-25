#!/bin/bash

# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

set -e

# Constants
TEMPLATE_FILE_PATH=""
APP_INFRA_FILE="infrastructure.config"
GITIGNORE_PATH=".gitignore"

# Default values
DEFAULT_REGION="us-east-1"

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --deployment-type)
                DEPLOYMENT_TYPE="$2"
                shift 2
                ;;
            --stack-name)
                STACK_NAME="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --skip-assume-role)
                SKIP_ASSUME_ROLE=true
                shift
                ;;
            # ECS-specific parameters
            --target-name)
                TARGET_NAME="$2"
                shift 2
                ;;
            --vpc-id)
                VPC_ID="$2"
                shift 2
                ;;
            --public-subnet-ids)
                PUBLIC_SUBNET_IDS="$2"
                shift 2
                ;;
            --private-subnet-ids)
                PRIVATE_SUBNET_IDS="$2"
                shift 2
                ;;
            --alb-arn)
                ALB_ARN="$2"
                shift 2
                ;;
            --alb-security-group-id)
                ALB_SECURITY_GROUP_ID="$2"
                shift 2
                ;;
            --ecs-cluster-name)
                ECS_CLUSTER_NAME="$2"
                shift 2
                ;;
            --ecs-security-group-id)
                ECS_SECURITY_GROUP_ID="$2"
                shift 2
                ;;
            --certificate-arn)
                CERTIFICATE_ARN="$2"
                shift 2
                ;;
            --alb-listener-port)
                ALB_LISTENER_PORT="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Logging and display functions
write_log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local severity=$1
    local message=$2
    echo "[$timestamp] [$severity] $message"
}

show_usage() {
    write_log "INFO" "$(cat <<-EOF
Script Details:

This script can be used to deploy the Application Infrastructure CloudFormation (CFN) Stack.

Usage: ./deploy_infra.sh --deployment-type ecs [options]

Common Parameters:
    --deployment-type       : (Required) Type of deployment
    --stack-name            : (Required) Name for the CloudFormation stack
    --region                : (Optional) AWS region for deployment. Default: ${DEFAULT_REGION}
    --skip-assume-role      : (Optional) Skip assuming the deployment role

ECS Parameters:
    --target-name           : (Required) Name of the target (used for resource naming)
    --vpc-id                : (Optional) ID of the VPC for ECS deployment
    --public-subnet-ids     : (Optional) Comma-separated list of public subnet IDs
    --private-subnet-ids    : (Optional) Comma-separated list of private subnet IDs
    --alb-arn               : (Optional) ARN of existing Application Load Balancer
    --alb-security-group-id : (Optional) ID of existing ALB security group
    --ecs-cluster-name      : (Optional) Name of existing ECS cluster
    --ecs-security-group-id : (Optional) ID of existing ECS security group
    --certificate-arn       : (Optional) ARN of ACM certificate for HTTPS listener
    --alb-listener-port     : (Optional) Port for ALB listener. Default: 80 (HTTP) or 443 (HTTPS)

EOF
)"
}

initialize_parameters() {
    local missing_params=()

    if [ -z "$STACK_NAME" ]; then
        missing_params+=("$STACK_NAME")
    fi

    case $DEPLOYMENT_TYPE in
        "ecs")
            TEMPLATE_FILE_PATH="ecs_infra_template.yml"
            if [ -z "$TARGET_NAME" ]; then
                missing_params+=("TARGET_NAME")
            fi
            ;;
        *)
            write_log "ERROR" "Unsupported deployment type: $DEPLOYMENT_TYPE"
            write_log "ERROR" "Currently supported types: ecs"
            show_usage
            exit 1
            ;;
    esac
    
    if [ ${#missing_params[@]} -ne 0 ]; then
        write_log "ERROR" "Missing required parameters: ${missing_params[*]}"
        show_usage
        exit 1
    fi
    
    # Set region to default if not provided
    REGION=${REGION:-$DEFAULT_REGION}
}

assume_role() {
    local role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/${TARGET_NAME}-Deployment-Role"
    write_log "INFO" "Assuming role: $role_arn"
    
    local credentials=$(aws sts assume-role --role-arn "$role_arn" --role-session-name "DeploymentSession" --output json)
    
    if [ $? -ne 0 ]; then
        write_log "ERROR" "Failed to assume role. Please verify that:"
        write_log "ERROR" "1. The role 'AWSTransformDotNET-Infra-Deployment-Role' exists in your account"
        write_log "ERROR" "2. Your IAM user/role has permission to assume this role"
        write_log "ERROR" "3. The role trust policy allows your IAM user/role to assume it"
        exit 1
    fi

    export AWS_ACCESS_KEY_ID=$(echo "$credentials" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$credentials" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$credentials" | jq -r '.Credentials.SessionToken')
}

get_common_error_solution() {
    local error_message="$1"
    
    case "$error_message" in
        *"role cannot be assumed"*)
            echo "Check IAM role permissions and trust relationships"
            ;;
        *"VPC"*)
            echo "Verify VPC ID exists and is in the correct region"
            ;;
        *"ECS cluster"*)
            echo "Verify ECS cluster name is correct and the cluster exists"
            ;;
        *"certificate"*)
            echo "Ensure the ACM certificate ARN is valid and in the correct region"
            ;;
        *)
            echo "Review CloudFormation documentation and check AWS Console for more details"
            ;;
    esac
}

add_to_gitignore() {
    local file_to_ignore="$1"
    
    if [ -f "$GITIGNORE_PATH" ]; then
        if ! grep -q "^$file_to_ignore$" "$GITIGNORE_PATH"; then
            echo "$file_to_ignore" >> "$GITIGNORE_PATH"
        fi
    else
        echo "$file_to_ignore" > "$GITIGNORE_PATH"
    fi
}

deploy_stack() {

    write_log "INFO" "Deploying stack: $STACK_NAME"

    # Create parameters array
    local parameters=(
        "ParameterKey=TargetName,ParameterValue=$TARGET_NAME"
        "ParameterKey=VpcId,ParameterValue=${VPC_ID:-''}"
        "ParameterKey=PublicSubnetIds,ParameterValue='${PUBLIC_SUBNET_IDS:-''}'"
        "ParameterKey=PrivateSubnetIds,ParameterValue='${PRIVATE_SUBNET_IDS:-''}'"
        "ParameterKey=AlbArn,ParameterValue=${ALB_ARN:-''}"
        "ParameterKey=AlbSecurityGroupId,ParameterValue=${ALB_SECURITY_GROUP_ID:-''}"
        "ParameterKey=EcsClusterName,ParameterValue=${ECS_CLUSTER_NAME:-''}"
        "ParameterKey=EcsSecurityGroupId,ParameterValue=${ECS_SECURITY_GROUP_ID:-''}"
        "ParameterKey=CertificateArn,ParameterValue=${CERTIFICATE_ARN:-''}"
        "ParameterKey=AlbListenerPort,ParameterValue=${ALB_LISTENER_PORT:-0}"
    )

    # Update the stack if it exists
    if stack_info=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null); then

        echo "$stack_info"
        write_log "WARN" "There is already a stack with that name. See its definition above."

        read -r -p "Do you want to update the existing stack? (y/n) " REPLY
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            write_log "INFO" "Stack update cancelled by user."
            exit 0
        fi

        if aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body "file://$TEMPLATE_FILE_PATH" \
            --parameters "${parameters[@]}" \
            --capabilities CAPABILITY_IAM \
            --region "$REGION" \
            --tags Key=CreatedFor,Value=AWSTransform; then

            write_log "INFO" "Waiting for stack update to complete..."
            aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
            exit_code=$?
        else
            write_log "ERROR" "Failed to initiate stack update."
            exit 1
        fi

    # Create a new stack if it doesn't exist
    else
        if aws cloudformation create-stack \
            --stack-name "$STACK_NAME" \
            --template-body "file://$TEMPLATE_FILE_PATH" \
            --parameters "${parameters[@]}" \
            --capabilities CAPABILITY_IAM \
            --region "$REGION" \
            --tags Key=CreatedFor,Value=AWSTransform; then

            write_log "INFO" "Waiting for stack creation to complete..."
            aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
            exit_code=$?
        else
            write_log "ERROR" "Failed to initiate stack creation."
            exit 1
        fi
    fi

    if [ $exit_code -eq 0 ]; then
        write_log "SUCCESS" "Stack deployment completed successfully!"

        # Get and save stack outputs
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs' \
            --output json > "$APP_INFRA_FILE"

        write_log "INFO" "Wrote infrastructure details to $APP_INFRA_FILE"
        add_to_gitignore "$APP_INFRA_FILE"

        write_log "INFO" "Please refer to README.md and deploy.sh in order to deploy the application to this infrastructure."
    else
        write_log "ERROR" "Stack deployment failed"
        aws cloudformation describe-stack-events \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
            --output json | jq -r '.[] | "Failed resource: \(.LogicalResourceId)\nReason: \(.ResourceStatusReason)"' | \
        while IFS= read -r line; do
            write_log "ERROR" "$line"
        done
        exit 1
    fi
}

check_dependencies() {
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        write_log "ERROR" "AWS CLI is not installed. Please install it first."
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        write_log "ERROR" "jq is not installed. Please install it first."
        exit 1
    fi
}

main() {
    # AWS CLI and jq must be installed
    check_dependencies

    # Parse command line arguments
    parse_arguments "$@"

    # Validate arguments and set defaults
    initialize_parameters

    # Assume the Deployment IAM Role
    if [ "$SKIP_ASSUME_ROLE" != "true" ]; then
        assume_role
    fi

    # Deploy the stack
    deploy_stack
}

# Start script execution
main "$@"