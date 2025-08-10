# This script creates a table in SQL Server and populates it from the files written by 
# ArcGIS Pro's diagnostic monitor.  Since the root element of the file is not always terminated,
# this script will detect that condition and correct it.
# Before running the script, update the variables at the beginning of the file

# "C:\Program Files\PowerShell\7\pwsh.exe" arcgisProDmLogXml2TableBatch.ps1


$DirectoryOfXmlFiles = "C:\temp\UNS\6Aug\DmFiles"
$ConnectionString = "Server=localhost;Database=Testing;Trusted_Connection=true;"
$TableName = "ArcgisProDmLogFiles"


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

function Add-Table {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$files,

        [Parameter(Mandatory = $true)]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

	# get the XML of the first file
    $firstFile = $files[0]	
	[xml]$xmlContent = Get-Content $firstFile

    # Get all Event elements
    $events = $xmlContent.EventLog.Event
    #Write-Host "Found $($events.Count) event(s) in XML file" -ForegroundColor Yellow
    
    # Analyze all events to determine all possible columns
    #Write-Host "Analyzing event structure to determine table schema..." -ForegroundColor Yellow
    $allColumns = @{}
    
    foreach ($event in $events) {
        # Add attributes as columns
        foreach ($attr in $event.Attributes) {
			$columnName = "[" + $attr.Name + "]"
            #$allColumns[$attr.Name] = "NVARCHAR(MAX)"
			if ($attr.Name -eq "time")
			{
				$allColumns[$columnName] = "DATETIME2"
			}
			elseif ($attr.Name -eq "elapsed")
			{
				$allColumns[$columnName] = "BIGINT"
			}
			else 
			{
				$allColumns[$columnName] = "NVARCHAR(MAX)"
			}
        }
        
        # Add inner text as RequestURL column if it exists and contains URL
        if ($event.InnerText -and $event.InnerText.Trim() -ne "") {
            $allColumns["[RequestURL]"] = "NVARCHAR(MAX)"
            $allColumns["[EventDetails]"] = "NVARCHAR(MAX)"
        }
    }
	# add a column to hold the name of the file
	$allColumns["[FileName]"] = "NVARCHAR(MAX)"
    
    # Connect to RDBMS
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Connection.Open()
    Write-Host "Connected to SQL Server successfully to create table" -ForegroundColor Green
    
    # Drop existing table
	$dropQuery = "IF OBJECT_ID('$TableName', 'U') IS NOT NULL DROP TABLE $TableName"
    $Command = New-Object System.Data.SqlClient.SqlCommand($dropQuery, $Connection)
	$Command.ExecuteNonQuery() | Out-Null
    
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
	$Command.ExecuteNonQuery() | Out-Null
	
	$Connection.Close() 
	Write-Host "Closed SQL Server connection after creating table." -ForegroundColor Green

	return $allColumns 
}

function Add-EventLogClosingTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath,
        
        [Parameter(Mandatory = $false)]
        [string]$FileFilter = "*.*",
        
        [Parameter(Mandatory = $false)]
        [switch]$Recurse
        

    )
    
    # Verify the directory exists
    if (-not (Test-Path -Path $DirectoryPath -PathType Container)) {
        Write-Error "Directory '$DirectoryPath' does not exist."
        return
    }
    
    # Get all files in the directory
    $getChildItemParams = @{
        Path = $DirectoryPath
        Filter = $FileFilter
        File = $true
    }
    
    if ($Recurse) {
        $getChildItemParams.Recurse = $true
    }
    
    $files = Get-ChildItem @getChildItemParams
    
    if ($files.Count -eq 0) {
        Write-Host "No files found in directory '$DirectoryPath' with filter '$FileFilter'." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Processing $($files.Count) file(s)..." -ForegroundColor Green
    
    foreach ($file in $files) {
        try {
            # Read the file content
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            
            # Check if content is null or empty
            if ([string]::IsNullOrEmpty($content)) {
                Write-Warning "File '$($file.Name)' is empty. Skipping..."
                continue
            }
            
            # Trim whitespace from the end to check the actual ending
            $trimmedContent = $content.TrimEnd()
            
            # Check if it already ends with "</EventLog>"
            if ($trimmedContent.EndsWith("</EventLog>")) {
                #Write-Host "✓ File '$($file.Name)' already ends with '</EventLog>'. No changes needed." -ForegroundColor Green
                continue
            }
            
            # Add the closing tag
            $newContent = $trimmedContent + "`n</EventLog>"
            
            # Write the updated content back to the file
            Set-Content -Path $file.FullName -Value $newContent -NoNewline -ErrorAction Stop
            #Write-Host "✓ Added '</EventLog>' to file '$($file.Name)'" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to process file '$($file.Name)': $($_.Exception.Message)"
        }
    }
	
	return $files
}

function ConvertTo-DateTime {
    <#
    .SYNOPSIS
    Converts a date string in format "Tue Aug 05 14:41:41.943" to a DateTime object for the current year.
    
    .DESCRIPTION
    This function parses a date string that contains day of week, month abbreviation, day, 
    and time with milliseconds, assuming the current year.
    
    .PARAMETER DateString
    The date string to convert in format "Tue Aug 05 14:41:41.943"
    
    .EXAMPLE
    ConvertTo-DateTime "Wed Aug 06 1:50:57.708"
    Returns: Wednesday, August 6, 2025 1:50:57 AM
    
    .EXAMPLE
    "Wed Dec 25 09:30:15.123" | ConvertTo-DateTime
    Returns: Wednesday, December 25, 2025 9:30:15 AM
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$DateString
    )
    
    process {
        try {
            # Get the current year
            $currentYear = (Get-Date).Year
            
            # Remove the day of week (first part before first space)
            $dateWithoutDayOfWeek = $DateString -replace '^[A-Za-z]{3}\s+', ''
            
            # Add the current year to the beginning of the string
            $dateStringWithYear = "$currentYear $dateWithoutDayOfWeek"
            
            # Try parsing with both single-digit and double-digit hour formats
            $formats = @(
                'yyyy MMM dd H:mm:ss.fff',   # Single-digit hour (1:50:57.708)
                'yyyy MMM dd HH:mm:ss.fff'   # Double-digit hour (01:50:57.708)
            )
            
            $dateTime = $null
            foreach ($format in $formats) {
                try {
                    $dateTime = [DateTime]::ParseExact(
                        $dateStringWithYear,
                        $format,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    break
                }
                catch {
                    # Continue to next format if this one fails
                    continue
                }
            }
            
            if ($null -eq $dateTime) {
                throw "Unable to parse with any supported format"
            }
            
            return $dateTime
        }
        catch {
            Write-Error "Failed to parse date string '$DateString'. Expected format: 'Tue Aug 05 14:41:41.943'. Error: $($_.Exception.Message)"
            return $null
        }
    }
}

function Add_FilesContentsToTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$files,

        [Parameter(Mandatory = $true)]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [string]$TableName,	

        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$allColumns
		
    )	
	
	# Connect to RDBMS
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Connection.Open()
    Write-Host "Connected to SQL Server successfully to load data" -ForegroundColor Green
	
	$insertedFilesCount = 0 
	$failedFilesCount = 0
	foreach ($file in $files)
	{
		try
		{
			# Get the XML events
			[xml]$xmlContent = Get-Content $file
			$events = $xmlContent.EventLog.Event
			
			# insert Events
			$insertedCount = 0
			$failedCount = 0
			
			#$allColumns = @{}
			
			
			foreach ($event in $events) {
				# Prepare column values
				$columnValues = @{}
				
				# Process attributes
				foreach ($attr in $event.Attributes) {
					
					
					# The datetime information in the XML is weird
					# This unweirdifies it
					if ($attr.Name -eq "time")
					{
						$v = ConvertTo-DateTime -DateString $attr.Value
						$value =  Get-SqlValue -Value $v 
					}
					else
					{
						$value = Get-SqlValue -Value $attr.Value
					}
					
					$columnName = "[" + $attr.Name + "]"
					$columnValues[$columnName] = $value
				}
				#Write-Host "Processed attributes for $file for event $insertedCount"
				
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
				# set FileName value to that column
				$columnValues["[FileName]"] = "'$file'"
				
				#Write-Host "Processed innertext for $file for event $insertedCount"
				
				
				# Ensure all columns have values (NULL if not present)
				foreach ($col in $allColumns.Keys) {
					if (-not $columnValues.ContainsKey($col)) {
						$columnValues[$col] = "NULL"
					}
				}
				
				#Write-Host "Set nulls for $file for event $insertedCount"
				$colCnt = $allColumns.Keys.Count

				# Build and execute insert query
				$columns = $allColumns.Keys -join ", "
				#Write-Host "Joined columns for $file for event $insertedCount"
				#Write-Host "Columns: $columns"
				$values = ($allColumns.Keys | ForEach-Object { $columnValues[$_] }) -join ", "
				#Write-Host "Joined values for $file for event $insertedCount"
				
				$insertQuery = "INSERT INTO $TableName ($columns) VALUES ($values)"
				#Write-Host "Insert query for $file is:  $insertQuery"
				
				try {
					$Command = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $Connection)
					#Write-Host $insertQuery -ForegroundColor Green
					$Command.ExecuteNonQuery() | Out-Null 
					$insertedCount++
				}
				catch {
					$failedCount++
					Write-Warning "Failed to insert event: $_"
				}
			} #foreach event				
			Write-Host "$insertedCount events inserted and $failedCount events failed to insert for file $file" 
			$insertedFilesCount++
		}
		catch
		{
			Write-Warning "Failed to process file $file with exception: $_"
			$failedFilesCount++
		}
	} #foreach file
	
	Write-Host "$insertedFilesCount files processed and $failedFilesCount files failed to process"
	
	$Connection.Close() 
	Write-Host "Closed SQL Server connection after loading data." -ForegroundColor Green

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

Write-Host "Pre-process files to make sure the XML is properly terminated (the files don't seem properly terminated by default) ..."
$files = Add-EventLogClosingTag -DirectoryPath $DirectoryOfXmlFiles -FileFilter "*.xml"
Write-Host "Pre-processing complete."  -ForegroundColor Green
Write-Host "Ensure we have an empty table with the correct schema ..."
$allColumns = Add-Table -files $files -ConnectionString $ConnectionString -TableName $TableName
Write-Host "Table (re)-Created" -ForegroundColor Green
Write-Host "Loading files' content into table ..."
Add_FilesContentsToTable -files $files -ConnectionString $ConnectionString -TableName $TableName -allColumns $allColumns 
Write-Host "All processing complete." -ForegroundColor Green

exit 

