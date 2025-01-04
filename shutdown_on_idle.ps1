## ----------------------------------------------------------------------- ##
# Script to shut down workstations on idle and get alerted on Telegram      #
# Author      : Bairaktaris Emmanuel                                        #
# Date        : January 4, 2025                                             #
# Last version: January 4, 2025                                             #
# Link        : https://sonam.dev                                           #
## ----------------------------------------------------------------------- ##

# Set up TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID on all target machines:
# setx TELEGRAM_BOT_TOKEN "your_bot_token"
# setx TELEGRAM_CHAT_ID "your_chat_id"
## ----------------------------------------------------------------------- ##
# Ensure the PowerShell execution policy allows running scripts:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
## ----------------------------------------------------------------------- ##

# Function to calculate idle time in minutes
function Get-IdleTime {
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    public class Win32 {
        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    }
"@

    $lastInputInfo = New-Object "LASTINPUTINFO"
    $lastInputInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lastInputInfo)
    [Win32]::GetLastInputInfo([ref]$lastInputInfo) | Out-Null

    $uptime = [Environment]::TickCount
    $idleTimeMs = $uptime - $lastInputInfo.dwTime
    return [math]::Floor($idleTimeMs / 1000 / 60)
}

# Function to show the message box with a timeout
function Show-MessageBoxWithTimeout {
    param (
        [string]$message,
        [string]$title,
        [int]$timeoutSeconds
    )
    Add-Type -AssemblyName PresentationFramework

    $syncHash = [hashtable]::Synchronized(@{ Result = $null })
    
    $thread = [System.Threading.Thread]::new({
        param ($msg, $ttl, $hash)
        $hash.Result = [System.Windows.MessageBox]::Show(
            $msg, $ttl,
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Warning
        )
    }, $message, $title, $syncHash)
    
    $thread.IsBackground = $true
    $thread.Start()

    Start-Sleep -Seconds $timeoutSeconds
    if (-not $syncHash.Result) {
        # No response from user, simulate a "no" response
        $syncHash.Result = [System.Windows.MessageBoxResult]::None
    }
    $thread.Abort()
    return $syncHash.Result
}

# Function to check if specific processes are running
function CheckRunningProcesses {
    param (
        [array]$excludedProcesses
    )
    foreach ($process in $excludedProcesses) {
        $runningProcess = Get-Process | Where-Object { $_.Name -eq $process }
        if ($runningProcess) {
            return $true
        }
    }
    return $false
}

# Function to send a Telegram notification
function Send-TelegramMessage {
    param (
        [string]$BotToken,
        [string]$ChatID,
        [string]$Message
    )
    $TelegramURL = "https://api.telegram.org/bot$BotToken/sendMessage"
    $Payload = @{
        chat_id = $ChatID
        text = $Message
    }

    try {
        Invoke-RestMethod -Uri $TelegramURL -Method Post -ContentType "application/json" -Body ($Payload | ConvertTo-Json -Depth 10)
        Write-Host "Telegram message sent successfully."
    } catch {
        Write-Host "Failed to send Telegram message: $($_.Exception.Message)"
    }
}

# Idle threshold in minutes
$Threshold = 120 # Replace with your desired idle time in minutes

# List of processes to exclude from idle check (e.g., Veeam Backup)
$excludedProcesses = @("VeeamAgent", "VeeamBackupService")

# Telegram bot details
$BotToken = $env:TELEGRAM_BOT_TOKEN                           # Replace with your environment variable name
$ChatID = $env:TELEGRAM_CHAT_ID                               # Replace with your environment variable name

# Continuous monitoring loop
while ($true) {
    # Check if any excluded processes are running
    if (CheckRunningProcesses -excludedProcesses $excludedProcesses) {
        Write-Host "A backup or scheduled task is running. Skipping idle check."
    } else {
        $IdleTime = Get-IdleTime
        if ($IdleTime -ge $Threshold) {
            Write-Host "System has been idle for $IdleTime minutes. Preparing to shut down."

            # Custom message for the user
            $customMessage = @"
Your computer has been idle for $IdleTime minutes, exceeding the allowed threshold of $Threshold minutes.

The system will shut down in 30 seconds unless you click "Cancel."

To avoid this in the future:
- Keep working on your system. :)

Thank you! The IT Team.
"@
            $title = "Idle Shutdown Warning"
            $timeoutSeconds = 30 # Timeout in seconds

            # Send Telegram notification
            $TelegramMessage = "Warning: PC is idle and will shut down at $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')."
            Send-TelegramMessage -BotToken $BotToken -ChatID $ChatID -Message $TelegramMessage

            # Show the message box with a timeout
            $userResponse = Show-MessageBoxWithTimeout -message $customMessage -title $title -timeoutSeconds $timeoutSeconds

            # Handle the user's response
            if ($userResponse -eq [System.Windows.MessageBoxResult]::Cancel) {
                Write-Host "Shutdown canceled by the user."
            } elseif ($userResponse -eq [System.Windows.MessageBoxResult]::None) {
                Write-Host "Timeout reached. Proceeding with shutdown."
                Stop-Computer -Force
            } else {
                Write-Host "User confirmed. Shutting down."
                Stop-Computer -Force
            }
            break
        } else {
            Write-Host "System has been idle for $IdleTime minutes. No action taken."
        }
    }

    # Wait 1 minute before checking again
    Start-Sleep -Seconds 60
}
