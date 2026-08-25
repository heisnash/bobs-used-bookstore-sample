# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("EC2", "ECS")]
    [string]$DeploymentType,

    [switch]$Help,

    # Shared parameters
    [string]$ApplicationName = 'Bookstore.Web',
    [string]$Region = "us-east-1",
    [switch]$SkipAssumeRole,

    # EC2-specific parameters
    [string]$PublishDirectory,
    [string]$EC2InstanceId,
    [string]$S3Bucket,
    [string]$S3Folder,

    # ECS-specific parameters
    [string]$StackName = "AWSTransform-Deploy-App-Stack-Bookstore-Web-686569-326a14",
    [string]$ECSClusterName,
    [string[]]$SubnetIds,
    [string[]]$SecurityGroupIds,
    [string]$ContainerImageUri,
    [int]$ContainerCpu,
    [int]$ContainerMemory,
    [int]$ContainerStorage,
    [int]$ContainerPort,
    [hashtable]$EnvironmentVariables,
    [int]$ECSTaskCount,
    [string]$ECSExecutionRole,
    [string]$ECSTaskRole
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
    .\deploy.ps1 -DeploymentType <EC2|ECS> [options] [-Help]

Common Parameters:
    -DeploymentType        : (Required) Type of deployment (EC2 or ECS)
    -ApplicationName       : Name of the main executable binary
    -Region                : AWS region for deployment. Default: us-east-1
    -SkipAssumeRole        : Skip assumumption of the deployment role

EC2 Parameters:
    -PublishDirectory      : (Required) Path to the directory containing the published application
    -EC2InstanceId         : ID of the EC2 instance where the application will be deployed
    -S3Bucket              : S3 bucket for uploading the deployment package
    -S3Folder              : S3 folder/key prefix for the deployment package

ECS Parameters:
    -StackName             : CloudFormation stack name
    -ECSClusterName        : Name of the existing ECS cluster to deploy the application in
    -SubnetIds             : Subnet IDs (array)
    -SecurityGroupIds      : Security group IDs (array)
    -ContainerImageUri     : (Required) Container image URI
    -ContainerCpu          : Container CPU units
    -ContainerMemory       : Container memory (MB)
    -ContainerStorage      : Container storage (GB)
    -ContainerPort         : Container port number
    -EnvironmentVariables  : Environment variables to set in the container (hashtable)
    -ECSTaskCount          : Number of ECS tasks
    -ECSExecutionRole      : ECS execution role ARN
    -ECSTaskRole           : ECS task role ARN

Note: Run deploy_infra.ps1 first to create the required infrastructure.
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

function Initialize-DeploymentParams {
    param (
        [string]$ConfigPath
    )
    if (-not (Test-Path -Path $ConfigPath)) {
        Log "Configuration file '$ConfigPath' not found." "WARN"
        return
    }
    Log "Looking for details in '$ConfigPath'"
    $config = Get-Content $ConfigPath | ConvertFrom-Json
    if ($DeploymentType -eq "EC2") {
        if (-not $EC2InstanceId -and $config.InstanceId) {
            $script:EC2InstanceId = $config.InstanceId
            Log "Found EC2 Instance Id: '$EC2InstanceId'"
        }
    } elseif ($DeploymentType -eq "ECS") {
        if (-not $ECSClusterName -and $config.ECSClusterName) {
            $script:ECSClusterName = $config.ECSClusterName
            Log "Found ECS Cluster Name: '$ECSClusterName'"
        }
        if (-not $ContainerImageUri -and $config.ContainerImageUri) {
            $script:ContainerImageUri = $config.ContainerImageUri
            Log "Found Container Image URI: '$ContainerImageUri'"
        }
    }
}

function Confirm-RequiredParamsExist {

    if ($DeploymentType -eq "EC2") {

        $requiredParams = @{
            PublishDirectory = $PublishDirectory
            EC2InstanceId = $EC2InstanceId
            ApplicationName = $ApplicationName
        }

        if ($PublishDirectory -and -not (Test-Path $PublishDirectory -PathType Container)) {
            Log "Publish Directory '$PublishDirectory' does not exist" -Severity 'ERROR'
            exit 1
        }

        if (-not $S3Bucket) {
            $S3Bucket = "aws-transform-deployment-bucket-$(aws sts get-caller-identity --query Account --output text)-$Region"
        }
        Confirm-S3BucketExists $S3Bucket

        if (-not $S3Folder) {
            $currentDate = Get-Date -Format "yyyy-MM-dd"
            $S3Folder = "$ApplicationName-$currentDate"
        }

        $script:s3 = @{
            Bucket = $S3Bucket
            Key = $S3Folder
        }

    } elseif ($DeploymentType -eq "ECS") {

        $requiredParams = @{
            StackName = $StackName
            Region = $Region
            ECSClusterName = $ECSClusterName
            ContainerImageUri = $ContainerImageUri
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

function archive_publish_directory {
    param (
        [string]$publishDir,
        [string]$MainBinary
    )

    $parentDir = Split-Path -Parent $publishDir
    $archiveFile = Join-Path $parentDir "$MainBinary.zip"

    Log "Starting to create archive from $publishDir" -Severity 'INFO'

    if (Test-Path $archiveFile) {
        Remove-Item -Path $archiveFile -Force -ErrorAction SilentlyContinue
    }

    try {
        Compress-Archive -Path "$publishDir\*" -DestinationPath $archiveFile -CompressionLevel Optimal -Force    }
    catch {
        Log "Failed to create archive: $_" -Severity 'ERROR'
        exit 1
    }

    if (-not (Test-Path $archiveFile)) {
        Log "Failed to create archive" -Severity 'ERROR'
        exit 1
    }

    # Get and display file size
    $fileSize = (Get-Item $archiveFile).Length
    $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
    Log "Archive created successfully: $archiveFile ($fileSizeMB MB)" -Severity 'SUCCESS'

    return $archiveFile
}

# Function to upload to S3 with retries
function upload_to_s3 {
    param (
        [string]$file,
        [string]$bucket,
        [string]$key,
        [string]$zipFile
    )
    
    # Validate input parameters
    if (-not $file -or -not $bucket -or -not $key) {
        Log "Missing required parameters for S3 upload" -Severity 'ERROR'
        Log "File: $file" -Severity 'ERROR'
        Log "Bucket: $bucket" -Severity 'ERROR'
        Log "Key: $key" -Severity 'ERROR'
        exit 1
    }

    # Verify file exists
    if (-not (Test-Path $file)) {
        Log "File does not exist: $file" -Severity 'ERROR'
        exit 1
    }

    $uploadKey =  "$key/$zipFile" 
    
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Log "Attempting S3 upload (attempt $($i+1)/5)" -Severity 'INFO'
            Write-S3Object -BucketName $bucket -Key $uploadKey -File $file -ErrorAction Stop
            Log "Successfully uploaded to s3://$bucket/$uploadKey" -Severity 'SUCCESS'
            return
        } catch {
            $errorMessage = $_.Exception.Message
            Log "Upload attempt $($i+1) failed: $errorMessage" -Severity 'ERROR'
            
            if ($_.Exception.Message -like "*The specified bucket does not exist*") {
                Log "Bucket $bucket does not exist" -Severity 'ERROR'
                exit 1
            }
            
            if ($_.Exception.Message -like "*Access Denied*") {
                Log "Access denied to bucket $bucket" -Severity 'ERROR'
                exit 1
            }

            $waitTime = [Math]::Pow(2, $i)
            Log "Waiting $waitTime seconds before retry..." -Severity 'WARN'
            Start-Sleep -Seconds $waitTime
        }
    }
    Log "Failed to upload to S3 after 5 attempts" -Severity 'ERROR'
    exit 1
}

# Function to check if EC2 instance exists
function Check-InstanceExists {
    param ($instanceId)
    try {
        $instance = Get-EC2Instance -InstanceId $instanceId -ErrorAction Stop
        $state = $instance.Instances[0].State.Name
        Log "Instance $instanceId exists with state: $state" -Severity 'INFO'
        
        if ($state -eq 'terminated') {
            Log "Instance $instanceId is terminated" -Severity 'ERROR'
            return $false
        }
        return $true
    }
    catch {
        Log "Instance $instanceId does not exist or is not accessible: $_" -Severity 'ERROR'
        return $false
    }
}

function check_ssm_status {
    param (
        [string]$instanceId
    )
    for ($i = 0; $i -lt 60; $i++) {
        $status = (Get-SSMInstanceInformation -Filter @{Key="InstanceIds";Values=$instanceId}).PingStatus
        Log "Checking SSM agent status (attempt $($i+1)/60): $status" -Severity 'INFO'
        if ($status -eq 'Online') {
            return $true
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function create_systemd {
    param(
        [string]$publishDir,
        [string]$MainBinary,
        [string]$dbConnectionStringLocation
    )

    $mainBinaryPath = ""
    $binaryFiles = Get-ChildItem -Path $publishDir -Name "$MainBinary*" -Recurse -File

    foreach ($binaryFile in $binaryFiles) {
        $filename = Split-Path $binaryFile -Leaf
        if ($filename -eq $MainBinary) {
            $mainBinaryPath = $binaryFile -replace "^$([regex]::Escape($publishDir))[\\/]", "" -replace "\\", "/"
            break
        }
    }

    if (!$mainBinaryPath) {
        $mainBinaryPath = $MainBinary
    }

    # Check for aws-transform-deploy.env file
    $environment = Test-Path (Join-Path $publishDir "aws-transform-deploy.env")

    $deployDir = "/var/www/$MainBinary"
    $execStart = "$deployDir/$mainBinaryPath"

    $serviceContent = @"
[Unit]
Description=$MainBinary .NET App
After=network.target

[Service]
WorkingDirectory=$deployDir
ExecStart=$execStart
"@

    if ($environment) {
        $serviceContent += "`nEnvironmentFile=$deployDir/aws-transform-deploy.env"
    }

    $serviceContent += @"

StandardOutput=append:/var/log/$MainBinary/system.out.log
StandardError=append:/var/log/$MainBinary/system.err.log
Restart=always
User=root
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true

[Install]
WantedBy=multi-user.target
"@

    $serviceContent | Out-File -FilePath "$publishDir\$MainBinary.service" -Encoding UTF8
}

# Function to trigger SSM command
function trigger_ssm_command {
    param ($instanceId, $bucket, $key, $MainBinary)
    $downloadPath =  "$key/$MainBinary.zip"

    $commands = @"
MAIN_BINARY_NAME='$MainBinary'
DEPLOY_ROOT='/var/www'
DEPLOY_DIR=`$DEPLOY_ROOT/`$MAIN_BINARY_NAME
ZIP_FILE=/tmp/`$MAIN_BINARY_NAME.zip
LOG_DIR=/var/log/`$MAIN_BINARY_NAME

# Verify the archive is on the EC2 instance
if [ -f `$ZIP_FILE ]; then
  echo 'Zip file found at '`$ZIP_FILE
else
  echo 'Zip file not found at '`$ZIP_FILE
  exit 1
fi

# Install .NET 8 runtime and ASP.NET Core 8 runtime
sudo dnf install -y dotnet-runtime-8.0 --refresh --best --allowerasing
echo === dotnet 8.0 runtime is installed ===
sudo dnf install -y aspnetcore-runtime-8.0 --refresh --best --allowerasing
echo === aspnetcore 8.0 runtime is installed ===

# Stop and remove previous deployment service
sudo systemctl stop `$MAIN_BINARY_NAME.service || true
sudo systemctl disable `$MAIN_BINARY_NAME.service || true
sudo rm -f /etc/systemd/system/`$MAIN_BINARY_NAME.service

# Remove the previous deployment directory and create new ones
sudo rm -rf `$DEPLOY_DIR
sudo rm -rf `$LOG_DIR
mkdir -p `$DEPLOY_DIR
mkdir -p `$LOG_DIR

# Unzip the archive
unzip -q `$ZIP_FILE -d `$DEPLOY_DIR
rm `$ZIP_FILE

# Check if a environment file exists for logging
if [ -f `${DEPLOY_DIR}/aws-transform-deploy.env ]; then
    echo 'env file found'
else
    echo 'env file not found'
fi

# Check if a .service file exists and move to correct location
if [ -f `${DEPLOY_DIR}/`$MAIN_BINARY_NAME.service ]; then
    echo '.service file found'
    sudo mv `${DEPLOY_DIR}/`$MAIN_BINARY_NAME.service '/etc/systemd/system/'
else
    echo '.service file NOT found'
    exit 1
fi

MAIN_BINARY_FILE_PATH=`$(sudo systemctl show -p ExecStart `${MAIN_BINARY_NAME}.service | cut -d= -f4 | cut -d';' -f1)
echo 'Main binary path: '`$MAIN_BINARY_FILE_PATH
sudo chmod +x `$MAIN_BINARY_FILE_PATH


sudo systemctl daemon-reload
sudo systemctl enable `$MAIN_BINARY_NAME.service
sudo systemctl start `$MAIN_BINARY_NAME.service
echo "=== Printing systemctl status  ==="
sudo systemctl status `$MAIN_BINARY_NAME.service

echo "=== Printing system events by journalctl ==="
journalctl -u `$MAIN_BINARY_NAME.service -n 30

echo "=== system.out.log ==="
cat `$LOG_DIR/system.out.log

echo "=== system.err.log ==="
cat `$LOG_DIR/system.err.log
"@

    try {
        $json = @{
            sourceType = @("S3")
            sourceInfo = @("{`"path`":`"https://$bucket.s3.amazonaws.com/$downloadPath`"}")
            workingDirectory = @("/tmp")
            commandLine = @($commands)
        }

        $cmd = $null
        $maxRetries = 5
        $success = $false

        for ($i = 0; $i -lt $maxRetries; $i++) {
            try {
                $cmd = Send-SSMCommand -InstanceId $instanceId `
                    -DocumentName "AWS-RunRemoteScript" `
                    -Parameter $json `
                    -TimeoutSeconds 600
                $success = $true
                break
            } catch {
                $errorMessage = $_.Exception.Message
                Log "Failed to send SSM command (attempt $($i+1)/$maxRetries): $errorMessage" -Severity 'ERROR'
                
                if ($errorMessage -like "*InvalidInstanceId*") {
                    Log "Instance ID $instanceId is invalid" -Severity 'ERROR'
                    throw
                }
                
                if ($errorMessage -like "*AccessDenied*") {
                    Log "Access denied when sending SSM command" -Severity 'ERROR'
                    throw
                }

                if ($i -eq ($maxRetries - 1)) {
                    Log "Failed to send SSM command after $maxRetries attempts" -Severity 'ERROR'
                    throw
                }

                $waitTime = [Math]::Pow(2, $i)
                Log "Waiting $waitTime seconds before retry..." -Severity 'WARN'
                Start-Sleep -Seconds $waitTime
            }
        }

        if (-not $success -or -not $cmd) {
            Log "Failed to initiate SSM command" -Severity 'ERROR'
            throw "SSM command initiation failed"
        }

        $commandId = $cmd.CommandId
        Log "SSM Command is initiated on EC2 $instanceId with ID: $commandId" -Severity 'SUCCESS'

        # Wait for command completion
        do {
            Start-Sleep -Seconds 5
            $result = Get-SSMCommandInvocation -CommandId $commandId -InstanceId $instanceId 
            Log "Command Status: $($result.Status)" -Severity 'INFO'
        } while ($result.Status -eq "InProgress" -or $result.Status -eq "Pending")

        # Get command output
        $output = Get-SSMCommandInvocationDetail -CommandId $commandId -InstanceId $instanceId -PluginName "runShellScript"
        Log "Command Output:" -Severity 'INFO'
        Log $output.StandardOutputContent -Severity 'INFO'
        
        if ($result.Status -ne "Success") {
            Log "Error Output:" -Severity 'ERROR'
            Log $output.StandardErrorContent -Severity 'ERROR'
            throw "SSM command failed with status: $($result.Status)"
        }
    }
    catch {
        Log "Failed to send SSM command" -Severity 'ERROR'
        throw
    }
}

# Function to cleanup the archive folder
function cleanup {
    param ($file)
    Remove-Item -Path $file -Force
}

function Format-EnvironmentVariables {
    param (
        [hashtable]$EnvVars,
        [string]$Indent
    )
    $output = @()
    foreach ($env in $EnvVars.GetEnumerator()) {
        $output += "$Indent  - Name: '$($env.Key)'"
        $output += "$Indent    Value: '$($env.Value)'"
    }
    return $output
}

function Add-EnvironmentVariablesToTemplate {
    param (
        [hashtable]$EnvVars,
        [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        Log "Template file not found at path: $TemplatePath" "ERROR"
        exit 1
    }

    if ($EnvVars.Count -eq 0) {
        return
    }

    $lines = Get-Content -Path $TemplatePath
    $newContent = @()
    $inContainerDef = $false
    $containerDefIndent = ""
    $inEnvironment = $false
    $environmentIndent = ""
    $envVarsInserted = $false
    $existingEnvVars = @{}

    foreach ($line in $lines) {

        # Check if we found the ContainerDefinitions section
        if ($line -match "^\s*ContainerDefinitions:") {
            $inContainerDef = $true
            $containerDefIndent = ($line -match "^(\s+)") ? $matches[1] : "      "
        }

        # Check if we're exiting ContainerDefinitions (less or equal indentation)
        elseif ($inContainerDef -and $line -match "^(\s*)\S+:" -and $matches[1].Length -le $containerDefIndent.Length) {
            if (-not $envVarsInserted) {
                $indent = $containerDefIndent + "    "
                $newContent += "$indent`Environment:"
                $newContent += Format-EnvironmentVariables -EnvVars $EnvVars -Indent $indent
            }
            $inContainerDef = $false
        }

        # Check if we found the Environment section
        elseif ($inContainerDef -and $line -match "^\s*Environment:") {
            $inEnvironment = $true
            $environmentIndent = ($line -match "^(\s+)") ? $matches[1] : "          "
        }

        # Track existing environment variables
        elseif ($inEnvironment -and $line -match "^\s*-\s*Name:\s*'([^']*)'") {
            $envName = $matches[1]
            $existingEnvVars[$envName] = $true
        }

        # Check if we're exiting Environment (less or equal indentation)
        elseif ($inEnvironment -and $line -match "^(\s*)\S+:" -and $matches[1].Length -le $environmentIndent.Length) {
            $newEnvVars = @{}
            foreach ($key in $EnvVars.Keys) {
                if (-not $existingEnvVars.ContainsKey($key)) {
                    $newEnvVars[$key] = $EnvVars[$key]
                } else {
                    Log "Skipping existing environment variable: $key" -Severity 'WARN'
                }
            }
            $newContent += Format-EnvironmentVariables -EnvVars $newEnvVars -Indent $environmentIndent
            $envVarsInserted = $true
            $inEnvironment = $false
        }

        $newContent += $line
    }

    $newContent | Set-Content -Path $TemplatePath
}

function Get-ParameterOverrides {
    $paramOverrides = @()
    if ($DeploymentType -eq "ECS") {
        if ($ECSClusterName) {
            Log "ECS Cluster Name: $ECSClusterName"
            $paramOverrides += "ECSClusterName=$ECSClusterName"
        }
        if ($SubnetIds) {
            Log "Subnet IDs: $($SubnetIds -join ',')"
            $paramOverrides += "SubnetIds=$($SubnetIds -join ',')"
        }
        if ($SecurityGroupIds) {
            Log "Security Group IDs: $($SecurityGroupIds -join ',')"
            $paramOverrides += "SecurityGroupIds=$($SecurityGroupIds -join ',')"
        }
        if ($ContainerImageUri) {
            Log "Container Image URI: $ContainerImageUri"
            $paramOverrides += "ContainerImageUri=$ContainerImageUri"
        }
        if ($ContainerCpu) {
            Log "Container CPU: $ContainerCpu"
            $paramOverrides += "ContainerCpu=$ContainerCpu"
        }
        if ($ContainerMemory) {
            Log "Container Memory: $ContainerMemory"
            $paramOverrides += "ContainerMemory=$ContainerMemory"
        }
        if ($ContainerStorage) {
            Log "Container Storage: $ContainerStorage"
            $paramOverrides += "ContainerStorage=$ContainerStorage"
        }
        if ($ContainerPort) {
            Log "Container Port: $ContainerPort"
            $paramOverrides += "ContainerPort=$ContainerPort"
        }
        if ($EnvironmentVariables) {
            Log "Environment Variables: $($EnvironmentVariables | ConvertTo-Json -Compress)"
        }
        if ($ECSTaskCount) {
            Log "ECS Task Count: $ECSTaskCount"
            $paramOverrides += "ECSTaskCount=$ECSTaskCount"
        }
        if ($ECSExecutionRole) {
            Log "ECS Execution Role: $ECSExecutionRole"
            $paramOverrides += "ECSExecutionRole=$ECSExecutionRole"
        }
        if ($ECSTaskRole) {
            Log "ECS Task Role: $ECSTaskRole"
            $paramOverrides += "ECSTaskRole=$ECSTaskRole"
        }
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

function Main {

    if ($Help) {
        Show-Usage
        exit 0
    }

    Write-Host ""
    Log "=== Preparing for Deployment ==="

    Confirm-AwsCliInstalled

    Initialize-DeploymentParams -ConfigPath "build.config"
    Initialize-DeploymentParams -ConfigPath "infrastructure.config"

    Confirm-RequiredParamsExist

    if (-not $SkipAssumeRole) {
        Assume-DeploymentRole
    }

    Write-Host ""
    Log "=== Deploying Application to $DeploymentType ==="

    if ($DeploymentType -eq "EC2") {

        create_systemd $PublishDirectory $ApplicationName

        $zip = archive_publish_directory $PublishDirectory $ApplicationName

        upload_to_s3 $zip $s3.Bucket $s3.Key "$ApplicationName.zip"

        cleanup $zip

        if (-not (check_ssm_status $EC2InstanceId)) {
            Log "SSM agent did not go online after 5 minutes" -Severity 'ERROR'
            exit 1
        }

        trigger_ssm_command $EC2InstanceId $s3.Bucket $s3.Key $ApplicationName

        $instanceInfo = Get-EC2Instance -InstanceId $EC2InstanceId
        $publicIp = $instanceInfo.Instances[0].PublicIpAddress

        Log "====================================" -Severity 'SUCCESS'
        if ($publicIp) {
            Log "Application deployed to EC2 instance with public IP $publicIp" -Severity 'SUCCESS'
        } else {
            Log "Could not determine instance public IP" -Severity 'WARN'
            Log "Please check EC2 console for instance IP address" -Severity 'WARN'
        }

        Log "Application is placed in /var/www/$ApplicationName/ and started as systemd service /etc/systemd/system/$ApplicationName.service" -Severity 'SUCCESS'
        Log "Please refer to README.md file on how to access logs and general troubleshooting tips" -Severity 'SUCCESS'
        Log "====================================" -Severity 'SUCCESS'

    } elseif ($DeploymentType -eq "ECS") {

        $templateFilePath = "ecs_application_deployment.yml"

        $paramOverrides = Get-ParameterOverrides

        Add-EnvironmentVariablesToTemplate $EnvironmentVariables $templateFilePath

        Deploy-CloudFormationStack $StackName $templateFilePath $paramOverrides

    }

    Write-Host ""
    Log "=== Application Deployment Complete ===" "SUCCESS"
}

Main