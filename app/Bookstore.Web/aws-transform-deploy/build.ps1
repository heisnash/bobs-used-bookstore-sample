# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)]
	[ValidateSet("EC2", "ECS")]
	[string]$DeploymentType,

	[switch]$Help,

	# Shared Parameters
	[string]$CsprojPath = 'app\Bookstore.Web\Bookstore.Web.csproj',
	[string]$ApplicationName = 'Bookstore.Web',
	[string]$Region = "us-east-1",
	[switch]$SkipAssumeRole,

	# EC2 Parameters
	[string]$S3Bucket,
	[string]$S3Folder,

	# ECS Parameters
	[string]$EcrRepository = 'awstransform-deploy-images/heisnash/bobs-used-bookstore-sample/app/bookstoreweb/bookstoreweb'
)

function Log {
	param(
		[Parameter(Mandatory=$true)]
		[string]$Message,
		[ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG','AWS CLI', 'DOTNET')]
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
    .\build.ps1 -DeploymentType <EC2|ECS> -CsprojPath <path> [options] [-Help]

Common Parameters:
    -DeploymentType        : (Required) Type of deployment (EC2 or ECS)
    -CsprojPath            : (Required) Path to the .csproj file
    -ApplicationName       : (Optional) Application name (defaults to csproj filename)
    -Region                : (Optional) AWS region for deployment. Default: us-east-1
    -SkipAssumeRole        : (Optional) Skip assumption of the deployment role

EC2 Parameters:
    -S3Bucket              : (Required) S3 bucket name for artifact upload
    -S3Folder              : (Optional) S3 folder/key prefix for the deployment package

ECS Parameters:
    -EcrRepository         : (Optional) ECR repository name (defaults to application path)

Examples:
    .\build.ps1 -DeploymentType EC2 -CsprojPath "src/MyApp/MyApp.csproj" -S3Bucket "my-bucket"
    .\build.ps1 -DeploymentType ECS -CsprojPath "src/MyApp/MyApp.csproj" -EcrRepository "my-app"
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
		$Credentials = (Use-STSRole -RoleArn $RoleArn -RoleSessionName "BuildSession").Credentials
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

function Confirm-RequiredParamsExist {
	if (-not (Test-Path $CsprojPath -PathType Leaf)) {
		Log "Csproj file '$CsprojPath' does not exist" "ERROR"
		exit 1
	}

	if ($DeploymentType -eq "EC2") {
		$requiredParams = @{
			ApplicationName = $ApplicationName
			Region = $Region
		}

		if (-not $script:S3Bucket) {
			$script:S3Bucket = "aws-transform-deployment-bucket-$(aws sts get-caller-identity --query Account --output text)-$Region"
		}
		Confirm-S3BucketExists -Bucket $script:S3Bucket

		if (-not $script:S3Folder) {
			$currentDate = Get-Date -Format "yyyy-MM-dd"
			$script:S3Folder = "$ApplicationName-$currentDate"
		}
	}
	elseif ($DeploymentType -eq "ECS") {
		$requiredParams = @{
			ApplicationName = $ApplicationName
			Region = $Region
			EcrRepository = $EcrRepository
		}
	}

	# Validate all required params are present
	$missingParams = @()
	foreach ($param in $requiredParams.GetEnumerator()) {
		if (-not $param.Value) {
			$missingParams += $param.Key
		}
	}
	if ($missingParams.Count -gt 0) {
		Log "Missing required parameters: $($missingParams -join ', ')" -Severity 'ERROR'
		Show-Usage
		exit 1
	}
}

function Confirm-S3BucketExists {
	param(
		[string]$Bucket
	)
	aws s3 ls "s3://$Bucket" --region $Region 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		Log "S3 bucket '$Bucket' does not exist or is not accessible" "ERROR"
		Log "Please create the bucket in region $Region before running this script" "ERROR"
		exit 1
	}
}

function Build-DotNetProject {
	Log "Restoring dependencies..." "INFO"
	dotnet restore $CsprojPath 2>&1 | Prefix-Output "DOTNET"
	if ($LASTEXITCODE -ne 0) {
		Log "Failed to restore dependencies" "ERROR"
		exit 1
	}

	Log "Building project..." "INFO"
	dotnet build $CsprojPath `
        --configuration Release `
        --no-restore 2>&1 | Prefix-Output "DOTNET"

	if ($LASTEXITCODE -ne 0) {
		Log "Build failed" "ERROR"
		exit 1
	}

	Log "Build completed successfully" "SUCCESS"
}

function Build-EC2Artifact {
	param(
		[string]$WorkspaceDir
	)

	Log "Publishing application for EC2..." "INFO"

	$publishDir = Join-Path $WorkspaceDir "publish"

	dotnet publish $CsprojPath `
        --configuration Release `
        --output $publishDir `
        --no-build `
        --runtime linux-x64 `
        --self-contained false 2>&1 | Prefix-Output "DOTNET"

	if ($LASTEXITCODE -ne 0) {
		Log "Publish failed" "ERROR"
		exit 1
	}

	Log "Creating deployment package..." "INFO"
	$artifactName = "$ApplicationName.zip"
	$zipPath = Join-Path $WorkspaceDir $artifactName

	if (Test-Path $zipPath) {
		Remove-Item -Path $zipPath -Force
	}

	Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath -Force

	if (-not (Test-Path $zipPath)) {
		Log "Failed to create deployment package" "ERROR"
		exit 1
	}

	$fileSize = (Get-Item $zipPath).Length
	$fileSizeMB = [math]::Round($fileSize / 1MB, 2)
	Log "Package created: $artifactName ($fileSizeMB MB)" "SUCCESS"

	Log "Uploading to S3..." "INFO"
	$s3Key = "$script:S3Folder/$artifactName"
	$artifactUri = "s3://$script:S3Bucket/$s3Key"
	aws s3 cp $zipPath $artifactUri --region $Region 2>&1 | Prefix-Output

	if ($LASTEXITCODE -ne 0) {
		Log "Failed to upload artifact to S3" "ERROR"
		exit 1
	}

	Log "Artifact uploaded: $artifactUri" "SUCCESS"

	Remove-Item -Path $publishDir -Recurse -Force -ErrorAction SilentlyContinue
	Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

	return $artifactUri
}

function Build-ECSArtifact {
	param(
		[string]$WorkspaceDir
	)

	Log "Building and pushing container image for ECS..." "INFO"

	$accountId = aws sts get-caller-identity --query Account --output text --region $Region
	if ($LASTEXITCODE -ne 0) {
		Log "Failed to get AWS account ID" "ERROR"
		exit 1
	}

	Log "Checking ECR repository: $script:EcrRepository" "INFO"
	aws ecr describe-repositories --repository-names $script:EcrRepository --region $Region 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) {
		Log "Creating ECR repository: $script:EcrRepository" "INFO"
		aws ecr create-repository --repository-name $script:EcrRepository --region $Region 2>&1 | Prefix-Output
		if ($LASTEXITCODE -ne 0) {
			Log "Failed to create ECR repository" "ERROR"
			exit 1
		}
	}

	$ecrPassword = aws ecr get-login-password --region $Region
		if ($LASTEXITCODE -ne 0) {
		Log "Failed to get ECR login credentials" "ERROR"
		exit 1
	}

	$env:SDK_CONTAINER_REGISTRY_UNAME = "AWS"
	$env:SDK_CONTAINER_REGISTRY_PWORD = $ecrPassword

	if ($LASTEXITCODE -ne 0) {
		Log "Failed to get ECR login credentials" "ERROR"
		exit 1
	}

	$publishDir = Join-Path $WorkspaceDir "publish"
	$registry = "$accountId.dkr.ecr.$Region.amazonaws.com"

	Log "Publishing container to ECR..." "INFO"
	dotnet publish $CsprojPath `
        --os linux `
        --arch x64 `
        -nologo `
        -v:quiet `
        -c Release `
        --self-contained true `
        -o $publishDir `
        -p:ContainerAppCommand=dummy `
        /t:PublishContainer `
        /p:ContainerRegistry=$registry `
        /p:ContainerImageTags="latest" `
        /p:ContainerRepository=$script:EcrRepository 2>&1 | Prefix-Output "DOTNET"

	if ($LASTEXITCODE -ne 0) {
		Log "Container publish failed" "ERROR"
		exit 1
	}

	$artifactUri = "$registry/${script:EcrRepository}:latest"
	Log "Container published: $artifactUri" "SUCCESS"

	Remove-Item -Path $publishDir -Recurse -Force -ErrorAction SilentlyContinue

	return $artifactUri
}

function Write-BuildConfigFile {
	param(
		[string]$ArtifactUri,
		[string]$BuildConfigPath = "build.config"
	)

	Log "Writing build output details to ${BuildConfigPath}:" "INFO"

	$outputsToSave = @{}
	if ($DeploymentType -eq "EC2") {
		$outputsToSave['S3ArtifactUri'] = $ArtifactUri
	}
	elseif ($DeploymentType -eq "ECS") {
		$outputsToSave['ContainerImageUri'] = $ArtifactUri
	}

	foreach ($key in $outputsToSave.Keys) {
		Log "+ ${key}: $($outputsToSave[$key])" "INFO"
	}

	$outputsToSave | ConvertTo-Json | Out-File $BuildConfigPath
}

function Main {

	if ($Help) {
		Show-Usage
		exit 0
	}

	Write-Host ""
	Log "=== Preparing for Build ==="

	Confirm-AwsCliInstalled

	Confirm-RequiredParamsExist

	if (-not $SkipAssumeRole) {
		Assume-DeploymentRole
	}

	Write-Host ""
	Log "=== Building .NET Application ==="

	Log "Deployment Type: $DeploymentType"
	Log "Application Name: $ApplicationName"
	Log "Region: $Region"

	Build-DotNetProject

	Write-Host ""
	Log "=== Packaging and Publishing ==="

	$workspaceDir = Split-Path -Parent $CsprojPath
	$artifactUri = ""

	if ($DeploymentType -eq "EC2") {
		$artifactUri = Build-EC2Artifact -WorkspaceDir $workspaceDir
	}
	elseif ($DeploymentType -eq "ECS") {
		$artifactUri = Build-ECSArtifact -WorkspaceDir $workspaceDir
	}

	Write-Host ""
	Log "=== Build Complete ===" "SUCCESS"

	Write-BuildConfigFile -ArtifactUri $artifactUri

	exit 0
}

Main