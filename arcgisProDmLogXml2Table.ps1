# This script creates a table in SQL Server and populates it from the file written by 
# ArcGIS Pro's diagnostic monitor.  Since the root element of the file is not always terminated,
# this script will detect that condition and correct it.
# Before running the script, update the variables at the beginning of the file

# "C:\Program Files\PowerShell\7\pwsh.exe" arcgisProDmLogXml2Table.ps1

$XmlFilePath = "C:\temp\ArcGISProLog-84660~382879A7-F332-47FF-B1DE-63CE2089DF5B.xml"
$ConnectionString = "Server=localhost;Database=Testing;Trusted_Connection=true;"
$TableName = "ArcgisProDmLog"

# Import required modules
#Import-Module SqlServer -ErrorAction SilentlyContinue

# Function to build connection string if not provided
# function Get-ConnectionString {
    # param($Server, $Database)
    
    # if ($ConnectionString) {
        # return $ConnectionString
    # }
    
    # return "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
# }

# Function to execute SQL command
# function Invoke-SqlCommand {
    # param($Query, $ConnString)
    
    # try {
        # $connection = New-Object System.Data.SqlClient.SqlConnection($ConnString)
        # $connection.Open()
        
        # $command = New-Object System.Data.SqlClient.SqlCommand($Query, $connection)
        # $command.ExecuteNonQuery()
        
        # $connection.Close()
        # Write-Host "SQL command executed successfully" -ForegroundColor Green
    # }
    # catch {
        # Write-Error "Error executing SQL command: $_"
        # throw
    # }
# }

function Replace-LineBreaks {
    <#
    .SYNOPSIS
    Replaces line breaks (LF, CR, or CRLF) in a string with a single space.
    
    .DESCRIPTION
    This function takes a text string and replaces any linefeed (LF), carriage return (CR), 
    or carriage return + linefeed (CRLF) combinations with a single space character.
    
    .PARAMETER InputString
    The text string to process
    
    .EXAMPLE
    Replace-LineBreaks "Line 1`nLine 2`r`nLine 3"
    Returns: "Line 1 Line 2 Line 3"
    
    .EXAMPLE
    "Multi`rLine`nText" | Replace-LineBreaks
    Returns: "Multi Line Text"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$InputString
    )
    
    process {
        # Replace CRLF, CR, and LF with a single space
        # Using -replace with regex pattern that matches any combination
        return $InputString -replace '[\r\n]+', ' '
    }
}


# Function to safely escape SQL values
# Makes use of Replace-LineBreaks function
function Get-SqlValue {
    param($Value)
    
    if ($null -eq $Value -or $Value -eq "") {
        return "NULL"
    }
    $modifiedValue = Replace-LineBreaks $Value 
    # Escape single quotes and wrap in quotes
    $escapedValue = $modifiedValue.ToString().Replace("'", "''")
	
	
    return "'$escapedValue'"
}

# Main script execution
try {
    Write-Host "Starting XML to SQL Server import process..." -ForegroundColor Cyan
    
    # Validate XML file exists
    if (-not (Test-Path $XmlFilePath)) {
        throw "XML file not found: $XmlFilePath"
    }
    
    # Load and parse XML
	try
	{
		Write-Host "Loading XML file: $XmlFilePath" -ForegroundColor Yellow
		[xml]$xmlContent = Get-Content $XmlFilePath
    }
	catch 
	{
		if ($_.Exception.Message.Contains("The following elements are not closed: EventLog"))
		{
			# terminate the root element in a way that will allow the script to continue on (Add-Content isn't always completed synchronously)
			"</EventLog>" | Out-File -FilePath $XmlFilePath -Append -Force
			
			Write-Host "XML file not properly terminated.  Added termination and trying again..." -ForegroundColor Yellow
			[xml]$xmlContent = Get-Content $XmlFilePath			
		}
		throw
	}
	
    # Get all Event elements
    $events = $xmlContent.EventLog.Event
    Write-Host "Found $($events.Count) event(s) in XML file" -ForegroundColor Yellow
    
    # Analyze all events to determine all possible columns
    Write-Host "Analyzing event structure to determine table schema..." -ForegroundColor Yellow
    $allColumns = @{}
    
    foreach ($event in $events) {
        # Add attributes as columns
        foreach ($attr in $event.Attributes) {
			$columnName = "[" + $attr.Name + "]"
            #$allColumns[$attr.Name] = "NVARCHAR(MAX)"
			$allColumns[$columnName] = "NVARCHAR(MAX)"
        }
        
        # Add inner text as RequestURL column if it exists and contains URL
        if ($event.InnerText -and $event.InnerText.Trim() -ne "") {
            $allColumns["[RequestURL]"] = "NVARCHAR(MAX)"
            $allColumns["[EventDetails]"] = "NVARCHAR(MAX)"
        }
    }
    
    # Connect to RDBMS
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Connection.Open()
    Write-Host "Connected to SQL Server successfully" -ForegroundColor Green
    
    # Drop existing table
	$dropQuery = "IF OBJECT_ID('$TableName', 'U') IS NOT NULL DROP TABLE $TableName"
    $Command = New-Object System.Data.SqlClient.SqlCommand($dropQuery, $Connection)
	$Command.ExecuteNonQuery()
    
    # Create table with all discovered columns
    Write-Host "Creating table: $TableName" -ForegroundColor Yellow
    $createTableQuery = @"
IF OBJECT_ID('$TableName', 'U') IS NULL
BEGIN
    CREATE TABLE $TableName (
        EventID INT IDENTITY(1,1) PRIMARY KEY,
        $(($allColumns.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ",`n        ")
    )
END
"@
	$Command = New-Object System.Data.SqlClient.SqlCommand($createTableQuery, $Connection)
	$Command.ExecuteNonQuery()
    Write-Host "Table (re)-Created" -ForegroundColor Green
	
    # Insert data
    Write-Host "Inserting event data..." -ForegroundColor Yellow
    $insertedCount = 0
    
    foreach ($event in $events) {
        # Prepare column values
        $columnValues = @{}
        
        # Process attributes
        foreach ($attr in $event.Attributes) {
			$columnName = "[" + $attr.Name + "]"
            #$columnValues[$attr.Name] = Get-SqlValue -Value $attr.Value
			$columnValues[$columnName] = Get-SqlValue -Value $attr.Value
        }
        
        # Process inner text for URL extraction
        if ($event.InnerText -and $event.InnerText.Trim() -ne "") {
            $innerText = $event.InnerText.Trim()
            
            # Try to extract URL from the text
            $urlMatch = [regex]::Match($innerText, 'Request URL:\s*(https?://[^\s]+)')
            if ($urlMatch.Success) {
                $columnValues["[RequestURL]"] = Get-SqlValue -Value $urlMatch.Groups[1].Value
            }
            
            # Store full event details
            $columnValues["[EventDetails]"] = Get-SqlValue -Value $innerText
        }
        
        # Ensure all columns have values (NULL if not present)
        foreach ($col in $allColumns.Keys) {
            if (-not $columnValues.ContainsKey($col)) {
                $columnValues[$col] = "NULL"
            }
        }
        
        # Build and execute insert query
        $columns = $allColumns.Keys -join ", "
        $values = ($allColumns.Keys | ForEach-Object { $columnValues[$_] }) -join ", "
        
        $insertQuery = "INSERT INTO $TableName ($columns) VALUES ($values)"
        
        try {
			$Command = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $Connection)
			#Write-Host $insertQuery -ForegroundColor Green
			$Command.ExecuteNonQuery()
            $insertedCount++
        }
        catch {
            Write-Warning "Failed to insert event: $_"
        }
    }
    
    Write-Host "Successfully inserted $insertedCount out of $($events.Count) events" -ForegroundColor Green
    
    # Display summary
    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "  Table: $TableName" -ForegroundColor White
    Write-Host "  Events processed: $($events.Count)" -ForegroundColor White
    Write-Host "  Events inserted: $insertedCount" -ForegroundColor White
 
    
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}

# Example usage:
# .\XMLToSQLParser.ps1 -XmlFilePath "C:\path\to\sample.xml" -SqlServer "localhost" -Database "MyDatabase" -TableName "EventLog" -DropExistingTable