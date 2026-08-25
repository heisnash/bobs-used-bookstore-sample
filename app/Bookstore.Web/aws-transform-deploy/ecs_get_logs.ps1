# Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.

param(
    [string]$ECSClusterName,
    [string]$ServiceName,
    [string]$ApplicationName = 'Bookstore.Web',
    [string]$Region = "us-east-1",
    [switch]$SkipAssumeRole,
    [string]$LogGroupName,
    [int]$LogLines = 100,
    [string]$StartTime,
    [string]$EndTime
)

$InfraConfigFile = infrastructure.config

# Command line parameter help text
$usage = @"
Usage: 
    ecs_get_logs.ps1 [-ECSClusterName <cluster-name>] [-ServiceName <service-name>] [-ApplicationName <app-name>] [-SkipAssumeRole] [-LogGroupName <log-group>] [-LogLines <number>] [-StartTime <time>] [-EndTime <time>]

Parameters:
    -ECSClusterName    : (Optional) ECS cluster name. If not provided, will try to read from config file
    -ServiceName       : (Optional) ECS service name. If not provided, will be derived from ApplicationName
    -ApplicationName   : (Optional) Application name. Default: Bookstore.Web
    -Region            : (Optional) AWS region. Default: us-east-1
    -SkipAssumeRole    : (Optional) Skip assuming the IAM role
    -LogGroupName      : (Optional) CloudWatch log group name. If not provided, will be derived from ApplicationName
    -LogLines          : (Optional) Number of log lines to retrieve. Default: 100
    -StartTime         : (Optional) Start time for log retrieval (ISO 8601 format, e.g., 2023-01-01T00:00:00Z)
    -EndTime           : (Optional) End time for log retrieval (ISO 8601 format, e.g., 2023-01-01T23:59:59Z)
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
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Severity = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Severity] $Message" 
}

function Initialize-InfraParams {
    if (-not (Test-Path -Path $InfraConfigFile)) {
        Write-Log "Infrastructure configuration file '$InfraConfigFile' not found." -Severity 'WARN'
        return
    }
    Write-Log "Looking for infrastructure details in '$InfraConfigFile'" -Severity 'INFO'
    $infraConfig = Get-Content $InfraConfigFile | ConvertFrom-Json
    if (-not $ECSClusterName -and $infraConfig.ECSClusterName) {
        $script:ECSClusterName = $infraConfig.ECSClusterName
        Write-Log "Found ECS Cluster Name: '$ECSClusterName'" -Severity 'INFO'
    }
}

# Initialize parameters from infrastructure config if not provided
Initialize-InfraParams

# Set default values
if (-not $ServiceName -and $ApplicationName) {
    $ServiceName = "AWSTransform-$ApplicationName-Service"
}

if (-not $LogGroupName -and $ApplicationName) {
    $LogGroupName = "/aws/ecs/AWSTransform-$ApplicationName-Logs"
}

# Validate required parameters
if (-not $ECSClusterName) {
    Write-Log "ECS cluster name is required" -Severity 'ERROR'
    Write-Host $usage
    exit 1
}

if (-not $ApplicationName) {
    Write-Log "Application name is required" -Severity 'ERROR'
    Write-Host $usage
    exit 1
}

# Assume role if not skipped
if (-not $SkipAssumeRole) {
    try {
        $roleArn = "arn:aws:iam::$((Get-STSCallerIdentity).Account):role/AWSTransform-Deploy-Manual-Deployment-Role"
        Write-Log "Assuming role: $roleArn" -Severity 'INFO'
        $credentials = (Use-STSRole -RoleArn $roleArn -RoleSessionName "LogsSession").Credentials
        Set-AWSCredential -AccessKey $credentials.AccessKeyId -SecretKey $credentials.SecretAccessKey -SessionToken $credentials.SessionToken -Scope Global
    }
    catch {
        Write-Log "Failed to assume role: $_" -Severity 'ERROR'
        exit 1
    }
}

try {
    Write-Log "Getting logs for ECS service: $ServiceName in cluster: $ECSClusterName" -Severity 'INFO'
    
    # Get ECS service information
    Write-Log "Retrieving ECS service details..." -Severity 'INFO'
    $service = Get-ECSService -Cluster $ECSClusterName -Service $ServiceName -Region $Region
    
    if (-not $service -or $service.Count -eq 0) {
        Write-Log "ECS service '$ServiceName' not found in cluster '$ECSClusterName'" -Severity 'ERROR'
        exit 1
    }
    
    Write-Log "Service Status: $($service.Status)" -Severity 'INFO'
    Write-Log "Running Count: $($service.RunningCount)" -Severity 'INFO'
    Write-Log "Desired Count: $($service.DesiredCount)" -Severity 'INFO'
    Write-Log "Pending Count: $($service.PendingCount)" -Severity 'INFO'
    
    # Get running tasks
    Write-Log "Retrieving running tasks..." -Severity 'INFO'
    $tasks = Get-ECSTaskList -Cluster $ECSClusterName -ServiceName $ServiceName -DesiredStatus RUNNING -Region $Region
    
    if (-not $tasks -or $tasks.Count -eq 0) {
        Write-Log "No running tasks found for service '$ServiceName'" -Severity 'WARN'
    } else {
        Write-Log "Found $($tasks.Count) running task(s)" -Severity 'INFO'
        
        # Get task details
        $taskDetails = Get-ECSTaskDetail -Cluster $ECSClusterName -Task $tasks -Region $Region
        foreach ($task in $taskDetails) {
            Write-Log "Task ARN: $($task.TaskArn)" -Severity 'INFO'
            Write-Log "Task Status: $($task.LastStatus)" -Severity 'INFO'
            Write-Log "CPU/Memory: $($task.Cpu)/$($task.Memory)" -Severity 'INFO'
            
            # Show container status
            foreach ($container in $task.Containers) {
                Write-Log "Container '$($container.Name)' Status: $($container.LastStatus)" -Severity 'INFO'
                if ($container.ExitCode) {
                    Write-Log "Container Exit Code: $($container.ExitCode)" -Severity 'WARN'
                }
                if ($container.Reason) {
                    Write-Log "Container Reason: $($container.Reason)" -Severity 'INFO'
                }
            }
        }
    }
    
    # Get CloudWatch logs
    Write-Log "Retrieving CloudWatch logs from log group: $LogGroupName" -Severity 'INFO'
    
    # Check if log group exists
    try {
        $logGroup = Get-CWLLogGroup -LogGroupNamePrefix $LogGroupName -Region $Region | Where-Object { $_.LogGroupName -eq $LogGroupName }
        if (-not $logGroup) {
            Write-Log "Log group '$LogGroupName' not found" -Severity 'ERROR'
            exit 1
        }
    }
    catch {
        Write-Log "Failed to check log group: $_" -Severity 'ERROR'
        exit 1
    }
    
    # Get log streams
    $logStreams = Get-CWLLogStream -LogGroupName $LogGroupName -OrderBy LastEventTime -Descending $true -Region $Region
    
    if (-not $logStreams -or $logStreams.Count -eq 0) {
        Write-Log "No log streams found in log group '$LogGroupName'" -Severity 'WARN'
    } else {
        Write-Log "Found $($logStreams.Count) log stream(s)" -Severity 'INFO'
        
        # Prepare time parameters
        $logParams = @{
            LogGroupName = $LogGroupName
            Region = $Region
        }
        
        if ($StartTime) {
            $logParams.StartTime = [DateTimeOffset]::Parse($StartTime).ToUnixTimeMilliseconds()
        }
        
        if ($EndTime) {
            $logParams.EndTime = [DateTimeOffset]::Parse($EndTime).ToUnixTimeMilliseconds()
        }
        
        # Get recent log streams (up to 5 most recent)
        $recentStreams = $logStreams | Select-Object -First 5
        
        foreach ($stream in $recentStreams) {
            Write-Log "=== Log Stream: $($stream.LogStreamName) ===" -Severity 'SUCCESS'
            Write-Log "Last Event Time: $(([DateTimeOffset]::FromUnixTimeMilliseconds($stream.LastEventTime)).ToString('yyyy-MM-dd HH:mm:ss'))" -Severity 'INFO'
            
            try {
                $logParams.LogStreamName = $stream.LogStreamName
                $logEvents = Get-CWLLogEvent @logParams | Select-Object -Last $LogLines
                
                if ($logEvents -and $logEvents.Count -gt 0) {
                    foreach ($event in $logEvents) {
                        $eventTime = ([DateTimeOffset]::FromUnixTimeMilliseconds($event.Timestamp)).ToString('yyyy-MM-dd HH:mm:ss')
                        Write-Host "[$eventTime] $($event.Message)"
                    }
                } else {
                    Write-Log "No log events found in this stream" -Severity 'INFO'
                }
            }
            catch {
                Write-Log "Failed to get log events from stream '$($stream.LogStreamName)': $_" -Severity 'ERROR'
            }
            
            Write-Host ""
        }
    }
    
    # Show recent service events
    Write-Log "=== Recent Service Events ===" -Severity 'SUCCESS'
    if ($service.Events -and $service.Events.Count -gt 0) {
        $recentEvents = $service.Events | Select-Object -First 10
        foreach ($event in $recentEvents) {
            $eventTime = $event.CreatedAt.ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host "[$eventTime] $($event.Message)"
        }
    } else {
        Write-Log "No recent service events found" -Severity 'INFO'
    }
}
catch {
    Write-Log "Failed to get ECS logs: $_" -Severity 'ERROR'
    Write-Log "Please verify:" -Severity 'ERROR'
    Write-Log "1. ECS cluster '$ECSClusterName' exists" -Severity 'ERROR'
    Write-Log "2. ECS service '$ServiceName' exists in the cluster" -Severity 'ERROR'
    Write-Log "3. You have permissions to access ECS and CloudWatch Logs" -Severity 'ERROR'
    Write-Log "4. The specified region '$Region' is correct" -Severity 'ERROR'
    exit 1
}