<#
.SYNOPSIS
    Health check for the Cloud Operations Monitoring Lab.
    Inventories Azure resources, checks them against the lab's standard
    configuration, and writes CSV and HTML reports.

.DESCRIPTION
    Phase 1 checks:
      - Required tags on every resource
      - Provisioning state "Succeeded"
      - NSG: no inbound Allow rule open to Any/Internet
      - Storage: TLS 1.2, public blob access disabled, Data Lake Gen2 (HNS)
      - Key Vault: RBAC authorization and soft delete enabled
      - Diagnostic logs sent to Log Analytics (Key Vault, NSG)
    Phase 2 checks (only if a Synapse workspace exists):
      - Synapse firewall has no "whole internet" rule
      - Synapse managed identity has Storage Blob Data Contributor
      - Synapse diagnostic logs sent to Log Analytics

    -UploadToDataLake copies the CSV reports to the data lake (data/inventory, data/checks)
    so they can be analyzed with Synapse serverless SQL in phase 2.

.EXAMPLE
    ./Get-CloudOpsReport.ps1 -ResourceGroupName (terraform -chdir=../terraform output -raw resource_group_name)

.EXAMPLE
    ./Get-CloudOpsReport.ps1 -ResourceGroupName rg-cloudopsab12c -UploadToDataLake

.NOTES
    Requires PowerShell 7+ and the Az module (Az.Accounts, Az.Resources, Az.Network,
    Az.Storage, Az.KeyVault, Az.Monitor, Az.Synapse). Run Connect-AzAccount first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string[]]$RequiredTags = @('project', 'environment', 'owner', 'managed_by'),

    [string]$OutputFolder = './reports',

    [switch]$UploadToDataLake
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) {
    throw 'Not signed in. Run Connect-AzAccount first.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Category, [string]$Check, [string]$Target, [bool]$Passed, [string]$Detail)
    $checks.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        Category  = $Category
        Check     = $Check
        Target    = $Target
        Status    = if ($Passed) { 'PASS' } else { 'FAIL' }
        Detail    = $Detail
    })
}

function Test-LogsToWorkspace {
    param([string]$ResourceId, [string]$Name)
    $diag = Get-AzDiagnosticSetting -ResourceId $ResourceId -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkspaceId }
    Add-Check -Category 'Monitoring' -Check 'Logs sent to Log Analytics' -Target $Name `
        -Passed ([bool]$diag) `
        -Detail ($(if ($diag) { "Diagnostic setting: $(@($diag.Name) -join ', ')" } else { 'No diagnostic setting to Log Analytics' }))
}

Write-Host "Running checks on resource group '$ResourceGroupName'..." -ForegroundColor Cyan
$null = Get-AzResourceGroup -Name $ResourceGroupName

# --- Inventory, tags, provisioning state ---------------------------------------
$resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ExpandProperties

$inventory = foreach ($res in $resources) {
    $tags    = if ($res.Tags) { $res.Tags } else { @{} }
    $state   = $res.Properties.provisioningState
    $missing = @($RequiredTags | Where-Object { -not $tags.ContainsKey($_) })

    Add-Check -Category 'Governance' -Check 'Required tags' -Target $res.Name -Passed ($missing.Count -eq 0) `
        -Detail ($(if ($missing.Count) { "Missing: $($missing -join ', ')" } else { 'All required tags present' }))

    if ($state) {
        Add-Check -Category 'Health' -Check 'Provisioning state' -Target $res.Name -Passed ($state -eq 'Succeeded') -Detail $state
    }

    [pscustomobject]@{
        Timestamp         = (Get-Date).ToString('s')
        Name              = $res.Name
        Type              = $res.ResourceType
        Location          = $res.Location
        ProvisioningState = $state
        MissingTags       = $missing -join ' '
        Tags              = ($tags.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
    }
}

# --- Network security groups --------------------------------------------------
$openSources = @('*', 'Internet', 'Any', '0.0.0.0/0')
foreach ($nsg in Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName) {
    foreach ($rule in $nsg.SecurityRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' }) {
        $sources = @($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes) | Where-Object { $_ }
        $ports   = @($rule.DestinationPortRange) + @($rule.DestinationPortRanges) | Where-Object { $_ }
        $isOpen  = [bool]($sources | Where-Object { $_ -in $openSources })
        Add-Check -Category 'Security' -Check 'NSG inbound rule not open to the internet' -Target "$($nsg.Name)/$($rule.Name)" `
            -Passed (-not $isOpen) -Detail "Source: $($sources -join ','); Ports: $($ports -join ',')"
    }
    Test-LogsToWorkspace -ResourceId $nsg.Id -Name $nsg.Name
}

# --- Storage -------------------------------------------------------------------
$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName | Select-Object -First 1
if ($storage) {
    $sa = $storage.StorageAccountName
    Add-Check -Category 'Security' -Check 'Storage minimum TLS 1.2' -Target $sa `
        -Passed ($storage.MinimumTlsVersion -eq 'TLS1_2') -Detail "MinimumTlsVersion: $($storage.MinimumTlsVersion)"
    Add-Check -Category 'Security' -Check 'Storage blocks public blob access' -Target $sa `
        -Passed ($storage.AllowBlobPublicAccess -eq $false) -Detail "AllowBlobPublicAccess: $($storage.AllowBlobPublicAccess)"
    Add-Check -Category 'Configuration' -Check 'Storage is Data Lake Gen2 (HNS)' -Target $sa `
        -Passed ($storage.EnableHierarchicalNamespace -eq $true) -Detail "HNS: $($storage.EnableHierarchicalNamespace)"
}

# --- Key Vault -----------------------------------------------------------------
foreach ($item in Get-AzKeyVault -ResourceGroupName $ResourceGroupName) {
    $kv = Get-AzKeyVault -VaultName $item.VaultName -ResourceGroupName $ResourceGroupName
    Add-Check -Category 'Security' -Check 'Key Vault uses RBAC authorization' -Target $kv.VaultName `
        -Passed ($kv.EnableRbacAuthorization -eq $true) -Detail "EnableRbacAuthorization: $($kv.EnableRbacAuthorization)"
    Add-Check -Category 'Security' -Check 'Key Vault soft delete enabled' -Target $kv.VaultName `
        -Passed ($kv.EnableSoftDelete -eq $true) -Detail "SoftDelete: $($kv.EnableSoftDelete), retention $($kv.SoftDeleteRetentionInDays) days"
    Test-LogsToWorkspace -ResourceId $kv.ResourceId -Name $kv.VaultName
}

# --- Phase 2: Synapse ----------------------------------------------------------
$workspace = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($workspace) {
    foreach ($rule in Get-AzSynapseFirewallRule -ResourceGroupName $ResourceGroupName -WorkspaceName $workspace.Name) {
        $openToAll = ($rule.StartIpAddress -eq '0.0.0.0' -and $rule.EndIpAddress -eq '255.255.255.255')
        Add-Check -Category 'Security' -Check 'Synapse firewall rule scope' -Target "$($workspace.Name)/$($rule.Name)" `
            -Passed (-not $openToAll) -Detail "$($rule.StartIpAddress) - $($rule.EndIpAddress)"
    }

    if ($storage -and $workspace.Identity.PrincipalId) {
        $assignment = Get-AzRoleAssignment -Scope $storage.Id -ObjectId $workspace.Identity.PrincipalId -ErrorAction SilentlyContinue |
            Where-Object RoleDefinitionName -eq 'Storage Blob Data Contributor'
        Add-Check -Category 'Security' -Check 'Synapse identity has storage access (RBAC)' -Target $storage.StorageAccountName `
            -Passed ([bool]$assignment) `
            -Detail ($(if ($assignment) { 'Storage Blob Data Contributor assigned' } else { 'Role assignment not found' }))
    }

    Test-LogsToWorkspace -ResourceId $workspace.Id -Name $workspace.Name
}

# --- Reports -------------------------------------------------------------------
$inventoryCsv = Join-Path $OutputFolder "inventory-$stamp.csv"
$checksCsv    = Join-Path $OutputFolder "checks-$stamp.csv"
$htmlPath     = Join-Path $OutputFolder "cloudops-report-$stamp.html"

$inventory | Export-Csv -Path $inventoryCsv -NoTypeInformation
$checks    | Export-Csv -Path $checksCsv -NoTypeInformation

$failed = @($checks | Where-Object Status -eq 'FAIL').Count
$passed = $checks.Count - $failed

$css = @'
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; }
 h1 { font-size: 22px; margin-bottom: 4px; }
 h2 { font-size: 17px; margin-top: 28px; }
 table { border-collapse: collapse; width: 100%; font-size: 13px; }
 th, td { border: 1px solid #d9dee3; padding: 6px 8px; text-align: left; }
 th { background: #f1f4f7; }
</style>
'@

$summary = "<p>Resource group: <b>$ResourceGroupName</b> | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Resources: $(@($inventory).Count) | Checks: $passed passed, $failed failed</p>"

$checksHtml = ($checks | Sort-Object Status, Category | ConvertTo-Html -Fragment -Property Status, Category, Check, Target, Detail) -join "`n"
$checksHtml = $checksHtml -replace '<td>PASS</td>', '<td style="color:#1a7f37;font-weight:600">PASS</td>' `
                          -replace '<td>FAIL</td>', '<td style="color:#c62828;font-weight:600">FAIL</td>'
$inventoryHtml = ($inventory | ConvertTo-Html -Fragment -Property Name, Type, Location, ProvisioningState, MissingTags) -join "`n"

ConvertTo-Html -Title 'Cloud Operations Report' -Head $css -Body @"
<h1>Cloud Operations Report</h1>
$summary
<h2>Checks</h2>
$checksHtml
<h2>Resource inventory</h2>
$inventoryHtml
"@ | Out-File -FilePath $htmlPath -Encoding utf8

$checks | Sort-Object Status, Category | Format-Table Status, Category, Check, Target -AutoSize
Write-Host "`n$($checks.Count) checks, $failed failed." -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "Reports:`n  $inventoryCsv`n  $checksCsv`n  $htmlPath"

# --- Optional: copy reports to the data lake for Synapse analysis ---------------
if ($UploadToDataLake) {
    if (-not $storage) { throw 'No storage account found for upload.' }
    # Uses your Entra ID sign-in (Storage Blob Data Contributor), not account keys.
    $ctx = New-AzStorageContext -StorageAccountName $storage.StorageAccountName -UseConnectedAccount
    $null = Set-AzStorageBlobContent -Context $ctx -Container 'data' -File $inventoryCsv -Blob "inventory/$(Split-Path $inventoryCsv -Leaf)" -Force
    $null = Set-AzStorageBlobContent -Context $ctx -Container 'data' -File $checksCsv    -Blob "checks/$(Split-Path $checksCsv -Leaf)" -Force
    Write-Host "Uploaded reports to $($storage.StorageAccountName)/data/inventory and /data/checks" -ForegroundColor Cyan
}

if ($failed -gt 0) { exit 1 }
