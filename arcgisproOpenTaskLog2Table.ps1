# This script creates a table in SQL Server and populates it from the Task "log" element of 
# ArcGIS Pro's diagnostic monitor that has been copied and saved to a file.
# Before running the script, update the variables at the beginning of the file

# VARIABLES TO UPDATE
$connectionString = "Server=localhost;Database=Testing;Trusted_Connection=true;" # Connection string - modify as needed 
$FilePath = "C:\temp\UNS\26June\gas_un_AddandOpenTASK.txt" # File to read
$failureslog = "C:\temp\UNS\26June\gas_un_AddandOpenTASK.log" # This file will be created and populated if there are any lines that cannot be inserted into the database.
$TableName = "arcgisproTaskLog_gas" # This table will be created and populated

try {
    # Read the file content
    if (!(Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }
    
    $content = Get-Content $FilePath -Raw
    $lines = $content -split "`r?`n" | Where-Object { $_ -match '\S' }  # Remove empty lines
    
    if ($lines.Count -lt 2) {
        throw "File must contain at least a header row and one data row"
    }
    
    # Parse header row to get field names
    $headerLine = $lines[0]
    # Split by multiple spaces (the fields appear to be separated by variable whitespace)
    $fieldNames = $headerLine -split '\s{2,}' | Where-Object { $_ -match '\S' }
    
    Write-Host "Detected fields: $($fieldNames -join ', ')"

    Write-Host "Connecting to database"
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    
    # Create table schema based on field names and data analysis
    $createTableSQL = @"
IF OBJECT_ID('dbo.$TableName', 'U') IS NOT NULL 
    DROP TABLE dbo.$TableName;

CREATE TABLE dbo.$TableName (
    [Task_Number] INT,
    [Queued_Time] NVARCHAR(20),
    [Total_Time] INT,
    [Task_Time] INT,
    [Resume_Time] INT,
    [Wait_Time] INT,
    [Function_Name] NVARCHAR(500)
);
"@

    # Execute table creation
    Write-Host "Creating table: $TableName"
    $createCommand = New-Object System.Data.SqlClient.SqlCommand($createTableSQL, $connection)
    $createCommand.ExecuteNonQuery()


    # Process each data line
    $dataLines = $lines[1..($lines.Count-1)]
    $insertedRows = 0
    
    foreach ($line in $dataLines) {
        if ($line -match '\S') {  # Skip empty lines
            try {
                # Parse the line - split by whitespace but preserve the function name at the end
                # The pattern appears to be: TaskNum  Time  Num  Num  Num  Num  FunctionName
                if ($line -match '^(\d+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+)$') {
                    $taskNum = $matches[1]
                    $queuedTime = $matches[2]
                    $totalTime = $matches[3]
                    $taskTime = $matches[4] 
                    $resumeTime = $matches[5]
                    $waitTime = $matches[6]
                    $functionName = $matches[7].Trim()
                    
                    # Escape single quotes in function name
                    $functionName = $functionName -replace "'", "''"


                    # Insert into database
                    $insertQuery = @"
                        INSERT INTO $TableName (Task_Number, Queued_Time, Total_Time, Task_Time, Resume_Time, Wait_Time, Function_Name)
                        VALUES 
                        (@taskNum, @queuedTime, @totalTime, @taskTime, @resumeTime, @waitTime, @functionName);
"@

            
                    $insertCommand = New-Object System.Data.SqlClient.SqlCommand($insertQuery, $connection)
                    $insertCommand.Parameters.AddWithValue("@taskNum", $taskNum)
                    $insertCommand.Parameters.AddWithValue("@queuedTime", $queuedTime)
                    $insertCommand.Parameters.AddWithValue("@totalTime", $totalTime)
                    $insertCommand.Parameters.AddWithValue("@taskTime", $taskTime)
                    $insertCommand.Parameters.AddWithValue("@resumeTime", $resumeTime)
                    $insertCommand.Parameters.AddWithValue("@waitTime", $waitTime)
                    $insertCommand.Parameters.AddWithValue("@functionName", $functionName)
            
                    $insertCommand.ExecuteNonQuery()
                    Write-Host "Inserted record for taskNum $taskNum"


                    $insertedRows++
                    
                } else {
                    Write-Warning "Could not process this line: $($_.Exception.Message)"
                    Add-Content -Path $failureslog -Value $line
                }
                
            } catch {
                Write-Warning "Error processing line: $line. Error: $($_.Exception.Message)"
                Add-Content -Path $failureslog -Value $line
            }
        }
    }
    
    Write-Host "Successfully processed $insertedRows rows into table $TableName"
    
    ## Display summary
    #$countSQL = "SELECT COUNT(*) as RowCount FROM dbo.$TableName"
    #$rowCount = Invoke-Sqlcmd -ConnectionString $connectionString -Query $countSQL
    #Write-Host "Total rows in table: $($rowCount.RowCount)"
    
    ## Show sample data
    #Write-Host "`nSample data from table:"
    #$sampleSQL = "SELECT TOP 5 * FROM dbo.$TableName ORDER BY Task_Number DESC"
    #$sampleData = Invoke-Sqlcmd -ConnectionString $connectionString -Query $sampleSQL
    #$sampleData | Format-Table -AutoSize

} catch {
    Write-Error "Error: $($_.Exception.Message)"
    exit 1
}

Write-Host "Script completed successfully!"
