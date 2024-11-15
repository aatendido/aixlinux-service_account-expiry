# Purpose of the script: To capture and inspect AIX and Linux service account expiry details and send details of those expiring to New Relic 
# Author: Alvin Atendido

# Define constants
$currentDate = (Get-Date).ToString('yyyyMMdd')
$currentDateObj = Get-Date
$workingDir = 'C:\Program Files\New Relic\newrelic-infra\integrations.d'
$csvPath1 = "$workingDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}.csv"
$csvPath2 = "$workingDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}_part2.csv"
$outputPath = "$workingDir\AIX_Linux_UserAcc_Check_Report_MMDDYYYY_${currentDate}_combined.csv" # to save combined part 1 and part 2 files data into, but not used by the script for now
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
$tasks = @(
    @{ Name = "Maxage Report"; Attributes = @("Last Run Time", "Last Result") }, # task in Windows Task Scheduler that creates the 1st part of data ($csvPath1)
    @{ Name = "Maxage report pt.2"; Attributes = @("Last Run Time", "Last Result") } # task in Windows Task Scheduler that creates the 2nd part of data ($csvPath2)
)

# Function to send data to New Relic
function Send-AcctDetailsToNewRelic {
    param (
        [hashtable]$acctDetails
    )

    $jsonData = $acctDetails | ConvertTo-Json
    #echo "JSON data: $jsonData" # debug script

    try {
        # Define headers as a dictionary
        $headers = @{
            "Content-Type" = "application/json"
            "Api-Key" = $apiKey
        }

        # Send the POST request using Invoke-RestMethod
        $response = Invoke-RestMethod -Uri $URL -Method Post -Body $jsonData -Headers $headers -Verbose # note to self: remove '-Verbose' when test is complete
        #echo "response: $response" # debug script

        # Append the response from the server to a file i.e. filename of this script with current system time, located in $logFilePath
        ("Response from server for {0}: {1}" -f $acctDetails.hostName, $response) | Out-File -FilePath $logFileName -Append

    } catch {
        # Append the error message to a file i.e. filename of this script with current system time, located in $errorFilePath
        ("Error sending request for {0}: {1}" -f $acctDetails.hostName, $_) | Out-File -FilePath $errorFileName -Append
    }
}

# Function to get Windows Task Scheduler task details
function Get-TaskDetails {
    param (
        [string]$taskName,
        [string[]]$attributes
    )

    $taskDetails = schtasks /query /fo LIST /v /tn $taskName
    $result = @{}

    foreach ($attribute in $attributes) {
        $line = $taskDetails | Select-String -Pattern "$($attribute):"
        $value = $line -split ":\s+" | Select-Object -Last 1
        $result[$attribute] = $value
    }

    return $result
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
            $_ -notmatch '^\s*$' 
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
        $apiKey = $env:nrProdSecret
        $nrEnv = $nrProdAcctId
    }
    'PREPROD' {
        $apiKey = $env:nrPreprodSecret
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

#echo "apiKey: $apiKey" # debug script
#echo "nrEnv: $nrEnv" # debug script

# Check if the 'test' argument is provided (which will change the NR table where data will be stored)
if ($args.Count -eq 2 -and $args -eq 'test') {
    $eventType = $eventTypeTest
}
#echo "eventType: $eventType" # debug script

$startTime = Get-Date # Start timer (to compute durationInSeconds)
$errorMessages = @()
$allAcctDetails = @()
$processedContent1 = Process-CSVContent -path $csvPath1
$processedContent2 = Process-CSVContent -path $csvPath2
$combinedContent = $processedContent1 + "`n" + $processedContent2
$lines = $combinedContent -split "`n"; $lines | Out-File -FilePath $outputPath -Encoding UTF8
#echo "lines: $lines" # debug script
#echo "lines.Length: $($lines.Length)" # debug script

# Get exit code and last run time of Windows Scheduler tasks that produces the service account expiry details
$taskDetails = ""
foreach ($task in $tasks) {
    $taskName = $task.Name
    $attributes = $task.Attributes
    $details = Get-TaskDetails -taskName $taskName -attributes $attributes

    # Append the details to the string
    foreach ($attribute in $attributes) {
        $taskDetails += "$($taskName) - $($attribute): $($details[$attribute])`n"
    }
}

# Check each line of the max age data and filter out non-data and non-expiring accounts
$dataLines = $lines[0..($($lines.Length) - 1)] | ForEach-Object {
    
    $fields = $_ -split '::'

    $hostName = $fields[0]
    Write-Host "hostName: $hostName" # debug script

    # Extract relevant fields
    $accountStatus = $fields[11]
    $osVersion = $fields[8]
    $passwordExpiration = [int]$fields[3].Trim()

    # Skip lines based on the specified condition
    if (($accountStatus -notlike '*Active*') -or 
        (($osVersion -like '*Linux*' -or $osVersion -like '*Ubuntu*') -and $passwordExpiration -ne 365) -or 
        ($osVersion -like '*AIX*' -and $passwordExpiration -ne 52)) {
        Write-Host "Skipping line due to condition: $_"
        return
    }

    # Parse the lastPasswordChange date string to a DateTime object
    try {
        $lastPasswordChangeDate = [datetime]::ParseExact($($fields[4]), "dd-MMM-yyyy", $null)
        #Write-Host "Parsed last password change date: $lastPasswordChangeDate"
    } catch {
        Write-Host "Error parsing last password change date: $_"
    }
    #echo "lastPasswordChangeDate: $lastPasswordChangeDate" # debug script

    # Ensure passwordExpiration is an integer
    try {
        $passwordExpiration = [int]$fields[3].Trim()
        #Write-Host "Parsed password expiration: $passwordExpiration"
    } catch {
        Write-Host "Error parsing password expiration: $_"
    }
    #echo "passwordExpiration: $passwordExpiration" # debug script

    # Skip lines where passwordExpiration is -1 or 99999, these are service accounts whose passwords do not expire
    if ($passwordExpiration -eq -1 -or $passwordExpiration -eq 99999) {
        Write-Host "Skipping line with passwordExpiration: $passwordExpiration"
        return
    }

    #Write-Host "fields[8]: $($fields[8])" # debug script

    # Calculate the valid days
    $validDays = Calculate-ValidDays -lastPasswordChange $lastPasswordChangeDate -passwordExpiration $passwordExpiration -osVersion $($fields[8])
    Write-Host "validDays: $validDays" # debug script

    if ($validDays -gt 90) {  # Skip lines where validDays is greater than 90
         Write-Host "Skipping $validDays of $hostName..."
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
        lastPasswordChange = $fields[4]
        osVersion = $osVersion
        validDays = $validDays.ToString() # computed value
        expiryType = $expiryType # computed value
        scriptName = $scriptName # computed value
        taskDetails = $taskDetails.ToString() # computed value
        durationInSeconds = $durationInSeconds # computed value
    }
    
    #Write-Output $acctDetails # debug script
    Write-Host "======"
    foreach ($key in $acctDetails.Keys) {
        Write-Host "$($key): $($acctDetails[$($key)])"
    }
    Write-Host "======"

    # Add the account details to the outer array
    $allAcctDetails += $acctDetails
}


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
        validDays = "N/A"
        expiryType = "No service accounts expiring in 90 days"
        scriptName = $scriptName
        taskDetails = $taskDetails
        durationInSeconds = $durationInSeconds
    }

    Send-AcctDetailsToNewRelic -acctDetails $acctDetails

} else {
    foreach ($acctDetails in $allAcctDetails) {
        Send-AcctDetailsToNewRelic -acctDetails $acctDetails
    }
}
