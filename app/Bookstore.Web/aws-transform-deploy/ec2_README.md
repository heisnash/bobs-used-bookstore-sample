# AWS Transform Deployment Scripts for Bookstore.Web

This tool helps you deploy your Bookstore.Web to AWS EC2 instances.

# Provision Infrastructure

## Overview
Use the provided scripts or CloudFormation templates to provision and manage your own EC2 infrastructure and deploy application to this infrastructure.

The process consists of the following steps:

1. Use `deploy_infra.ps1` (or `iac_template.yml` directly) to provision EC2 instance in a VPC of your choice.
2. Use `deploy.ps1` to transfer application files to EC2 instance and start the application.


## Prerequisites
1. You or your account administrator have run `setup.sh` located in `aws-transform-deploy/prerequisites` directory at the root of this repository to create necessary IAM roles and S3 bucket.
2. You can assume the role `AWSTransform-Deploy-Manual-Deployment-Role` created by the setup script.
3. You have your AWS credentials configured either via environment variables or credential files (see https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-authentication.html for details).
4. Review the CloudFormation template (`ec2_infra_template.yml`). 
5. Review the infrastructure deployment script (`deploy_infra.ps1`). 


## Default values

When using the AWS Transform Web UI to provide infrastructure parameter values, the templates are automatically populated with these defaults. 

However, you can override any defaults by:

1. modifying parameters in the CloudFormation template directly
2. providing override values as parameters to the scripts


## Provision infrastructure using deploy_infra.ps1 

This script uses the provided template to automate the infrastructure provisioning, check for the errors and provide suggestions for deployment failures.

Run this script: 
```
powershell ./deploy_infra.ps1 -SubnetId subnet-123456789 -SecurityGroupIds sg-123456789 -DeploymentType EC2
```

The script:
1. assumes **AWSTransform-Deploy-Manual-Deployment-Role** 
2. creates CloudFormation stack for EC2 instance
3. prints the created EC2 instance ID in the output
4. **saves the instance ID** to `infrastructure.config` file for use by the application deployment script
5. analyzes CloudFormation events and provides suggestions how to address common problems

After the script successfully finishes, the EC2 instance is created and you are ready for the next step.

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
./deploy_infra.ps1 -DeploymentType EC2 -SubnetId subnet-123456789 -SkipAssumeRole
```



## Provision infrastructure using iac_template.yml

This is the template used by the script above to deploy CloudFormation stack for EC2 instance.

If you want to use CloudFormation directly, use this template by either providing the parameters at the template deployment time, or by editing the template and adding default values to the parameters.

Example for AWS CLI
```
aws cloudformation deploy --template-file iac_template.yml --stack-name mystack --parameter '[{"ParameterKey":"ApplicationName", "ParameterValue": "MyApp"}, {"ParameterKey":"EC2InstanceProfile", "ParameterValue": "MyInstanceRole"}, ...]'
```

# Deploy the Bookstore.Web

## Overview
Deploy your application to an EC2 instance using the provided deployment script. The script sets up systemd service for your application, copies application binary to the EC2 instance and runs it.

## Build your application for Linux using .NET SDK or VS2022

Checkout the transform branch and make edits if needed.

### VS2022

There are two ways to build Linux binaries in VS2022:
* Simply select "Linux" as the target platform in your project settings.
* Use the <RuntimeIdentifier> property in your .csproj file (e.g., linux-x64).

Build and publish, note the publish directory.

### .NET SDK

Run the following commands at solution root to build application artifacts:

```bash
dotnet build "<Project File Location>"
dotnet publish "<Project File Location>" -c Release -r linux-x64 -o ./publish
```

## Deploy to EC2 instance

Run the provided script `deploy.ps1` to deploy the application.

```
powershell ./deploy.ps1 -publishDirectory ./publish -DeploymentType EC2 
```

The script automatically:
1. **reads EC2 instance ID** from the file created by deploy_infra.ps1 if not provided as parameter
2. **assumes the AWSTransform-Deploy-Manual-Deployment-Role** by default for deployment permissions
3. **uses the S3 bucket** specified in SSM parameter /transform/bucket-name if S3Bucket not provided
4. transfers application binaries to EC2 instance
5. configures and starts systemd service for the application on the instance

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

3. Run the `deploy.ps1`  with -SkipAssumeRole parameter since credentials are already configured.

```
powershell ./deploy.ps1 -publishDirectory ./publish -DeploymentType EC2 -SkipAssumeRole
```


### Environment Variables Configuration

Create aws-transform-deploy.env file in your publish directory to specify environment variables
that will be transferred to the EC2 instance and set for your application.

Format: name=value, one per line

Example aws-transform-deploy.env:
```
ASPNETCORE_ENVIRONMENT=Production
ConnectionStrings__DefaultConnection=Server=mydb.example.com;Database=myapp;User Id=admin;Password=secret
ApiKey=1234567890
CustomSetting=Value
```

The deployment script will automatically:
- Copy this file to the EC2 instance along with your application
- Set the environment variables for your application's systemd service
- Ensure the variables are available to your application at runtime

## Debug your application

### Getting Application Logs

Use the provided `get_logs.ps1` script to retrieve stdout, stderr and service status from your deployed application.

You can fetch any log by specifying parameter `-LogFile`.

### Logging in to the instance
By default, ssh to the instance is not enabled for security reasons. You can configure ssh separately if you need one (e.g. for remote debugging from IDE).

To access log files for the application, open Web Browser, AWS Console, EC2, find the instance id, click "Connect" and chose "Session Manager". This will open a secure terminal in a Web Browser.
   
See output of `deploy.ps1` to find the application location, logs location.

## Common problems

Important: Configure Kestrel Endpoints.
By default, Kestrel web server in ASP.NET Core applications listens only on localhost (127.0.0.1).
This means the application won't accept connections from outside the EC2 instance.

To allow external access, add the following to your appsettings.json:
```
{
  "Kestrel": {
    "Endpoints": {
      "Http": {
        "Url": "http://0.0.0.0:5000"
      }
    }
  }
}
```
Or set via environment variables in aws-transform-deploy.env:
```
ASPNETCORE_URLS=http://0.0.0.0:5000
```

Replace 5000 with your desired port number.

After making changes to the source code, run `dotnet build`, `dotnet publish` and `deploy.ps1` again to deploy the modified binaries.