# This script creates a table in SQL Server and populates it from the Event "log" element of 
# ArcGIS Pro's diagnostic monitor that has been coppied and saved to a file.
# Before running the script, update the variables at the beginning of the file

# VARIABLES TO UPDATE
$XmlFilePath = "C:\temp\UNS\26June\gas_un_AddandOpenLOG.txt" # File path of the Diagnostic Monitor Event output
$failureslog = "C:\temp\UNS\26June\gas_un_AddandOpenLOG.log" # This file will be created and populated if there are any XML fragments that cannot be inserted into the database.
$ConnectionString = "Server=localhost;Database=Testing;Trusted_Connection=true;" # SQL Server database connection
$TableName = 'arcgisproEventLog_gas' # Table to create and populate


# Function to extract attribute values from the faux-xml (there are too many weird problems with the XML to treat it as XML)
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

# Function to extract the text value of the faux-xml (there are too many weird problems with the XML to treat it as XML)
function Extract-EventText {
    <#
    .SYNOPSIS
        Extracts the Event Text content from XML Event elements using string processing.
    
    .DESCRIPTION
        This function uses regular expressions to extract the text content between 
        <Event> opening and closing tags without using XML parsing libraries.
        It handles malformed XML and extracts the inner text content.
    
    .PARAMETER XmlFragment
        The XML fragment containing the Event element(s).
    
    .PARAMETER TrimWhitespace
        Optional switch to trim leading/trailing whitespace from the extracted text.
        Default is $true.
    
    .PARAMETER NormalizeLineBreaks
        Optional switch to normalize line breaks to consistent format.
        Default is $true.
    
    .EXAMPLE
        $xml = @"
        <Event time="Tue Jun 24 11:28:49.999" type="Debug">
        Request URL: https://example.com
              Setting up request...
              Success
        </Event>
        "@
        
        Extract-EventText -XmlFragment $xml
        
        # Returns the cleaned text content between the Event tags
    
    .EXAMPLE
        # Process multiple Event elements
        $multipleEvents = Get-Content "events.xml" -Raw
        Extract-EventText -XmlFragment $multipleEvents
    
    .OUTPUTS
        System.String[] - Array of extracted event text content.  No event text will be returned as this string " "
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$XmlFragment,
        
        [Parameter(Mandatory = $false)]
        [bool]$TrimWhitespace = $true,
        
        [Parameter(Mandatory = $false)]
        [bool]$NormalizeLineBreaks = $true
    )
    
    begin {
        Write-Verbose "Starting Event Text extraction"
    }
    
    process {
        try {
            # Regular expression to match Event elements and capture their content
            # This pattern handles:
            # - Opening <Event> tag with any attributes
            # - Content between tags (including newlines)
            # - Closing </Event> tag
            $eventPattern = '(?s)<Event\s+[^>]*>(.*?)</Event>'
            
            # Find all matches
            $matches = [regex]::Matches($XmlFragment, $eventPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            
            if ($matches.Count -eq 0) {
                Write-Warning "No Event elements found in the provided XML fragment"
                #return @()
                return " "
            }
            
            $extractedTexts = @()
            
            foreach ($match in $matches) {
                # Get the captured group (content between tags)
                $eventText = $match.Groups[1].Value
                
                if ($TrimWhitespace) {
                    # Remove leading and trailing whitespace
                    $eventText = $eventText.Trim()
                }
                
                if ($NormalizeLineBreaks) {
                    # Normalize line breaks to consistent format
                    $eventText = $eventText -replace '\r\n', "`n"
                    $eventText = $eventText -replace '\r', "`n"
                    
                    # Remove excessive blank lines (more than 2 consecutive)
                    $eventText = $eventText -replace '\n{3,}', "`n`n"
                }
                
                # Additional cleanup: remove excessive leading spaces from each line
                $lines = $eventText -split '\n'
                $cleanedLines = @()
                
                foreach ($line in $lines) {
                    # Trim each line but preserve intentional indentation structure
                    $trimmedLine = $line.TrimEnd()
                    $cleanedLines += $trimmedLine
                }
                
                $cleanedText = $cleanedLines -join "`n"
                
                if ($TrimWhitespace) {
                    $cleanedText = $cleanedText.Trim()
                }
                
                if (-not [string]::IsNullOrEmpty($cleanedText)) {
                    $extractedTexts += $cleanedText
                    Write-Verbose "Extracted event text of length: $($cleanedText.Length)"
                }
            }
            
            Write-Verbose "Successfully extracted $($extractedTexts.Count) event text(s)"
            if ($extractedText.Length -lt 1)
            {
                $extractedTexts = " "
            }
            return $extractedTexts
        }
        catch {
            Write-Warning "Error extracting event text: $($_.Exception.Message)"
            return " "
        }
    }
    
    end {
        Write-Verbose "Event Text extraction completed"
    }
}

function Remove-ReturnsExceptAfterSequence {
    <#
    .SYNOPSIS
    Removes all linefeed and carriage return characters from a file except those that follow a specified sequence.
    
    .DESCRIPTION
    This function reads a file, removes all linefeed characters (LF, `n)  and carriage return (CR, `r) except those
    that immediately follow the specified text sequence, and writes the result back to the file
    or to a new output file.
    
    .PARAMETER InputPath
    The path to the input file to process.
    
    .PARAMETER Sequence
    The text sequence after which linefeeds should be preserved.
    
    .PARAMETER OutputPath
    Optional. The path where the processed content should be saved. 
    If not specified, the original file will be overwritten.
    
    .PARAMETER Encoding
    Optional. The encoding to use when reading and writing the file. 
    Default is UTF8.
    
    .EXAMPLE
    Remove-ReturnsExceptAfterSequence -InputPath "C:\logs\events.xml" -Sequence "</Event>"
    
    .EXAMPLE
    Remove-ReturnsExceptAfterSequence -InputPath "input.xml" -OutputPath "output.xml" -Sequence "</Record>"
    
    .EXAMPLE
    Remove-ReturnsExceptAfterSequence -InputPath "events.log" -OutputPath "processed.log" -Sequence "END_BLOCK" -Encoding ASCII
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$InputPath,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Sequence,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [string]$Encoding = "UTF8"
    )
    
    try {
        # Read the entire file content
        $content = Get-Content -Path $InputPath -Raw -Encoding $Encoding
        
        # Replace all CRLF's with a placeholder first
        $tempContent = $content -replace "`r`n", ""
        $tempContent = $tempContent -replace "`n`r", ""
        # Replace any remaining linefeeds with a placeholder 
        $tempContent = $tempContent -replace "`n", ""
        # Replace any remaining carriagereturns with a placeholder 
        $tempContent = $tempContent -replace "`r", ""
        
        # Restore linefeeds that should follow the specified sequence
        $processedContent = $tempContent -replace "$([regex]::Escape($Sequence))", "$Sequence`n"
        
        # Remove any remaining placeholders (these were the linefeeds we wanted to remove)
        $finalContent = $processedContent -replace "TEMP_PLACEHOLDER", ""
        
        # Determine output path
        if (-not $OutputPath) {
            $OutputPath = $InputPath
        }
        
        # Write the processed content
        $finalContent | Set-Content -Path $OutputPath -Encoding $Encoding -NoNewline
        
        Write-Host "Successfully processed file. Linefeeds removed except those following '$Sequence'." -ForegroundColor Green
        Write-Host "Output saved to: $OutputPath" -ForegroundColor Green
        
    }
    catch {
        Write-Error "An error occurred while processing the file: $($_.Exception.Message)"
    }
}

try {
    # Create SQL connection
    $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $Connection.Open()
    Write-Host "Connected to SQL Server successfully" -ForegroundColor Green

    # Create table SQL
    $CreateTableSQL = @"
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='$TableName' AND xtype='U')
CREATE TABLE [$TableName] (
    [ID] INT IDENTITY(1,1) PRIMARY KEY,
    [EventTime] DATETIME2 NULL,
    [EventTimeString] NVARCHAR(255),
    [EventType] NVARCHAR(MAX),
    [Thread] NVARCHAR(MAX),
    [Elapsed] INT,
    [Function] NVARCHAR(MAX),
    [Code] NVARCHAR(MAX),
    [EventText] NVARCHAR(MAX),
    [InsertedDate] DATETIME2 DEFAULT GETDATE()
)
"@

    # Execute create table
    $Command = New-Object System.Data.SqlClient.SqlCommand($CreateTableSQL, $Connection)
    $Command.ExecuteNonQuery()
    Write-Host "Table '$TableName' created or already exists" -ForegroundColor Green

    # Load and parse XML
    if (-not (Test-Path $XmlFilePath)) {
        throw "XML file not found: $XmlFilePath"
    }

    # Natively, the XML elements are allowed to span lines.  Since the XML is invalid (owing to other factors)
    # we need to read the file line-by-line.  The linefeeds within the elements cause problems with this approach
    # So, this function makes sure that the only linefeeds are after the XML element closure tag "</Event>"
    Remove-ReturnsExceptAfterSequence -InputPath $XmlFilePath -Sequence "</Event>"


    $xmlFragments = Get-Content -Path $xmlFilePath | Where-Object { $_.Trim() -ne "" }

    # Process each XML fragment
    foreach ($xmlFragment in $xmlFragments) {

        try {

            # Extract attributes
            
            # now handle the non-time element attributes
            $type = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'type')
            $thread = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'thread')
            $elapsed = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'elapsed')
            $function = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'function')
            $code = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'code')

            # now get the element text
            $eventtext = $(Extract-EventText -XmlFragment $xmlFragment )
            

            # The loopy-assed "time" value needs special attention
            # We change the insert statement based on what we can get here
            $timeString = $(Get-AttributeValue -InputString $xmlFragment -AttributeName 'time')
            $format = "ddd MMM dd HH:mm:ss.fff"
            #$time = [DateTime]::MinValue # if we cannot successfully parse the value, we use the default min.


            try {
            # Parse time and insert values to table

                $time = [DateTime]::ParseExact($timeString, $format, $null)

                # Insert into database with parsed time
                $insertQuery = @"
                INSERT INTO $TableName ([EventTime],[EventTimeString], [EventType], [Thread], [Elapsed], [Function], [Code], [EventText])
                VALUES (@EventTime, @EventTimeString, @EventType, @Thread, @Elapsed, @Function, @Code, @EventText)
"@
            
                $insertCommand = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $connection)
                $insertCommand.Parameters.AddWithValue("@EventTime", $time)

                #$InsertCommand.Parameters["@EventType"].Value = if ($Event.type) { $Event.type } else { [DBNull]::Value }

                $insertCommand.Parameters.AddWithValue("@EventTimeString", $timeString)
                $insertCommand.Parameters.AddWithValue("@EventType", $type)
                $insertCommand.Parameters.AddWithValue("@Thread", $thread)
                $insertCommand.Parameters.AddWithValue("@Elapsed", $elapsed)
                $insertCommand.Parameters.AddWithValue("@Function", $function)
                $insertCommand.Parameters.AddWithValue("@Code", $code)

                $insertCommand.Parameters.AddWithValue("@EventText", $eventtext)
            
                $insertCommand.ExecuteNonQuery()

                Write-Verbose "Wrote event record with time value $timeString."

            } catch {

                # date parse fail; second attempt
                try
                {
                    Write-Warning "Failed to parse date ($dateString): $($_.Exception.Message)"
                
                    # Insert into database without parsed time
                    $insertQuery = @"
                    INSERT INTO $TableName ([EventTimeString], [EventType], [Thread], [Elapsed], [Function], [Code], [EventText])
                    VALUES ( @EventTimeString, @EventType, @Thread, @Elapsed, @Function, @Code, @EventText)
"@
            
                    $insertCommand = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $connection)
                    #$insertCommand.Parameters.AddWithValue("@EventTime", $time)

                    #$InsertCommand.Parameters["@EventType"].Value = if ($Event.type) { $Event.type } else { [DBNull]::Value }

                    $insertCommand.Parameters.AddWithValue("@EventTimeString", $timeString)
                    $insertCommand.Parameters.AddWithValue("@EventType", $type)
                    $insertCommand.Parameters.AddWithValue("@Thread", $thread)
                    $insertCommand.Parameters.AddWithValue("@Elapsed", $elapsed)
                    $insertCommand.Parameters.AddWithValue("@Function", $function)
                    $insertCommand.Parameters.AddWithValue("@Code", $code)
                
                    $insertCommand.Parameters.AddWithValue("@EventText", $eventtext)
            
                    $insertCommand.ExecuteNonQuery()

                    Write-Verbose "Wrote event record with time value $timeString WITHOUT parsed time value"
                }
                catch
                {
                    
                    Write-Warning "Error processing XML fragment: $($_.Exception.Message)"
                    Add-Content -Path $failureslog -Value $xmlFragment
                }

            }
            #$time = [DateTime]::Parse($(Get-AttributeValue -InputString $xmlFragment -AttributeName 'time'))
                        
        }
        catch 
        {
            Write-Warning "Error extracting attributes: $($_.Exception.Message)"
            Add-Content -Path $failureslog -Value $xmlFragment
        }
    }

}
catch {
    Write-Error "Error: $($_.Exception.Message)"
    Write-Error "Stack Trace: $($_.Exception.StackTrace)"
}
finally {
    if ($Connection -and $Connection.State -eq 'Open') {
        $Connection.Close()
        Write-Host "Database connection closed" -ForegroundColor Green
    }
}

Write-Host "`nScript completed!" -ForegroundColor Magenta
