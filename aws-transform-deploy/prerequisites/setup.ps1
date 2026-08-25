# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

param (
	[string]$StackName = "AWSTransform-Deploy-IAM-Role-Stack",
	[switch]$DisableBucketCreation,
	[switch]$Help
)

$TemplateFile = "iam_roles.yml"

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
	Write-Host "Usage: ./setup.ps1 [-StackName <StackName>] [-DisableBucketCreation] [-Help]"
}

function Confirm-AwsCliInstalled {
	if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
		Log "AWS CLI is not installed or not in PATH." "ERROR"
		Log "Please download and install the AWS CLI from:" "INFO"
		Log "- https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" "INFO"
		exit 1
	}
}

function Write-RecentErrorEvents {
	param (
		[string]$StackName,
		[DateTime]$StartTime
	)

	$events = aws cloudformation describe-stack-events --stack-name $StackName 2>&1
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

function Main {
	if ($Help) {
		Show-Usage
		exit 0
	}

	Confirm-AwsCliInstalled

	Log "Stack Name: $StackName"
	Log "Bucket Creation: $( -not $DisableBucketCreation )"

	if ($DisableBucketCreation) {
		Log "Bucket creation is disabled. An S3 bucket is required for AWS Transform deployment." "WARN"
	}

	Write-Host ""
	Log "=== Checking ECS Service-Linked Role ==="

	$output = aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>&1

	if ($LASTEXITCODE -ne 0) {
		if ($output -match "Service role name .* has been taken") {
			Log "ECS service-linked role already exists."
		} else {
			Log "Failed to create service-linked role." "ERROR"
			$output | ForEach-Object { $_ | Prefix-Output }
			exit 1
		}
	} else {
		Log "Service-linked role created successfully."
	}

	Write-Host ""
	Log "=== Deploying CloudFormation Stack ==="

	$bucketFlag = if ($DisableBucketCreation) { "false"  } else { "true" }
	$paramOverrides = @("CreateS3Bucket=$bucketFlag")
	$deployStartTime = [DateTime]::UtcNow
	aws cloudformation deploy `
		--template-file $TemplateFile `
		--stack-name $StackName `
		--capabilities CAPABILITY_NAMED_IAM `
		--parameter-overrides $paramOverrides `
		--tags CreatedFor=AWSTransform 2>&1 |
			ForEach-Object { $_ | Prefix-Output }
	$exitCode = $LASTEXITCODE

	if ($exitCode -ne 0) {
		Log "CloudFormation deployment failed with exit code $LASTEXITCODE." "ERROR"
		if ($exitCode -eq 254) {
			Show-Usage
		} else {
			Write-RecentErrorEvents $StackName $deployStartTime
		}
		exit 1
	}

	Write-Host ""
	Log "=== Deployment Complete ==="

	Log "Next steps:"
	Log "- Return to the AWS Transform website and select 'Continue' to configure application infrastructure if not done yet."
	Log "- Once infrastructure is configured, deploy your application by selecting the 'Deploy' button in the AWS Transform website."
	Log "- Alternatively, consult the README located in the 'aws-transform-deploy' folder of your project’s parent directory"
	Log "  if you prefer self-managed deployment or no further configuration is needed."
	Log "- Optionally, review and update IAM role permissions if your application requires further customization."
}

Main