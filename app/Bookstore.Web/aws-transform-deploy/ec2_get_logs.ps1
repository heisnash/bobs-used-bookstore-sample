# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

param(
    [string]$EC2InstanceId,
    [switch]$SkipAssumeRole,
    [string]$LogFilePath
)

$InstanceIdFile = "instance_id_from_infra_deployment.config"


# Command line parameter help text
$usage = @"
Usage: 
    Get-Logs.ps1 [-EC2InstanceId <instance-id>] [-SkipAssumeRole] [-LogFilePath <path>]

Parameters:
    -EC2InstanceId     : (Optional) EC2 instance ID to get logs from. If not provided, will try to read from config file
    -SkipAssumeRole    : (Optional) Skip assuming the IAM role
    -LogFilePath       : (Optional) Specific log file path to read. If not provided, will get standard logs
"@

# Show usage if -help parameter is passed
if ($args -contains "-help" -or $args -contains "-h" -or $args -contains "/?") {
    Write-Host $usage
    exit 0
}


function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Severity = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Severity] $Message" 
}

# Get EC2 instance ID from parameter or file
if (-not $EC2InstanceId -and (Test-Path $InstanceIdFile)) {
    try {
        $instanceConfig = Get-Content $InstanceIdFile | ConvertFrom-Json
        $EC2InstanceId = $instanceConfig.InstanceId
        Write-Log "Using EC2 instance ID from $InstanceIdFile : $EC2InstanceId" -Severity 'INFO'
    }
    catch {
        Write-Log "Failed to read instance ID from $InstanceIdFile : $_" -Severity 'WARN'
    }
}

if (-not $EC2InstanceId) {
    Write-Log "EC2 instance ID is required" -Severity 'ERROR'
    Write-Host $usage
    exit 1
}

# Validate EC2 instance ID format
if (-not ($EC2InstanceId -match "^i-[a-zA-Z0-9]{8,17}$")) {
    Write-Log "Invalid EC2 instance ID format. Must start with 'i-' followed by 8-17 alphanumeric characters" -Severity 'ERROR'
    Write-Host $usage
    exit 1
}

# Assume role if not skipped
if (-not $SkipAssumeRole) {
    try {
        $roleArn = "arn:aws:iam::$((Get-STSCallerIdentity).Account):role/AWSTransformDotNET-Application-Deployment-Role"
        Write-Log "Assuming role: $roleArn" -Severity 'INFO'
        $credentials = (Use-STSRole -RoleArn $roleArn -RoleSessionName "LogsSession").Credentials
        Set-AWSCredential -AccessKey $credentials.AccessKeyId -SecretKey $credentials.SecretAccessKey -SessionToken $credentials.SessionToken -Scope Global
    }
    catch {
        Write-Log "Failed to assume role: $_" -Severity 'ERROR'
        exit 1
    }
}

# Execute SSM command to get logs
try {
    $MainBinary = "Bookstore.Web"
    Write-Log "Executing SSM command to get logs from instance: $EC2InstanceId" -Severity 'INFO'
    
    if ($LogFilePath) {
        $logCommands = 
            @"
echo === $LogFilePath ===
cat $LogFilePath
"@
    } else {
        $logCommands = 
            @"
echo === Printing systemctl status  ===
sudo systemctl status $mainBinary.service
echo === Printing system events by journalctl ===
journalctl -u $mainBinary.service -n 10
LOG_DIR=/var/log/$mainBinary
echo === `$LOG_DIR/system.out.log ===
tail -n 50 `$LOG_DIR/system.out.log
echo === `$LOG_DIR/system.err.log ===
tail -n 50 `$LOG_DIR/system.err.log
"@
    }
    
    $command = Send-SSMCommand -InstanceId $EC2InstanceId -DocumentName "AWS-RunShellScript" -Parameter @{
        commands = @($logCommands)
    }

    # Wait for command completion
    do {
        Start-Sleep -Seconds 1
        $result = Get-SSMCommandInvocation -CommandId $command.CommandId -InstanceId $instanceId 
        Write-Log "Command Status: $($result.Status)" -Severity 'INFO'
    } while ($result.Status -eq "InProgress" -or $result.Status -eq "Pending")    
    
    $output = Get-SSMCommandInvocationDetail -CommandId $command.CommandId -InstanceId $EC2InstanceId -PluginName "aws:runShellScript"
    
    Write-Log "Logs from EC2 instance:" -Severity 'INFO'
    Write-Host $output.StandardOutputContent
}
catch {
    Write-Log "Failed to get logs: $_" -Severity 'ERROR'
    exit 1
}