# Script to check if server services are running
# Get alerted on Telegram
# Author      : Bairaktaris Emmanuel
# Date        : December 26, 2024
# Last version: January 2, 2025
# Link        : https://sonam.dev

# === CONFIGURATION ===
$botToken = [System.Environment]::GetEnvironmentVariable("BOT_TOKEN", "Machine")
$chatID = [System.Environment]::GetEnvironmentVariable("BOT_CHAT_ID", "Machine")

# Define a hashtable with each server and its respective services
$serversToMonitor = @{
	  "server01" = @("APCPBEAgent")
    "server02" = @("nodeportal.exe")
    "server03" = @("Epsilon Application Service (Business Payroll)", "ZKAccessPush.ServiceApp")
    "server04" = @("SasWatchDg", "OracleServiceSEN", "OracleVssWriterSEN", "OracleOraDB12Home1MTSRecoveryService", "OracleOraDB12Home1TNSListener", "SenDaemonSvc")
}

# Initialize a hashtable to store the previous states of services
$serviceStates = @{}

$checkInterval = 120  # Time in seconds to wait between each check (e.g., 120 seconds = 2 minutes)
$reportTimes = @("07:50", "10:35", "14:20")  # Times to send the status report
$lastReportTime = $null  # Track when the last report was sent

#function Send-TelegramMessage {
#    param (
#        [string]$message
#    )
#
#    $url = "https://api.telegram.org/bot$botToken/sendMessage"
#    $payload = @{
#        chat_id = $chatID
#        text = $message
#    }
#
#    try {
#        $jsonPayload = $payload | ConvertTo-Json -Depth 3
#        $response = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body $jsonPayload
#        
#        if ($response.ok -eq $true) {
#            Write-Host "✅ Message sent successfully."
#        } else {
#            Write-Host "❌ Failed to send message to Telegram."
#        }
#    }
#    catch {
#        Write-Host "⚠️ Error sending message: $_"
#    }
#}

# Send Telegram Message
function Send-TelegramMessage {
    param (
        [string]$message
    )

    # Define the log file path
    $logFilePath = "C:\tools\scripts\ServicesTelegramErrors.log"

    # Use the raw emoji characters in the message
    $url = "https://api.telegram.org/bot$botToken/sendMessage"
    $payload = @{
        chat_id = $chatID
        text = $message
    }

    try {
        # Convert to JSON, ensuring encoding is preserved
        $jsonPayload = $payload | ConvertTo-Json -Depth 3 -Compress

        # Send the message with the correct UTF-8 encoding
        $response = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body $jsonPayload
        
        if ($response.ok -eq $true) {
            Write-Host "✅ Message sent successfully."
        } else {
            # Log the failed message
            $errorMessage = "❌ Failed to send message at $(Get-Date): $message`nResponse: $($response | ConvertTo-Json -Depth 3)"
            Add-Content -Path $logFilePath -Value $errorMessage
            Write-Host $errorMessage
        }
    }
    catch {
        # Log the exception and the failed message
        $errorMessage = "⚠️ Error sending message at $(Get-Date): $message`nException: $_"
        Add-Content -Path $logFilePath -Value $errorMessage
        Write-Host $errorMessage
    }
}


# Function to check the status of services on each server
function CheckServices {
    foreach ($server in $serversToMonitor.Keys) {
        $servicesToMonitor = $serversToMonitor[$server]

        if (-not $serviceStates.ContainsKey($server)) {
            $serviceStates[$server] = @{}
        }

        foreach ($serviceName in $servicesToMonitor) {
            try {
                $service = Invoke-Command -ComputerName $server -ScriptBlock { 
                    param($serviceName) 
                    Get-Service -Name $serviceName -ErrorAction SilentlyContinue 
                } -ArgumentList $serviceName

                if ($null -eq $service) {
                    if ($serviceStates[$server][$serviceName] -ne 'Not Found') {
                        Send-TelegramMessage "⚠️ ALERT: '$serviceName' not found on '$server'."
                    }
                    $serviceStates[$server][$serviceName] = 'Not Found'
                }
                elseif ($service.Status -ne 'Running') {
                    if ($serviceStates[$server][$serviceName] -ne 'Stopped') {
                        $serviceStates[$server][$serviceName] = 'Stopped'
                        Send-TelegramMessage "❌ ALERT: '$serviceName' on '$server' is DOWN."
                    }
                }
                else {
                    if ($serviceStates[$server][$serviceName] -eq 'Stopped') {
                        $serviceStates[$server][$serviceName] = 'Running'
                        Send-TelegramMessage "✅ ALERT: '$serviceName' on '$server' is Running again."
                    }
                    elseif ($null -eq $serviceStates[$server][$serviceName]) {
                        $serviceStates[$server][$serviceName] = 'Running'
                    }
                }
            }
            catch {
                Send-TelegramMessage "❌ ERROR: Unable to connect to server '$server' or get status of service '$serviceName'. Error: $_"
            }
        }
    }
}

# Function to generate and send a periodic status report
function Send-StatusReport {
    $statusReport = "📝 Service Status Report for all servers:`n"
    foreach ($server in $serversToMonitor.Keys) {
        $statusReport += "Server: $server`n"
        $servicesToMonitor = $serversToMonitor[$server]

        foreach ($serviceName in $servicesToMonitor) {
            $status = if ($serviceStates[$server][$serviceName]) { 
                $serviceStates[$server][$serviceName] 
            } else { 
                "Unknown" 
            }

            # Add ✅ or ❌ depending on the status
            $statusIcon = switch ($status) {
                'Running'   { '✅' }
                'Stopped'   { '❌' }
                'Not Found' { '⚠️' }
                default     { '❓' } # If the status is unknown, use a question mark emoji
            }

            # Append the server, service, and status with emoji
            $statusReport += "`t- ${statusIcon} ${serviceName}: $status`n"
        }
        $statusReport += "`n"
    }
    Send-TelegramMessage $statusReport
}

# Main loop to check the services periodically
while ($true) {
    CheckServices

    $currentTime = (Get-Date).ToString("HH:mm")

    # Send the report only if it's at a specified report time and not already sent in this minute
    if ($reportTimes -contains $currentTime -and $lastReportTime -ne $currentTime) {
        Send-StatusReport
        $lastReportTime = $currentTime
    }

    Start-Sleep -Seconds $checkInterval
}
