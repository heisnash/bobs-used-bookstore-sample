# AWS Transform Deployment Scripts for .NET Applications

## Overview

As part of the code transformation AWS Transform analyzed your source code repository to identify deployable .NET applications, including:

* ASP.NET MVC applications
* ASP.NET Web applications

### Deployable Applications Found

| Project name | Project file location | Deployment Scripts and templates location |
|--------------|----------------------|---------------------------|
| Bookstore.Web | `app/Bookstore.Web/Bookstore.Web.csproj` | `app/Bookstore.Web/aws-transform-deploy/`

AWS Transform provides deployment scripts and AWS CloudFormation templates to help you deploy your transformed .NET applications to Amazon EC2 instances or Amazon ECS service. This comprehensive deployment solution includes infrastructure provisioning, application deployment, and management tools that streamline the process of getting your applications running in the AWS cloud.

The generated deployment assets are placed in directory `{Project Directory}/aws-transform-deploy/` for each project in the table above.

## Deployment workflow

The deployment process follows these key steps:

1. Core Infrastructure Setup
   - Creates required IAM Roles and Instance Profiles for secure access.
   - Provisions S3 bucket for storing deployment artifacts.

2. Application Infrastructure 
   - Deploys application-specific infrastructure resources.
   - Configures networking.
   - Sets up monitoring and logging.

3. Application Deployment
   - Uploads application packages to S3 or ECR
   - Deploys applications using the provisioned infrastructure.
   - Validates deployment health.

## Core Infrastructure Setup

### Important: Administrator privileges are needed
To execute templates in this directory, you need admin-level permissions to create IAM roles. If you don't have these permissions, please forward contents of this directory to your AWS account administrator for review and implementation.

### Prerequisites
1. Admin-level permissions on your AWS account to manage IAM Roles, IAM Instance Profiles, and CloudFormation stacks.
2. AWS credentials properly configured via either:
   - Environment variables (e.g. `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
   - AWS credentials file (`~/.aws/credentials`)
   See https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-authentication.html for detailed setup instructions
3. **Review the CloudFormation template** `prerequisites/iam_roles.yml` before deployment.

### Create IAM Roles and S3 Bucket

. You only need to do this once per account. If you already did this during using AWS Transform webapp, you can skip this step. Use `prerequisites/iam_roles.yml` CloudFormation template to create deployment roles and s3 bucket:

1. `AWSTransform-Deploy-Manual-Deployment-Role`: a role used to deploy infrastructure. Has permissions to create CloudFormation stacks, EC2 instances, write to S3 bucket and execute SSM commands on a given instance
2. `AWSTransform-Deploy-App-Instance-Role`: a role used by EC2 instance to run deployed application
3. `AWSTransform-Deploy-ECS-Task-Role`: a role used by ECS tasks to access AWS services
4. `AWSTransform-Deploy-ECS-Execution-Role`: a role used by ECS service to pull container images from ECR and manage task lifecycle

### Deploy CloudFormation stack to create IAM roles and S3 bucket
#### Using the Bash Setup Script (setup.sh)

```shell
cd prerequisites
./setup.sh --stack-name AWSTransform-Deploy-IAM-Role-Stack
```

**Optional Parameters:**

* `--stack-name`: CloudFormation stack name (default: `AWSTransform-Deploy-IAM-Role-Stack`).

* `--disable-bucket-creation`: Whether to create an S3 bucket to store build artifacts (`true` or `false`, default: `false`).

---

#### Using the PowerShell Setup Script (setup.ps1)
```powershell
cd prerequisites
.\setup.ps1 -StackName AWSTransform-Deploy-IAM-Role-Stack
```

**Optional Parameters:**

* `-StackName`: CloudFormation stack name (default: `AWSTransform-Deploy-IAM-Role-Stack`).

* `-DisableBucketCreation`: Switch to prevent S3 bucket creation (default is to create the bucket).

---

## Assigning users to the roles

After the IAM roles are created, the administrator needs to edit the trust policy for the following roles
to specify which users/roles can assume them for infrastructure and application deployment:
1. AWSTransform-Deploy-Manual-Deployment-Role

### Example trust policy to allow specific IAM users/roles to assume the deployment role:
```
aws iam update-assume-role-policy --role-name <Role Name> --policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\": [\"arn:aws:iam::ACCOUNT_ID:user/USERNAME\", \"arn:aws:iam::ACCOUNT_ID:role/ROLENAME\"]},\"Action\":\"sts:AssumeRole\"}]}'
```

# Deploy your transformed applications

Refer to `README.md` file in `Deployment Scripts and templates location` for each individual application as in the table above.