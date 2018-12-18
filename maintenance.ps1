# Titel: Maintenance Script for RDS Session Hosts
# Dependencies: Maintenance Window COllection in SCCM must be in place
# Prerequisiteds: Users running scheduled Tasks must have "Read-Only-Analyst" rights and (http://benef-it.blogspot.com/2013/04/solve-ps-drive-problem-with-sccm2012.html)
# Author: BRUS
# Date: 13.11.18
# Version: 1.0
# History: 1.0 - Inital Script for Maintaining RDS Farm
#                
#
################################################################################

# Set Parameter for Input (GroupA,GroupB,CleanUp)
Param (
	[string]$Parameter
)

# Set some stuff
$Domain = "xyz.local" #Domain Name
$SCCM = "scc.xyz.local" # SCCM Server
$SiteCode = "bla:\" # SCCM Site Code (leave : and \ in place)
$CollectionNameA = "MWM RDS Session Hosts Group A" # MWM Collection in SCMM Group A
$CollectionNameB = "MWM RDS Session Hosts Group B" # MWM Collection in SCMM Group A
$RDSCollectionName = "Prod" # RDS Collection Name
$collectionbroker = "rds01.xyz.local"
$path = "C:\scripts\Maintenance\Log" # Path  to log Files
$date = get-date -format "yyyy-MM-dd-HH-mm" # Log File Format leave as it is
$file = ("Log_" + $date + ".log") # Log File Format leave as it is
$logfile = $path + "\" + $file # Log File Format leave as it is
$DisconnectedSessionLimitMin = "120" # RDS Disconnect Time
$IdleSessionLimitMin = "120" # RDS Idle Time
$ActiveSessionLimitMin ="720" # RDS Session Limit Time

# Function for Logfile
function Write-Log([string]$logtext, [int]$level=0)
{
	$logdate = get-date -format "yyyy-MM-dd HH:mm:ss"
	if($level -eq 0)
	{
		$logtext = "[INFO] " + $logtext
		$text = "["+$logdate+"] - " + $logtext
		Write-Host $text
	}
	if($level -eq 1)
	{
		$logtext = "[WARNING] " + $logtext
		$text = "["+$logdate+"] - " + $logtext
		Write-Host $text -ForegroundColor Yellow
	}
	if($level -eq 2)
	{
		$logtext = "[ERROR] " + $logtext
		$text = "["+$logdate+"] - " + $logtext
		Write-Host $text -ForegroundColor Red
	}
	$text >> $logfile
}
$date = get-date -format "yyyy-MM-dd"


# Import Required Modules
Import-Module RemoteDesktopServices

#Connect to SCCM
$sess = New-PSSession -ComputerName $SCCM -ConfigurationName Microsoft.PowerShell32

#get all Session Hosts from Collection A
$collection_a = Invoke-Command -Session $sess -ArgumentList ($SiteCode,$CollectionNameA) -ScriptBlock {
    param($SiteCode, $CollectionNameA)
    Import-module "E:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

    cd $SiteCode
  
    
  Get-CMCollection -Name "$CollectionNameA" | Get-CMCollectionMember | select name 
} 

#get all Session Hosts from Collection B
$collection_b = Invoke-Command -Session $sess -ArgumentList ($SiteCode,$CollectionNameB) -ScriptBlock {
    param($SiteCode, $CollectionNameB)
    Import-module "E:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

    cd $SiteCode
  
    
  Get-CMCollection -Name "$CollectionNameB" | Get-CMCollectionMember | select name 
} 

# export only Servernames from Collection Group
$sessionhosts_a = $collection_a.name
$sessionhosts_b = $collection_b.name
Write-Log "Servers in $CollectionNameA $sessionhosts_a"
Write-Log "Servers in $CollectionNameB $sessionhosts_b"


#Get Logged in Users from Group A
 $loggedinusers_a = Foreach ($sessionhosts in $sessionhosts_a) {
                Get-RDUserSession -ConnectionBroker $collectionbroker| Where-Object {$_.HostServer -eq "$sessionhosts.$domain"}
            }
$loggedinusername_a = $loggedinusers_a.UserName
Write-Log "Users logged in on Server Group A $loggedinusername_a"

#Get Logged in Users from Group B
 $loggedinusers_b = Foreach ($sessionhosts in $sessionhosts_b) {
                Get-RDUserSession -ConnectionBroker $collectionbroker| Where-Object {$_.HostServer -eq "$sessionhosts.$domain"}
            }
$loggedinusername_b = $loggedinusers_b.UserName
Write-Log "Users logged in on Servers Group B $loggedinusername_b"



if ($parameter -ieq "GroupA"){
        
        # Set Disconnected Session limit to 1 Minute
        Set-RDSessionCollectionConfiguration -CollectionName $RDSCollectionName -DisconnectedSessionLimitMin 1 -IdleSessionLimitMin 1 -ActiveSessionLimitMin 720

if ((Get-RDSessionCollectionConfiguration -CollectionName $RDSCollectionName -Connection | select DisconnectedSessionLimitMin) -eq 1)
    { Write-Log "Session limits successfully set" }
    else {
    Write-Log "Session limits not set" 1
    Do {
    Set-RDSessionCollectionConfiguration -CollectionName $RDSCollectionName -DisconnectedSessionLimitMin 1 -IdleSessionLimitMin 1 -ActiveSessionLimitMin 720
    }
    Until ((Get-RDSessionCollectionConfiguration -CollectionName $RDSCollectionName -Connection | select DisconnectedSessionLimitMin) -match 1)
    Write-Log "Session limits successfully set" 
    }

        #Set Server from other Group to allow new connections
        $sessionhosts_b | ForEach-Object {
                Set-RDSessionHost -SessionHost "$_.$domain" -NewConnectionAllowed Yes
            }
Write-Log "New Connection Allowed for $sessionhosts_b"

        #Set Server to not allow new connections until reboot
        $sessionhosts_a | ForEach-Object {
                Set-RDSessionHost -SessionHost "$_.$domain" -NewConnectionAllowed NotUntilReboot
            }
Write-Log "New Connection NOT Allowed for $sessionhosts_a"

        # Send Message to all logged in Users
        Foreach ($sessionhosts in $sessionhosts_a) {
                Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Send-RDUserMessage -MessageTitle "Message from Support" -MessageBody "Server will be rebooting shortly please save your work and logoff. You can reconnect after 5 Minutes."
            }
Write-Log "Message sent to Users $loggedinusername_a"

        #Wait 5 Minutes
        Start-Sleep -Seconds 300

        # log out all Users from Session Hosts group a
        Foreach ($sessionhosts in $sessionhosts_a) {
                Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Invoke-RDUserLogoff -Force
            #Wait a few seconds
        Start-Sleep -Seconds 10
         }
        #check if log out successfull
        If ((Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts_a.$domain"} | Measure-Object | Select-Object Count | ft -HideTableHeaders | Out-String) -ge 1) {
        write-log "Users still logged in" 1
        Foreach ($sessionhosts in $sessionhosts_a) {
                        Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Invoke-RDUserLogoff -Force
                    }
        }
        Else
        {
        write-log "Successfully logged out $loggedinusername_a"
    }
    } #End if
if ($parameter -ieq "GroupB"){

        #Set Server from other Group to allow new connections
        $sessionhosts_a | ForEach-Object {
                Set-RDSessionHost -SessionHost "$_.$Domain" -NewConnectionAllowed Yes
            }
        Write-Log "New Connection Allowed for $sessionhosts_a"

            #Set Server to not allow new connections until reboot
        $sessionhosts_b | ForEach-Object {
                Set-RDSessionHost -SessionHost "$_.$Domain" -NewConnectionAllowed NotUntilReboot
            }
        Write-Log "New Connection NOT Allowed for $sessionhosts_b"

        # Send Message to all logged in Users
        Foreach ($sessionhosts in $sessionhosts_b) {
                Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Send-RDUserMessage -MessageTitle "Message from Support" -MessageBody "Server will be rebooting shortly please save your work and logoff. You can reconnect after 5 Minutes."
            }
        Write-Log "Message sent to Users $loggedinusername_b"

        #Wait 5 Minutes
        Start-Sleep -Seconds 300

       # log out all Users from Session Hosts group b
        Foreach ($sessionhosts in $sessionhosts_b) {
                Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Invoke-RDUserLogoff -Force
         #Wait a few seconds
        Start-Sleep -Seconds 10
            }
        #check if log out successfull
        If ((Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts_b.$domain"} | Measure-Object | Select-Object Count | ft -HideTableHeaders | Out-String) -ge 1)
        {
        write-log "Users still logged in" 1
        Foreach ($sessionhosts in $sessionhosts_b) {
                        Get-RDUserSession -ConnectionBroker $collectionbroker | Where-Object {$_.HostServer -eq "$sessionhosts.$domain"} | Invoke-RDUserLogoff -Force
                    }
        }
        Else
        {
        write-log "Successfully logged out $loggedinusername_b"
    } #End if
    } #end if

if ($parameter -ieq "CleanUp"){
    #Set Session limit back to original
    Set-RDSessionCollectionConfiguration -CollectionName $RDSCollectionName -DisconnectedSessionLimitMin $DisconnectedSessionLimitMin -IdleSessionLimitMin $IdleSessionLimitMin -ActiveSessionLimitMin $ActiveSessionLimitMin
    write-log "Session Collection Timelimits reset"

    #Set all SessionHosts to allow new connections
     $sessionhosts_a | ForEach-Object {
                    Set-RDSessionHost -SessionHost "$_.$Domain" -NewConnectionAllowed Yes
                }
            Write-Log "New Connection Allowed for $sessionhosts_a.$Domain"

    $sessionhosts_b | ForEach-Object {
                    Set-RDSessionHost -SessionHost "$_.$Domain" -NewConnectionAllowed Yes
                }
            Write-Log "New Connection Allowed for $sessionhosts_b.$Domain"
}