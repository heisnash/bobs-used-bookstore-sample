Deploy your Bookstore.Web to AWS ECS (Elastic Container Service).

# Provision Infrastructure

## Overview
Use the provided scripts or CloudFormation templates to provision and manage your own ECS infrastructure and deploy containerized applications to this infrastructure.

The process consists of the following steps:

1. Use `deploy_infra.ps1` (or `ecs_infra_template.yml` directly) to provision ECS cluster.
2. Use `deploy.ps1` to deploy your containerized application to the ECS cluster.

## Prerequisites
1. You or your account administrator have run `setup.sh` located in `aws-transform-deploy/prerequisites` directory at the root of this repository to create necessary IAM roles and S3 bucket.
2. You can assume the role `AWSTransform-Deploy-Manual-Deployment-Role` created by the setup script.
3. You have your AWS credentials configured either via environment variables or credential files (see https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-authentication.html for details).
4. Review the CloudFormation template (`ecs_infra_template.yml`).
5. Review the infrastructure deployment script (`deploy_infra.ps1`).
6. Your application is containerized and the container image is available in a container registry (ECR, Docker Hub, etc.).

## Default values

When using the AWS Transform Web UI to provide infrastructure parameter values, the templates are automatically populated with these defaults.

However, you can override any defaults by:

1. modifying parameters in the CloudFormation template directly
2. providing override values as parameters to the scripts

## Provision infrastructure using deploy_infra.ps1

This script uses the provided template to automate the infrastructure provisioning, check for the errors and provide suggestions for deployment failures.

Run this script:
```
powershell ./deploy_infra.ps1 -EcsClusterName my-ecs-cluster -DeploymentType ECS
```

The script:
1. assumes **AWSTransform-Deploy-Manual-Deployment-Role**
2. creates CloudFormation stack for ECS cluster
3. prints the created ECS cluster name in the output
4. **saves the cluster name** to `infrastructure.config` file for use by the application deployment script
5. analyzes CloudFormation events and provides suggestions how to address common problems

After the script successfully finishes, the ECS cluster is created and you are ready for the next step.

Run `deploy_infra.ps1` without parameters to see other usage options.

### Using a different IAM Role
The script assumes the **AWSTransform-Deploy-Manual-Deployment-Role** by default for proper permissions (use `-SkipAssumeRole` to skip this).

If using a different role than the default `AWSTransform-Deploy-Manual-Deployment-Role` you need to:

1. Obtain temporary credentials for that role using AWS STS AssumeRole.
```
$credentials = Use-STSRole -RoleArn "arn:aws:iam::<account>:role/<role-name>" -RoleSessionName "TransformDeployment"
```

2. Configure AWS credentials environment variables with the temporary credentials.
```
$env:AWS_ACCESS_KEY_ID = $credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $credentials.SecretAccessKey 
$env:AWS_SESSION_TOKEN = $credentials.SessionToken
```

3. Run the deployment scripts with `-SkipAssumeRole` parameter since credentials are already configured.

```
./deploy_infra.ps1 -DeploymentType ECS -EcsClusterName my-ecs-cluster -SkipAssumeRole
```

## Provision infrastructure using ecs_infra_template.yml

This is the template used by the script above to deploy CloudFormation stack for ECS cluster.

If you want to use CloudFormation directly, use this template by either providing the parameters at the template deployment time, or by editing the template and adding default values to the parameters.

Example for AWS CLI
```
aws cloudformation deploy --template-file ecs_infra_template.yml --stack-name mystack --parameter '[{"ParameterKey":"ECSClusterName", "ParameterValue": "MyCluster"}, {"ParameterKey":"KmsKeyId", "ParameterValue": "alias/aws/ecs"}, ...]'
```

# Deploy the Bookstore.Web

## Overview
Deploy your containerized application to an ECS cluster using the provided deployment script. The script creates ECS task definitions, services, and manages the deployment lifecycle.

## Build and containerize your application

### Build your application for containers using .NET SDK or VS2022

Checkout the transform branch and make edits if needed.

### VS2022

Use .NET's built-in container publishing capabilities:

1. Ensure your project has container support enabled in the .csproj file:
   ```xml
   <PropertyGroup>
     <EnableSdkContainerSupport>true</EnableSdkContainerSupport>
   </PropertyGroup>
   ```

2. Set ECR credentials and build the container:
   ```bash
   export SDK_CONTAINER_REGISTRY_PWORD=$(aws ecr get-login-password --region <region>)
   export SDK_CONTAINER_REGISTRY_UNAME=AWS
   dotnet publish --os linux --arch x64 -c Release --self-contained true /t:PublishContainer /p:ContainerRegistry=<account-id>.dkr.ecr.<region>.amazonaws.com /p:ContainerImageTags="latest" /p:ContainerRepository=<your-app-name>
   ```

### .NET SDK

First, publish your application for Linux:
```bash
dotnet publish -c Release -r linux-x64 --self-contained true -o ./publish
```

Then build and publish the container using .NET's container publishing:
```bash
# Set ECR credentials
export SDK_CONTAINER_REGISTRY_PWORD=$(aws ecr get-login-password --region <region>)
export SDK_CONTAINER_REGISTRY_UNAME=AWS

# Build and publish container
dotnet publish --os linux --arch x64 -c Release --self-contained true /t:PublishContainer /p:ContainerRegistry=<account-id>.dkr.ecr.<region>.amazonaws.com /p:ContainerImageTags="latest" /p:ContainerRepository=<your-app-name>
```

## Deploy to ECS cluster

Run the provided script `deploy.ps1` to deploy the application.

```
powershell ./deploy.ps1 -DeploymentType ECS -ContainerImageUri <your-image-uri>
```

The script automatically:
1. **reads ECS cluster name** from the file created by deploy_infra.ps1 if not provided as parameter
2. **assumes the AWSTransform-Deploy-Manual-Deployment-Role** by default for deployment permissions
3. creates ECS task definition with your container image
4. creates or updates ECS service to run your application
5. configures CloudWatch logging for your application

Follow the prompts and instructions from the script.

Run `deploy.ps1` without parameters to see other usage options.

### Using a different IAM Role
The script assumes the **AWSTransform-Deploy-Manual-Deployment-Role** by default for proper permissions.

If using a different role, you need to:

1. Obtain temporary credentials for that role using AWS STS AssumeRole.
```
$credentials = Use-STSRole -RoleArn "arn:aws:iam::<account>:role/<role-name>" -RoleSessionName "TransformDeployment"
```

2. Configure AWS credentials environment variables with the temporary credentials.
```
$env:AWS_ACCESS_KEY_ID = $credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $credentials.SecretAccessKey 
$env:AWS_SESSION_TOKEN = $credentials.SessionToken
```

3. Run the `deploy.ps1` with -SkipAssumeRole parameter since credentials are already configured.

```
powershell ./deploy.ps1 -DeploymentType ECS -ContainerImageUri <your-image-uri> -SkipAssumeRole
```

### Environment Variables Configuration

You can specify environment variables for your container using the `-EnvironmentVariables` parameter in JSON format:

```
powershell ./deploy.ps1 -DeploymentType ECS -ContainerImageUri <your-image-uri> -EnvironmentVariables '{"ASPNETCORE_ENVIRONMENT":"Production","ConnectionStrings__DefaultConnection":"Server=mydb.example.com;Database=myapp;User Id=admin;Password=secret","ApiKey":"1234567890"}'
```

The deployment script will automatically:
- Configure the environment variables in the ECS task definition
- Ensure the variables are available to your application at runtime

## Debug your application

### Getting Application Logs

ECS applications automatically log to CloudWatch Logs. You can view logs in the AWS Console:

1. Navigate to CloudWatch > Log groups
2. Find the log group named `/aws/ecs/AWSTransform-<ApplicationName>-Logs`
3. View the log streams for your running tasks

You can also use AWS CLI to fetch logs:
```bash
aws logs describe-log-streams --log-group-name /aws/ecs/AWSTransform-<ApplicationName>-Logs
aws logs get-log-events --log-group-name /aws/ecs/AWSTransform-<ApplicationName>-Logs --log-stream-name <stream-name>
```

### Accessing running containers

For debugging purposes, you can use ECS Exec to access running containers:

1. Ensure your task definition has `enableExecuteCommand` set to true
2. Use AWS CLI to execute commands in the container:
   ```bash
   aws ecs execute-command --cluster <cluster-name> --task <task-arn> --container <container-name> --interactive --command "/bin/bash"
   ```

## Common problems

### Container Health Checks
Ensure your application responds to health check requests. By default, ECS will perform health checks on the configured container port.

Add a health check endpoint to your application:
```csharp
app.MapGet("/health", () => "Healthy");
```

### Port Configuration
Make sure your application listens on the correct port specified in the container port configuration.

For ASP.NET Core applications, configure Kestrel to listen on all interfaces:
```json
{
  "Kestrel": {
    "Endpoints": {
      "Http": {
        "Url": "http://0.0.0.0:80"
      }
    }
  }
}
```

Or set via environment variables:
```
ASPNETCORE_URLS=http://0.0.0.0:80
```

### Resource Limits
Ensure your container has sufficient CPU and memory allocated. Monitor CloudWatch metrics for CPU and memory utilization.

### Network Configuration
Verify that security groups allow traffic on the container port and that subnets have proper routing configured.

After making changes to your application, rebuild the container image, push to your registry, and run `deploy.ps1` again to deploy the updated version.