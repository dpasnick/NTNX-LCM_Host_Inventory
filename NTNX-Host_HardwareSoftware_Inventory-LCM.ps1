####################################################################################################
#
# NTNX-Host_HardwareSoftware_Inventory-LCM.ps1
# Modified: 09/28/21
# Version:  3.1
#
# - 09/28/21 - Updated LCM API calls so they are called only once per cluster instance - this greatly
#              speeds up the script runtime. Calls are run outside of the host loop.
# - 09/11/21 - Added error checking for cluster connectivity - will display an error message on the 
#              console if there were any errors connecting to the PE API of any cluster.
#            - Cleaned up code and added/massaged the comments/documentation.
# - 09/10/21 - Added logic for LCM API to determine if information is present or not. If not 
#              present it will display an error from variable $errorLCM
#            - Added logic for pulling BIOS/BMC information - G7 appear to have changed the 
#              lookup entity label (i.e. BMC vs. BMC (Redvish), etc...)
#            - Added host boot information and logic to the host boot drive information pull - 
#              SATADOM vs. M2 drives. Also note that M2 drive entity labels (for lookup) are 
#              different between the G6 and G7. G6 labels them 'Host Boot Device - M2 Drives' 
#              whereas G7 labels them as 'M.2 Drives'.
#            - Added a feature to highlight, in yellow, the individual cells where LCM API information 
#              contained no inforatmion - either LCM issue (inventory/version) or issue with the cluster.
#            - Added display of cluster name on console output.
# - 02/24/21 - Added Foundation Version & Password popup
# - 12/10/20 - Added LCM darksite address and hardware model informaiton
# - 12/02/20 - Added cluster name and LCM Version
#
# Description: Uses the standard Nutanix Prism API calls (v2) along with LCM API calls in order to
#              grab host inventory in a cluster and pull software and hardware informaiton.
#              Please note: LCM API is opt-in and needs to be turned on - see KB 8722.
#                           If not enabled the results will be blank for hosts in that cluster.
#
# Requires: - LCM API enabled
#           - CSV input file nust have two columnns
#               Column: Cluster Name (the name of the cluster to connect to)  
#             Column: Ext_IP (the external/VIP address of the cluster)
#
# Limitations: - Will not work for single node clusters
#
# Select Variables:  
#           - $username:      AOS administrative username
#           - $fileCSV:       CVM input file with cluster lists (uses VIP with column name Ext_IP)
#           - $errorLCM       MEssage to display on spreadsheet if no information was pulled from
#                             the LCM API
#           - $Clusters:      Array of clusters to be pulled from
#           - $timeout:       Timeout in seconds for REST API method
#           - $uriLCM:        LCM API entities call
#           - $uriHost:       Cluster API hosts call
#           - $postParams:    LCM API payload parameters for call
#           - $resultLCM:     LCM API call hold
#           - $resultHost:    Cluster API call hold
#           - $hostInfo:      Ordered dictionary/hashtable to temporarily hold individual
#                             host informaiton to be added to $updateResults
#           - $updateResults: PSObject to hold final information
#
#
# Notes:
#           - Will not work on single node cluster
#           - DMZ clusters must use Nutanix Cluster Virtual IP Address
#           - Clusters must use local account as they are not connected to standard AD
#
####################################################################################################

$ErrorActionPreference = "silentlycontinue"

# Clusters to be run
$fileCSV = $(get-location).Path + "\Nutanix-Cluster_Lookup.csv"

# Error message for clusters/hosts where LCM API not enabled/cannot connect
$errorLCM = "Error - Check LCM"


# ------------------- Change Variables Above ------------------- 

# Initial Screen Messaging
clear;
Write-Host $dateToday
Write-Host "`nPlease Note: You should have run an LCM Inventory beforehand.`n" -ForegroundColor Yellow
Write-Host "This script will use '$fileCSV' to pull cluster information.`n" -ForegroundColor Yellow

# Username input - either local account or AD account if cluster is configured
$username = Read-Host -Prompt 'Enter cluster(s) administrative username.'

# Password input - either local account or AD account if cluster is configured
$securePassword = Read-Host -Prompt 'Enter cluster(s) administrative password.' -AsSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword))

# Create the HTTP Basic Authorization header
$pair = $username + ":" + $password
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$basicAuthValue = "Basic $base64"

# Setup the request headers
$headers = @{
    'Accept' = 'application/json'
    'Authorization' = $basicAuthValue
    'Content-Type' = 'application/json'
}

Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Set a sensible timeout
$timeout = 10

# Set date for log file
$dateToday = (Get-Date).toshortdatestring().Replace("/","-")

# Function that will get/parse the hardware information from the LCM API
function getHardware ($ip, $hostID, $clusterID, $resultLCMconfig, $resultLCMhost) {
    
    $hostLookup = "node:$hostID"
    $clusterLookup = "cluster:$clusterID"


    # Message for host boot drive checks - N/A will appear for Host Boot Devices based on category (i.e. M2 or SATADOM)
    $hostBootMSG = "N/A"

    # Populate temporary variables with results for each hardware device call
    
    # LCM Framework Information
    $LCM_Version = $resultLCMconfig.data.lcm_version
    
    # Darksite URL
    $LCM_Darksite = $resultLCMconfig.data.url
    
    # AOS Version Information
    $AOS_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $clusterLookup}.where{$_.entity_model -eq "AOS"}.version
    
    # NCC Version Information
    $NCC_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $clusterLookup}.where{$_.entity_model -eq "NCC"}.version
    
    #Foundation Information
    $Foundation_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_model -eq "Foundation"}.version
    
    # BMC Information
    $BMC_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -like "BMC*"}.entity_model
    $BMC_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -like "BMC*"}.version
    
    #BIOS Information
    $BIOS_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -like "BIOS*"}.entity_model
    $BIOS_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -like "BIOS*"}.Version
    
    # HBA Information
    $HBA_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "HBAs"}.entity_model
    $HBA_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "HBAs"}.version
    
    # Host Boot Drive - SATADOM
    $Host_Boot_SATADOM_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "Host Boot Device - Satadom"}.entity_model
    $Host_Boot_SATADOM_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "Host Boot Device - Satadom"}.version
    
    # Host Boot Drive - M.2 - G7 represent the lookup 'entity class' differently from G6 (M.2 Drives vs Host Boot Device - M2 Drives)
    $Host_Boot_M2_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{($_.entity_class -eq "M.2 Drives") -or ($_.entity_class -eq "Host Boot Device - M2 Drives")}.entity_model
    $Host_Boot_M2_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{($_.entity_class -eq "M.2 Drives") -or ($_.entity_class -eq "Host Boot Device - M2 Drives")}.version
    
    # SATA Drive Infromation
    $SATA_Model = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "SATA Drives"}.entity_model
    $SATA_Version = $resultLCMhost.data.entities.where{$_.location_id -eq $hostLookup}.where{$_.entity_class -eq "SATA Drives"}.version

    # Populate hostInfo array/object with LCM data pull for eventual Excel dump - includes logic for checking if data from pull is present then displaying $errorLCM if values are Null
    $hostInfo.LCM_Version = if ($LCM_Version -eq $null) { $errorLCM } else { $LCM_Version }
    $hostInfo.LCM_Darksite = if ($LCM_Darksite -eq $null) { $errorLCM } else { $LCM_Darksite }
    $hostInfo.AOS_Version = if ($AOS_Version -eq $null) { $errorLCM } else { $AOS_Version }
    $hostInfo.NCC_Version = if ($NCC_Version -eq $null) { $errorLCM } else { $NCC_Version }
    $hostInfo.Foundation_Version = if ($Foundation_Version -eq $null) { $errorLCM } else { $Foundation_Version }
    $hostInfo.BMC_Model = if ($BMC_Model -eq $null) { $errorLCM } else { $BMC_Model }
    $hostInfo.BMC_Version = if ($BMC_Version -eq $null) { $errorLCM } else { $BMC_Version }
    $hostInfo.BIOS_Model = if ($BIOS_Model -eq $null) { $errorLCM } else { $BIOS_Model }
    $hostInfo.BIOS_Version = if ($BIOS_Version -eq $null) { $errorLCM } else { $BIOS_Version }
    $hostInfo.HBA_Model = if ($HBA_Model -eq $null) { $errorLCM } else { $HBA_Model }
    $hostInfo.HBA_Version = if ($HBA_Version -eq $null) { $errorLCM } else { $HBA_Version }
    
    # Host Boot - Added logic to determine if the cluster has a SATADOM (G4/G5) or M.2 (G6/G7)
    $hostInfo.Host_Boot_SATADOM_Model =  if ($Host_Boot_M2_Model.count -ge 1) { $hostBootMSG } elseif ($Host_Boot_SATADOM_Model -eq $null) {  $errorLCM } else { $Host_Boot_SATADOM_Model }
    $hostInfo.Host_Boot_SATADOM_Version = if ($Host_Boot_M2_Model.count -ge 1) { $hostBootMSG } elseif ($Host_Boot_SATADOM_Version -eq $null) { $errorLCM } else { $Host_Boot_SATADOM_Version }
    $hostInfo.Host_Boot_M2_Model = if ($Host_Boot_SATADOM_Model.count -ge 1) { $hostBootMSG } elseif ($Host_Boot_M2_Model -eq $null) { $errorLCM } else { $Host_Boot_M2_Model -join ', ' }
    $hostInfo.Host_Boot_M2_Version = if ($Host_Boot_SATADOM_Model.count -ge 1) { $hostBootMSG } elseif ($Host_Boot_M2_Version -eq $null) { $errorLCM } else { $Host_Boot_M2_Version -join ', ' }    
    $hostInfo.SATA_Model = if ($SATA_Model -eq $null) { $errorLCM } else { $SATA_Model -join ', ' }
    $hostInfo.SATA_Version = if ($SATA_Version -eq $null) { $errorLCM } else { $SATA_Version -join ', ' }

}
# End Functions

Write-Host "Hardware Inventory Run on $dateToday"

$updateResults = New-Object System.Collections.ArrayList($null)

# Import all clusters to be upgraded from the CSV file
$csv = Import-Csv "$fileCSV"

# Cluster error message - console
$errorCluster = New-Object System.Collections.ArrayList($null)


# Run through each cluster and pull API payloads.
foreach ($cluster in $csv) {

    $ip = $($cluster.Ext_IP)
    $clusterName = $($cluster.'Cluster Name')

    Write-Host "`nConnecting to Nutanix cluster $clusterName ($ip) ...`n" -foregroundColor Yellow
    Write-Host "Triggering REST API for $clusterName ($ip)..." -foregroundColor Green
    

# Error checking to determine if cluster is up and responsive - if not do not add to spreadsheet but display errors to console
Try { 

    # Invoke REST method for cluster information - PE
    $uriCluster = "https://" + $ip + ":9440/PrismGateway/services/rest/v2.0/cluster/"
    $resultCluster = (Invoke-RestMethod -Uri $uriCluster -Headers $headers -Method GET -TimeoutSec $timeout)
    
    # Invoke REST method for host information - PE
    $uriHost = "https://" + $ip + ":9440/PrismGateway/services/rest/v2.0/hosts/"
    $resultHost = (Invoke-RestMethod -Uri $uriHost -Headers $headers -Method GET -TimeoutSec $timeout)
} 

Catch {

            Write-Host "`n`n*************************************************************************" -ForegroundColor Red
            Write-Host "Error Type: " $_.Exception.Message -ForegroundColor Red
            Write-Host "Error Line: " $_.InvocationInfo.ScriptLineNumber -ForegroundColor Red
            Write-Host "Failed For: " $ip -ForegroundColor Red
            Write-Host "*************************************************************************`n`n" -ForegroundColor Red

            $errorClusterInfo = [ordered]@{
                Cluster_Name = $clusterName
                Error_Message = $_.Exception.Message
            }
            $errorCluster.Add((New-Object PSObject -Property $errorClusterInfo)) | Out-Null
}

    # LCM API calls for the cluster

    # Invoke LCM API REST method for hosts
    $uriLCMhost = "https://" + $ip + ":9440/lcm/v1.r0.b1/resources/entities/list"
    $uriLCMconfig = "https://" + $ip + ":9440/lcm/v1.r0.b1/resources/config"
    
       
    $postLCMParams = @{} | ConvertTo-Json
    
    # Grab LCM Config Information
    $resultLCMconfig = (Invoke-RestMethod -Uri $uriLCMconfig -Headers $headers -Method GET -TimeoutSec $timeout)
    
    # Grab LCM Host Information
    $resultLCMhost = (Invoke-RestMethod -Uri $uriLCMhost -Headers $headers -Method POST -Body $postLCMParams -TimeoutSec $timeout)


    # Grab host information (regular API and LCM API) and parse through the API calls for each host.
    for ($i=0; $i -lt $resultHost.entities.count; $i++) {

        $hostInfo = [ordered]@{
            Cluster_Name = $resultCluster.name;
            Host_Name = $resultHost.entities.name[$i];
            Host_UUID = $resultHost.entities.uuid[$i];
            Host_Model = $resultHost.entities.block_model_name[$i];
            Hypervisor_Version = $resultHost.entities.hypervisor_full_name[$i];
        }

        Write-Host "Getting Invetory for" $hostInfo.Host_Name "..." -foregroundColor Green
        
        # Call LCM API to grab hardware information   
        getHardware $ip $hostInfo.Host_UUID $resultHost.entities.cluster_uuid[$i] $resultLCMconfig $resultLCMhost

        # Add info to master list $updateResults        
        $updateResults.Add((New-Object PSObject -Property $hostInfo)) | Out-Null

        Start-Sleep -m 100
    }

    # Clear iterative lookup table - if host is down it will not populate the the master table with prevoius iteration information
    $hostInfo = $resultCluster = $resultHost = $null

}

Write-Output $updateResults | ft

if ($errorCluster -ne $null) {
    Write-Output "*************************************************************"
    Write-Output "Errors Connecting to Clusters Encountered - Specific Issues:"
    Write-Output $errorCluster
    Write-Output "`n*************************************************************`n"
}

# Save to Excel
$excelApp = New-Object -ComObject Excel.Application
$excelApp.Visible = $True
$workBook = $excelApp.Workbooks.Add()

$workSheet = $workBook.Worksheets.Item(1)
$workSheet.Rows.HorizontalAlignment = -4131 
$workSheet.Rows.Font.Size = 10
$workSheet.Name = "Hosts Inventory"
$row = $col = 1
$hostXLHead = ("Cluster_Name","Host_Name","Host_Model","LCM_Version","LCM_Darksite","Host_UUID","Hypervisor_Version","AOS_Version","Foundation_Version","NCC_Version","BMC_Model","BMC_Version","BIOS_Model","BIOS_Version","HBA_Model","HBA_Version","Host_Boot_SATADOM_Model","Host_Boot_SATADOM_Version","Host_Boot_M2_Model","Host_Boot_M2_Version","SATA_Model","SATA_Version")
$hostXLHead | %( $_  ){ $workSheet.Cells.Item($row,$col) = $_ ; $col++ }
$workSheet.Rows.Item(1).Font.Bold = $True
$workSheet.Rows.Item(1).HorizontalAlignment = -4108
$workSheet.Rows.Item(1).Borders.Item(9).Weight = 2
$workSheet.Rows.Item(1).Borders.Item(9).LineStyle = 1

$i = 0; $row++; $col = 1
FOREACH( $updateResult in $updateResults ){ 
    $i = 0
    DO{ 
        $workSheet.Cells.Item($row,$col) = $updateResult.($hostXLHead[$i])

        If ($updateResult.($hostXLHead[$i]) -eq $errorLCM) {
            $workSheet.Cells.Item($row,$col).Interior.ColorIndex = 36
        }

        $col++
        $i++ 
    }UNTIL($i -ge $hostXLHead.Count)
    $row++; $col=1
    Start-Sleep -m 250
} 
$workSheet.UsedRange.EntireColumn.AutoFit()

#Save Excel Workbook
$Date = Get-Date
$Today = (Get-Date).toshortdatestring().Replace("/","-")
$filepath = $(get-location).Path + "/Nutanix_Hardware_Report-$Today.xlsx"
$excelApp.DisplayAlerts = $False
$workBook.SaveAs($filepath)
$excelApp.Quit()

Write-Host "`nFile Saved to: $filepath" -foregroundColor Yellow

# Cleanup sensitice information
Remove-Variable username -ErrorAction SilentlyContinue
Remove-Variable securePassword -ErrorAction SilentlyContinue
Remove-Variable password -ErrorAction SilentlyContinue
# End Cleanup