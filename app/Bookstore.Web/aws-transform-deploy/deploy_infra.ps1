# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("EC2", "ECS")]
    [string]$DeploymentType,

    [switch]$Help,

    # Shared Parameters
    [string]$ApplicationName = 'Bookstore.Web',
    [string]$StackName,
    [string]$Region = "us-east-1",
    [switch]$SkipAssumeRole,
    [string]$KmsKeyId,

    # EC2 Paramaters
    [string]$SubnetId,
    [string[]]$SecurityGroupIds,
    [string]$EC2InstanceProfile,
    [string]$InstanceType,
    [string]$CustomAmiId,
    [int]$VolumeSize,

    # ECS Parameters
    [string]$EcsClusterName
)

function Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG','AWS CLI')]
        [string]$Severity = 'INFO'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Severity] $Message"
}

function Prefix-Output {
    param (
        [string]$Severity = "AWS CLI"
    )
    process {
        if ($_ -ne "") {
            Log $_ $Severity
        }
    }
}

function Show-Usage {
    Write-Host @"
Usage: 
    .\deploy-infra.ps1 -DeploymentType <EC2|ECS> [options] [-Help]

Common Parameters:
    -DeploymentType        : (Required) Type of deployment (EC2 or ECS)
    -ApplicationName       : (Optional) Name of the main executable binary
    -StackName             : (Optional) Name for the CloudFormation stack. Default: AWSTransform-Deploy-Infra-Stack-<EC2|ECS>-<AppName>"
    -Region                : (Optional) AWS region for deployment. Default: us-east-1
    -SkipAssumeRole        : (Optional) Skip assumumption of the deployment role
    -KmsKeyId              : (Optional) KMS Key ID to use for infrastructure encryption.

EC2-specific Parameters:
    -SubnetId              : (Optional) ID of the VPC subnet for EC2 instance
    -SecurityGroupIds      : (Optional) Comma-separated list of security group IDs
    -EC2InstanceProfile    : (Optional) IAM instance profile name for EC2
    -InstanceType          : (Optional) EC2 instance type
    -CustomAmiId           : (Optional) Custom Amazon Machine Image ID
    -VolumeSize            : (Optional) Size in GB for the EC2 instance root volume

ECS-specific Parameters:
    -EcsClusterName        : (Optional) Desired name of the ECS cluster
"@
}

function Confirm-AwsCliInstalled {
    if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
        Log "AWS CLI is not installed or not in PATH." "ERROR"
        Log "Please download and install the AWS CLI from:" "INFO"
        Log "- https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" "INFO"
        exit 1
    }
}

function Assume-DeploymentRole {
    $RoleArn = "arn:aws:iam::$((Get-STSCallerIdentity).Account):role/AWSTransform-Deploy-Manual-Deployment-Role"
    Log "Assuming role: $RoleArn" "INFO"
    try {
        $Credentials = (Use-STSRole -RoleArn $RoleArn -RoleSessionName "DeploymentSession").Credentials
        Set-AWSCredential -AccessKey $Credentials.AccessKeyId -SecretKey $Credentials.SecretAccessKey -SessionToken $Credentials.SessionToken -Scope Global
    }
    catch {
        Log "Failed to assume role. Please verify that:" "ERROR"
        Log "1. The role exists in your account" "ERROR"
        Log "2. Your IAM user/role has permission to assume this role" "ERROR"
        Log "3. The role trust policy allows your IAM user/role to assume it" "ERROR"
        Log "Error details: $_" "ERROR"
        exit 1
    }
}

function Get-ParameterOverrides {
    $paramOverrides = @()
    Log "DeploymentType: $DeploymentType" "INFO"
    if ($DeploymentType -eq "EC2") {
        if ($ApplicationName) {
            Log "Application Name: $ApplicationName" "INFO"
            $paramOverrides += "ApplicationName=$ApplicationName"
        }
        if ($SubnetId) {
            Log "Subnet ID: $SubnetId" "INFO"
            $paramOverrides += "SubnetId=$SubnetId"
        }
        if ($SecurityGroupIds) {
            Log "Security Group IDs: $SecurityGroupIds" "INFO"
            $paramOverrides += "SecurityGroupIds=${$SecurityGroupIds -join ',')}"
        }
        if ($EC2InstanceProfile) {
            Log "EC2 Instance Profile: $EC2InstanceProfile" "INFO"
            $paramOverrides += "EC2InstanceProfile=$EC2InstanceProfile"
        }
        if ($InstanceType) {
            Log "Instance Type: $InstanceType" "INFO"
            $paramOverrides += "InstanceType=$InstanceType"
        }
        if ($CustomAmiId) {
            Log "Custom AMI ID: $CustomAmiId" "INFO"
            $paramOverrides += "CustomAmiId=$CustomAmiId"
        }
        if ($VolumeSize) {
            Log "Volume Size: $VolumeSize GB" "INFO"
            $paramOverrides += "VolumeSize=$VolumeSize"
        }
    } elseif ($DeploymentType -eq "ECS") {
        if ($EcsClusterName) {
            Log "ECS Cluster Name: $EcsClusterName" "INFO"
            $paramOverrides += "ECSClusterName=$EcsClusterName"
        }
    }
    if ($KmsKeyId) {
        Log "KMS Key ID: $KmsKeyId" "INFO"
        $paramOverrides += "KmsKeyId=$KmsKeyId"
    }
    return $paramOverrides
}

function Write-RecentErrorEvents {
    param (
        [string]$StackName,
        [DateTime]$StartTime
    )

    $events = aws cloudformation describe-stack-events --stack-name $StackName --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "Failed to get stack events: $events" "ERROR"
        return
    }

    $events = $events | ConvertFrom-Json

    $errorEvents = $events.StackEvents |
        Where-Object { [DateTime]::Parse($_.Timestamp) -ge $StartTime.ToLocalTime() } |
        Where-Object {
            $_.ResourceStatus -like "*FAILED" -or
            $_.ResourceStatus -eq "ROLLBACK_STARTED" -or
            $_.ResourceStatus -eq "ROLLBACK_IN_PROGRESS"
        } |
        Sort-Object -Property Timestamp -Descending

    foreach ($event in $errorEvents) {
        $logMessage = @(
            "Resource: $($event.LogicalResourceId)",
            "Status: $($event.ResourceStatus)"
        ) -join " | "

        if ($event.ResourceStatusReason) {
            $logMessage += " | Reason: $($event.ResourceStatusReason)"
        }

        Log $logMessage "ERROR"
    }
}

function Deploy-CloudFormationStack {
    param(
        [string]$CfnStackName,
        [string]$TemplateFilePath,
        [string[]]$ParamOverrides
    )

    $params = @(
        "--template-file", $TemplateFilePath,
        "--stack-name", $CfnStackName,
        "--region", $Region,
        "--tags", "CreatedFor=AWSTransform"
    )
    if ($paramOverrides) {
        $params += "--parameter-overrides"
        $params += $ParamOverrides
    }

    $deployStartTime = [DateTime]::UtcNow
    aws cloudformation deploy $params 2>&1 | ForEach-Object { $_ | Prefix-Output }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Log "CloudFormation deployment failed with exit code $LASTEXITCODE." "ERROR"
        if ($exitCode -eq 254) {
            Show-Usage
        } else {
            Write-RecentErrorEvents $CfnStackName $deployStartTime
        }
        exit 1
    }
}

function Write-InfraConfigFile {
    param(
        [string]$StackName,
        [string]$InfraConfigPath = "infrastructure.config"
    )
    $outputsJson = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs" --region $Region --output json
    if ($LASTEXITCODE -ne 0) {
        Log "Failed to describe CloudFormation stack with exit code $LASTEXITCODE." "ERROR"
        exit 1
    }

    $outputs = $outputsJson | ConvertFrom-Json

    if ($outputs) {
        Log "Writing the following infrastructure details to ${InfraConfigPath}:" "INFO"
        $outputsToSave = @{}

        foreach ($output in $outputs) {
            Log "+ $($output.OutputKey): $($output.OutputValue)" "INFO"
            $outputsToSave[$output.OutputKey] = $output.OutputValue
        }

        $outputsToSave | ConvertTo-Json | Out-File $InfraConfigPath
    }
}

function Main {

    if ($Help) {
        Show-Usage
        exit 0
    }

    Confirm-AwsCliInstalled

    Write-Host ""
    Log "=== Deploying Infrastructure Stack ==="

    if (-not $SkipAssumeRole) {
        Assume-DeploymentRole
    }

    if (-not ($StackName)) {
        $StackId = $ApplicationName -replace '[^a-zA-Z0-9]', '-'
        $StackName = "AWSTransform-Deploy-Infra-Stack-$DeploymentType-$StackId"
    }

    $templateFilePath = Join-Path $PSScriptRoot "${DeploymentType}_infra_template.yml"

    $paramOverrides = Get-ParameterOverrides

    Deploy-CloudFormationStack $StackName $templateFilePath $paramOverrides

    Write-Host ""
    Log "=== Infrastructure Deployment Complete ===" "SUCCESS"

    Write-InfraConfigFile -StackName $StackName

}

Main