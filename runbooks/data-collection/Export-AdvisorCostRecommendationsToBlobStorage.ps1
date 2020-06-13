param(
    [Parameter(Mandatory = $false)]
    [string] $targetSubscription = ""
)

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

# get ARG exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_AdvisorCostContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "advisorexports"
}

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment 
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}


Write-Output "Getting subscriptions target $TargetSubscription"

if (-not([string]::IsNullOrEmpty($TargetSubscription)))
{
    $subscriptions = $TargetSubscription
}
else
{
    $subscriptions = Get-AzSubscription | ForEach-Object { "$($_.Id)"}
}

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$recommendations = @()

<#
   Getting Advisor Cost recommendations for each subscription and building CSV entries
#>

$datetime = (get-date).ToUniversalTime()
$hour = $datetime.Hour
$min = $datetime.Minute
$timestamp = $datetime.ToString("yyyy-MM-ddT$($hour):$($min):00.000Z")

foreach ($subscription in $subscriptions)
{
    Select-AzSubscription -SubscriptionId $subscription

    $advisorRecommendations = Get-AzAdvisorRecommendation -Category Cost

    foreach ($advisorRecommendation in $advisorRecommendations)
    {
        # compute instance ID, resource group and subscription for the recommendation
        $resourceIdParts = $advisorRecommendation.ResourceId.Split('/')
        if ($resourceIdParts.Count -ge 9)
        {
            # if the Resource ID is made of 9 parts, then the recommendation is relative to a specific Azure resource
            $realResourceIdParts = $resourceIdParts[1..8]
            $instanceId = ""
            for ($i = 0; $i -lt $realResourceIdParts.Count; $i++)
            {
                $instanceId += "/" + $realResourceIdParts[$i]
            }

            $resourceGroup = $realResourceIdParts[3]
            $subscriptionId = $realResourceIdParts[1]
        }
        else
        {
            # otherwise it is not a resource-specific recommendation (e.g., reservations)
            $instanceId = $advisorRecommendation.ResourceId
            $resourceGroup = "NotAvailable"
            $subscriptionId = $resourceIdParts[2]
        }

        $recommendation = New-Object PSObject -Property @{
            Timestamp = $timestamp
            Cloud = $cloudEnvironment
            Impact = $advisorRecommendation.Impact
            ImpactedArea = $advisorRecommendation.ImpactedField
            Description = $advisorRecommendation.ShortDescription.Problem
            RecommendationText = $advisorRecommendation.ShortDescription.Problem
            RecommendationTypeId = $advisorRecommendation.RecommendationTypeId
            InstanceId = $instanceId
            Category = $advisorRecommendation.Category
            InstanceName = $advisorRecommendation.ImpactedValue
            AdditionalInfo = $advisorRecommendation.ExtendedProperties
            ResourceGroup = $resourceGroup
            SubscriptionGuid = $subscriptionId
        }
    
        $recommendations += $recommendation    
    }

    <#
    Actually exporting CSV to Azure Storage
    #>

    $fileDate = $datetime.ToString("yyyyMMdd")
    $jsonExportPath = "$fileDate-cost-$subscription.json"
    $csvExportPath = "$fileDate-cost-$subscription.csv"

    $recommendations | ConvertTo-Json -Depth 10 | Out-File $jsonExportPath
    Write-Output "Exported to JSON: $($recommendations.Count) lines"
    $recommendationsJson = Get-Content -Path $jsonExportPath | ConvertFrom-Json
    Write-Output "JSON Import: $($recommendationsJson.Count) lines"
    $recommendationsJson | Export-Csv -NoTypeInformation -Path $csvExportPath
    Write-Output "Export to $csvExportPath"

    $csvBlobName = $csvExportPath
    $csvProperties = @{"ContentType" = "text/csv"};

    Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
}

Write-Output "DONE!"