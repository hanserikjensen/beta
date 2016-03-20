<#
.SYNOPSIS
  This script checks a queued blueprint job to ensure timely, successful execution.
  If the blueprint fails to complete within the threshold, a ticket is generated to Support

.DESCRIPTION
  Author    : Erik Jensen
  Last edit : 2/11/2016
  Version   : 0.1

.PARAMETER DataCenter
  The description of a parameter.
  Add a .PARAMETER keyword for each parameter in the script syntax.

.PARAMETER PollInterval

.PARAMETER TimeoutThreshold

.EXAMPLE
 MonitorDatacenterQueue.ps1   
  
.EXAMPLE
 MonitorDatacenterQueue.ps1 -TimeoutThreshold 120  

.EXAMPLE
MonitorDataCenterQueue.ps1 -PollInterval 15 -TimeoutThreshold 90

.INPUTS
  Types of Objects used as parameters.

.OUTPUTS
  Ticket ID if an alert ticket is created during exeution

.LINK
  https://support.ctl.io/hc/en-us/articles
#>
[CmdletBinding()]
Param(

    [Parameter(Mandatory=$False)]
    [string]$AccountAlias = ("EJT1"),       # My training account for POC

    [Parameter(Mandatory=$False)]
    [string[]]$Servers = ("GB3EJT1MON01"),  # Servers to check
    
    [Parameter(Mandatory=$False)]
    [int]$PollInterval = 5,                 # Time between polling checks, in seconds
    
    [Parameter(Mandatory=$False)]
    [int]$TimeoutThreshold = 45             # Timeout threshold, in seconds
)

$DebugPreference = "Continue"
$shortSleepTimer = 5 # seconds

import-module -name Control
import-module -name ZenDesk

$DataCenter = $Servers.Substring(0,3).ToUpper()

Write-Debug ('$DataCenter:       {0}' -f $DataCenter)
Write-Debug ('$PollInterval:     {0}' -f $pollInterval)
Write-Debug ('$TimeoutThreshold: {0}' -f $TimeoutThreshold); write-host;

# At the outset, query ZenDesk to see if there's an open ticket for queue issues in the data center 
Write-host # this line intentionally left blank (just here for output formatting)
Write-Debug "## CHECK ZENDESK FOR EXISTING OPEN TICKETS, AND IF FOUND DO NOT PROCEED ##"
$zdQuery = 'subject:"{0}" status:open' -f "TEST: Queue alert in $DataCenter data center"
Write-Debug ('$zdQuery: {0}' -f $zdQuery)
$zdQueryResult = Find-ZenDeskObject -ObjectType Tickets -Query $zdQuery
Write-Debug ('$zdQueryResult: {0}' -f ($zdQueryResult | convertto-json) )
if($zdQueryResult.count -gt 0)
{
    Write-Host  ("`nFound open ticket {0} for Queue Alert in the {1} data center.  Execution complete." -f $zdQueryResult.results.id, $DataCenter) -ForegroundColor Yellow
    return;
}


# TODO: dynamically pull canary server for given data center
Write-host # this line intentionally left blank (just here for output formatting)
Write-Debug "## SETUP THE APIv2 CALL PARAMETERS AND INVOKE IT ##"
$content = ('["{0}"]' -f $Servers)
Write-Debug ('$content (JSON data being sent):  {0}' -f $content)

$startTime = Get-Date
Write-Debug ('$startTime:  {0}' -f $startTime)

# Make an initial attempt to StartMaintenanceMode
$request = Invoke-ControlApi2 -PowerOperations StartMaintenanceMode -accountAlias $AccountAlias -content $content -Force
# Now check the request - if it's not an object, then need to call StopMaintenanceMode because it's already in MM, hence call to start MM failed
if($request -eq $null) 
{ 
    $request = Invoke-ControlApi2 -PowerOperations StopMaintenanceMode -accountAlias $AccountAlias -content $content -force 
}
Write-Debug ('$request (JSON data returned):{0}' -f ($request | ConvertTo-Json) )

# Sleep a moment, then start checking the blueprint job on an interval
sleep -Seconds $shortSleepTimer

# Loop on the queue request until either is comes back succeeded, or time's out per the timeoutThreshold
Write-host # this line intentionally left blank (just here for output formatting)
Write-Debug "## POLL THE BLUEPRINT JOB FOR STATUS UNTIL EITHER COMPLETE OR TIMEOUT ##"
while((Invoke-ControlApi2 -Queue GetStatus -accountAlias $AccountAlias -statusID ($request.links | select id)[0].id).Status -ne "succeeded") 
{
    $elapsedTime = New-TimeSpan -Start $startTime  -end $(Get-Date)
    
    # Check to see if execution timer is longer than the timeoutThreshold, and if so create a new incident ticket 
    if($elapsedTime.Seconds -gt $TimeoutThreshold)
    {
        # create ZenDesk ticket
        $subject = 'TEST: Queue alert in {0} data center' -f $DataCenter
        $message = 'TEST: Assign to Erik Jensen: Synthetic monitoring in the data center indicates there may be excessive delays in processing the queue'
        $groupid = '20048861'
        # https://developer.zendesk.com/rest_api/docs/core/tickets#creating-tickets
        $params = @{
            TicketData = (@{
                ticket = @{
                    subject  = $subject
                    group_id = $groupid
                    type     = 'incident'
                    priority = 'normal'
                    status   = 'open'
                    comment  = @{
                        body = $message
                    }
                    custom_fields = @(
                        @{
                            id = 20321291
                            value = 'T3N'
                        }
                        @{
                            id = 21619801
                            value = 'manual_task'
                        }
                        @{
                            id = 20321657
                            value = 'T3N'
                        }
                        @{
                            id = 24305619
                            value = 'Blueprints'
                        }
                    )
                }
            } | ConvertTo-Json -Depth 3 -Compress)
            #WebSession = $Data.ZenDesk.Session  #  TODO: how to set this session object appropriately?
        }
        $alertTicket = New-ZenDeskTicket @params
        Write-Debug $alertTicket
        exit
    }
    
    Write-Debug "The blueprint has not completed, elapsed time in queue: $elapsedTime"; sleep $pollInterval;  
}

# If this goes past the $threshold, fire an alert
$executionTime  = New-TimeSpan -Start $startTime  -end $(Get-Date)
Write-Debug -Message $('Blueprint completed after {0} seconds' -f $executionTime)