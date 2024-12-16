# Purpose of the script: To capture and inspect AIX and Linux service account expiry details and send details of those expiring to New Relic 
# Author: Alvin Atendido

# Define constants
$currentDate = (Get-Date).ToString('yyyyMMdd')
$currentDateObj = Get-Date
$workingDir = 'C:\Program Files\New Relic\newrelic-infra\integrations.d'
$sourceFileDir = 'C:\Program Files\New Relic\newrelic-infra\integrations.d'
$csvPath1 = "$sourceFileDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}.csv"
$csvPath2 = "$sourceFileDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}_part2.csv"
#$outputPath = "$workingDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}_combined.csv" # to save combined part 1 and part 2 files data into, but not used by the script for now
$eventType = "AIXLinuxSvcAcct" # name of the New Relic table that will contain the cert data gathered by this script
$eventTypeTest = "AIXLinuxSvcAcctTestOnly"
$nrPreprodAcctId = "1737703"
$nrProdAcctId = "1737705"
$URL = "https://insights-collector.newrelic.com/v1/accounts/$nrEnv/events" # URL of the New Relic Event API endpoint
$logFilePath = "$workingDir\Logs" # path to where $logFileName will be saved
$errorFilePath = "$workingDir\Logs" # path to where $errorFileName will be saved
$logFileName = "$logFilePath\$([System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)).$(Get-Date -Format 'yyyyMMddHHmm').log" # name of the file to contain New Relic response (+ other things but later)
$errorFileName = "$errorFilePath\$([System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)).$(Get-Date -Format 'yyyyMMddHHmm').err" # name of the file to contain request error (+ other things but later)
$scriptName = [System.IO.Path]::GetFileName($PSCommandPath) # name of this script
$task1Name = "Maxage Report"
$task2Name = "Maxage report pt.2"

# Function to send data to New Relic
function Send-AcctDetailsToNewRelic {
    param (
        [hashtable]$acctDetails
    )

    $jsonData = $acctDetails | ConvertTo-Json
    #Write-Host "JSON data: $jsonData" # debug script

    try {
        # Define headers as a dictionary
        $headers = @{
            "Content-Type" = "application/json"
            "Api-Key" = $apiKey
        }

        # Send the POST request using Invoke-RestMethod
        $response = Invoke-RestMethod -Uri $URL -Method Post -Body $jsonData -Headers $headers -Verbose # note to self: remove '-Verbose' when test is complete
        #Write-Host "response: $response" # debug script

        # Append the response from the server to a file i.e. filename of this script with current system time, located in $logFilePath
        ("Response from server for {0}: {1}" -f $acctDetails.hostName, $response) | Out-File -FilePath $logFileName -Append

    } catch {
        # Append the error message to a file i.e. filename of this script with current system time, located in $errorFilePath
        ("Error sending request for {0}: {1}" -f $acctDetails.hostName, $_) | Out-File -FilePath $errorFileName -Append
    }
}

# Function to clean and then filter CSV content
function Process-CSVContent {
    param (
        [string]$path
    )
    try {
        $content = Get-Content -Path $path
        $processedContent = $content -replace '","', '::' -replace '^\s*\"', '' -replace '\"\s*$', '' # replace comma separator with '::'and remove leading and trailing spaces
        $filteredContent = $processedContent | Where-Object { # filter out headers and other non-acct data
            $_ -notmatch '^Hostname' -and
            $_ -notmatch 'assword:' -and
            $_ -notmatch 'You are required to change your password immediately' -and
            $_ -notmatch '^\s*$' -and
            $_ -notmatch 'YOU HAVE NEW MAIL' -and
            $_ -notmatch '^\[' -and
            $_ -notmatch 'Generating list of' -and
            $_ -notmatch 'check in progress'
        }
        return $filteredContent -join "`n"
    } catch {
        $errorMessages += $_.Exception.Message
        return ''
    }
}

# Calculate validDays
function Calculate-ValidDays {
    param (
        [datetime]$lastPasswordChange,
        [int]$passwordExpiration,
        [string]$osVersion
    )

    if ($osVersion -match 'Linux|Ubuntu') {
        $expirationDate = $lastPasswordChange.AddDays($passwordExpiration)
    } elseif ($osVersion -match 'AIX') {
        $expirationDate = $lastPasswordChange.AddDays($passwordExpiration * 7)
    } else {
        return 'N/A'
    }
    return ($expirationDate - (Get-Date)).Days
}

# Change to the working directory
Set-Location -Path $workingDir

# Check if exactly one or two arguments are provided
if ($args.Count -ne 1 -and $args.Count -ne 2) {
    Write-Host "Usage: .\$scriptName <PROD|PREPROD> [test]"
    exit 1
}

# Get the argument to the script, initialize the apiKey, check if apiKey is set
$environment = $args[0]
switch ($environment) {
    'PROD' {
        $apiKey = "cfc7194e3f49cac353913f8afc0a5379FFFFNRAL"
        $nrEnv = $nrProdAcctId
    }
    'PREPROD' {
        $apiKey = "71ba23ad8203901b5cac727f4c02c795FFFFNRAL"
        $nrEnv = $nrPreprodAcctId
    }
    default {
        Write-Host "Invalid argument. Usage: .\$scriptName <PROD|PREPROD>"
        exit 1
    }
}

if (-not $apiKey) {
    Write-Host "Error: Environment variable for $environment is not set."
    exit 1
}
#Write-Host "apiKey: $apiKey" # debug script
#Write-Host "nrEnv: $nrEnv" # debug script

# Check if the 'test' argument is provided (which will change the NR table where data will be stored)
if ($args.Count -eq 2 -and $args -eq 'test') {
    $eventType = $eventTypeTest
}
#Write-Host "eventType: $eventType" # debug script

$startTime = Get-Date # Start timer (to compute durationInSeconds)
$errorMessages = @()
$allAcctDetails = @()

try {
    $processedContent1 = Process-CSVContent -path $csvPath1
    $processedContent2 = Process-CSVContent -path $csvPath2
} catch {
    if (-not (Test-Path $csvPath1)) {
        Write-Output "The path $csvPath1 does not exist."
    } elseif (-not (Test-Path $csvPath2)) {
        Write-Output "The path $csvPath2 does not exist."
    } else {
        Write-Output "Something happened, exiting the script: $_"
    }
    exit 1
}

$combinedContent = $processedContent1 + "`n" + $processedContent2
$lines = $combinedContent -split "`n";# $lines | Out-File -FilePath $outputPath -Encoding UTF8
#Write-Host "lines: $lines" # debug script
Write-Host "lines.Length: $($lines.Length)" # debug script

# Get Last Result (exit code) and Last Run Time of Windows Scheduler tasks that produces the 2 service account expiry files
$lastResultTask1 = ""
$lastRunTimeTask1 = ""
$schTask1Details = schtasks /query /fo LIST /v /tn $task1Name
$lastResultTask1 = ($schTask1Details | Select-String -Pattern "Last Result:") -split ":\s+" | Select-Object -Last 1
$lastRunTimeTask1 = ($schTask1Details | Select-String -Pattern "Last Run Time:") -split ":\s+" | Select-Object -Last 1
#Write-Host "lastResultTask1: $lastResultTask1" # debug script
#Write-Host "lastRunTimeTask1: $lastRunTimeTask1" # debug script

$lastResultTask2 = ""
$lastRunTimeTask2 = ""
$schTask2Details = schtasks /query /fo LIST /v /tn $task2Name
$lastResultTask2 = ($schTask2Details | Select-String -Pattern "Last Result:") -split ":\s+" | Select-Object -Last 1
$lastRunTimeTask2 = ($schTask2Details | Select-String -Pattern "Last Run Time:") -split ":\s+" | Select-Object -Last 1
#Write-Host "lastResultTask2: $lastResultTask2" # debug script
#Write-Host "lastRunTimeTask2: (Get-Date $lastRunTimeTask2).ToString("yyyy-MM-dd")" # debug script

# Check each line of the max age data and filter out non-data and non-expiring accounts
$dataLines = $lines[0..($($lines.Length) - 1)] | ForEach-Object {
    $fields = $_ -split '::'
    $hostName = $fields[0]
    $accountStatus = $fields[11]
    $osVersion = $fields[8]
    $passwordExpiration = [int]$($fields[3]).Trim()
    $lastPasswordChangeStr = $fields[4]

    # Skip lines based on the conditions
    # Skip if not active
    # Skip if non-expiring
    # Skip if not 365 or 52

    if (($accountStatus -notlike '*Active*') -or ($passwordExpiration -eq -1 -or $passwordExpiration -eq 99999) -or ($lastPasswordChangeStr -like '*-never-*') -or 
        (($osVersion -like '*Linux*' -or $osVersion -like '*Ubuntu*') -and $passwordExpiration -ne 365) -or 
        ($osVersion -like '*AIX*' -and $passwordExpiration -ne 52)) {
        #Write-Host "Skipping this line: $fields"
        return
    }

    # Parse the lastPasswordChange date string to a DateTime object
    try {
        $lastPasswordChangeDate = [datetime]::ParseExact($($fields[4]), "d-MMM-yyyy", $null)
        #Write-Host "Parsed last password change date: $lastPasswordChangeDate"
    } catch {
        Write-Host "Error parsing last password change date: $lastPasswordChangeDate"
    }
    #Write-Host "lastPasswordChangeDate: $lastPasswordChangeDate" # debug script

    # Ensure passwordExpiration is an integer
    try {
        $passwordExpiration = [int]$fields[3].Trim()
        #Write-Host "Parsed password expiration: $passwordExpiration"
    } catch {
        Write-Host "Error parsing password expiration: $_"
    }
    #Write-Host "passwordExpiration: $passwordExpiration" # debug script

    # Calculate the valid days
    $validDays = Calculate-ValidDays -lastPasswordChange $lastPasswordChangeDate -passwordExpiration $passwordExpiration -osVersion $($fields[8])
    #Write-Host "validDays: $validDays" # debug script

    if ($validDays -gt 90) {  # Skip lines where validDays is greater than 90
        #Write-Host "Skipping $validDays of $hostName..."
        return
    }

    switch ($validDays) {
        { $_ -gt 30 -and $_ -le 90 } { $expiryType = 'Service account expiring in 30 to 90 days'; break }
        { $_ -gt 7 -and $_ -le 30 } { $expiryType = 'Service account expiring in 7 to 30 days'; break }
        { $_ -ge 0 -and $_ -le 7 } { $expiryType = 'Service account expiring  in 0 to 7 days'; break }
        default { return }
    }

    $endTime = Get-Date # End the timer for this account
    $durationInSeconds = ($endTime - $startTime).TotalSeconds

    $acctDetails = @{
        eventType = $eventType
        hostName = $fields[0]
        ipAddress = $fields[1]
        userId = $fields[2]
        passwordExpiration = $fields[3]
        lastPasswordChange = [datetime]::ParseExact($fields[4], "d-MMM-yyyy", $null).ToString("yyyy-MM-dd")
        accountDesc = $fields[6]
        osVersion = $osVersion
        lastResultTask1 = $lastResultTask1
        lastRunTimeTask1 = (Get-Date $lastRunTimeTask1).ToString("yyyy-MM-dd")
        lastResultTask2 = $lastResultTask2
        lastRunTimeTask2 = (Get-Date $lastRunTimeTask2).ToString("yyyy-MM-dd")
        validDays = $validDays.ToString() # computed value
        expiryType = $expiryType # computed value
        scriptName = $scriptName # computed value
        durationInSeconds = $durationInSeconds # computed value
    }
    <#
    Write-Host "======"
    foreach ($key in $acctDetails.Keys) {
        Write-Host "$($key): $($acctDetails[$($key)])"
    }
    Write-Host "======"
    #>
    
    # Add the account details to the outer array
    $allAcctDetails += $acctDetails
}

Write-Host "TOTAL LINES TO SEND IS: $($allAcctDetails.Length)"

# Send each account detail to New Relic if there are
if ($allAcctDetails -eq $null -or $allAcctDetails.Count -eq 0) {
    $endTime = Get-Date # End the timer for this account
    $durationInSeconds = ($endTime - $startTime).TotalSeconds

    $acctDetails = @{
        eventType = $eventType
        hostName = "None"
        ipAddress = "N/A"
        userId = "N/A"
        passwordExpiration = "N/A"
        lastPasswordChange = "N/A"
        osVersion = "N/A"
        accountDesc = "N/A"
        lastResultTask1 = $lastResultTask1
        lastRunTimeTask1 = (Get-Date $lastRunTimeTask1).ToString("yyyy-MM-dd")
        lastResultTask2 = $lastResultTask2
        lastRunTimeTask2 = (Get-Date $lastRunTimeTask2).ToString("yyyy-MM-dd")
        validDays = "N/A"
        expiryType = "No service accounts expiring in 90 days"
        scriptName = $scriptName
        durationInSeconds = $durationInSeconds
    }

    Send-AcctDetailsToNewRelic -acctDetails $acctDetails

} else {
    foreach ($acctDetails in $allAcctDetails) {
        Send-AcctDetailsToNewRelic -acctDetails $acctDetails
    }
}