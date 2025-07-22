# ArcGISProDiagnosticMonitor2Sql
PowerShell scripts that creates tables and populates them from the log outputs saved from ArcGIS Pro's "Diagnostic Monitor".

The arcgisProDmLogXml2Table.ps1 script reads the file that is created directly by Diagnostic Monitor.

The other scripts are designed to process the contents of tabs from the UX that are copied and pasted into files.  Each 
of those scripts' names includes a reference to the tab ("Events", "Tasks", and "HTTP Requests").
