# This script creates a table in SQL Server and populates it from the HTTP request "log" element of 
# ArcGIS Pro's diagnostic monitor that has been saved to a file.
# Before running the script, update the variables at the beginning of the file

# VARIABLES TO UPDATE
$connectionString = "Server=localhost;Database=Testing;Trusted_Connection=true;" # Connection string - modify as needed
$xmlFilePath = "C:\temp\UNS\26June\gas_un_AddandOpenHTTP.txt" # File path containing XML fragments (one per line)
$failureslog = "C:\temp\UNS\26June\gas_un_AddandOpenHTTP.log" # This file will be created and populated if there are any XML fragments that cannot be inserted into the database.
$TableName = "arcgisproHttpRequestLog_gas" # This table will be created and populated

# Function to extract attribute values from the faux-xml (there are too many weird problem with the XML to treat it as XML)
function Get-AttributeValue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputString,
        
        [Parameter(Mandatory=$true)]
        [string]$AttributeName
    )
    
    # Create regex pattern to match the attribute and its quoted value
    # Pattern explanation:
    # - $AttributeName = matches the literal attribute name followed by equals
    # - \s* = matches optional whitespace after equals
    # - " = matches opening quote
    # - ([^"]*) = captures everything that's not a quote (the value we want)
    # - " = matches closing quote
    $pattern = "$AttributeName\s*=\s*`"([^`"]*)`""
    
    # Perform the regex match
    if ($InputString -match $pattern) {
        return $matches[1]
    }
    else {
        return $null
    }
}



# Read XML fragments from file
if (Test-Path $xmlFilePath) {
    Write-Host "Reading XML fragments from: $xmlFilePath"
    $xmlFragments = Get-Content -Path $xmlFilePath | Where-Object { $_.Trim() -ne "" }
    Write-Host "Found $($xmlFragments.Count) XML fragments"
} else {
    Write-Error "File not found: $xmlFilePath"
    exit 1
}

try {
    # Create SQL connection
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    
    # Create table if it doesn't exist
    $createTableQuery = @"
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='$TableName' AND xtype='U')
    CREATE TABLE $TableName (
        ID INT IDENTITY(1,1) PRIMARY KEY,
        StartTime DATETIME2,
        Duration INT,
        Thread NVARCHAR(20),
        Status NVARCHAR(10),
        URL NVARCHAR(MAX)
    )
"@
    
    $createCommand = New-Object System.Data.SqlClient.SqlCommand($createTableQuery, $connection)
    $createCommand.ExecuteNonQuery()
    
    # Process each XML fragment
    foreach ($xmlFragment in $xmlFragments) {
        try {

            # Extract attributes
            $startTime = [DateTime]::Parse($(Get-AttributeValue -InputString $xmlFragment -AttributeName 'start'))
            $duration = [int]$(Get-AttributeValue -InputString $xmlFragment -AttributeName 'duration')
            $thread = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'thread')
            $status = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'status')
            $url = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'url')
            
            # Insert into database
            $insertQuery = @"
            INSERT INTO $TableName (StartTime, Duration, Thread, Status, URL)
            VALUES (@StartTime, @Duration, @Thread, @Status, @URL)
"@
            
            $insertCommand = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $connection)
            $insertCommand.Parameters.AddWithValue("@StartTime", $startTime)
            $insertCommand.Parameters.AddWithValue("@Duration", $duration)
            $insertCommand.Parameters.AddWithValue("@Thread", $thread)
            $insertCommand.Parameters.AddWithValue("@Status", $status)
            $insertCommand.Parameters.AddWithValue("@URL", $url)
            
            $insertCommand.ExecuteNonQuery()
            Write-Host "Inserted record for thread $thread at $startTime"
        }
        catch {
            Write-Warning "Error processing XML fragment: $($_.Exception.Message)"
            Add-Content -Path $failureslog -Value $xmlFragment
        }
    }
}
catch {
    Write-Error "Database error: $($_.Exception.Message)"
}
finally {
    if ($connection.State -eq 'Open') {
        $connection.Close()
    }
}

Write-Host "Processing complete!"
