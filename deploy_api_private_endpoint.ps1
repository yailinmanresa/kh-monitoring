<#
.SYNOPSIS
    Gives the monitoring API a private endpoint, so on-prem can reach it through the VPN.

.DESCRIPTION
    1. Creates a private endpoint for the web app in snet-privateendpoints.
    2. Creates the private DNS zone privatelink.azurewebsites.net and links it
       to the hub and spoke VNets.
    3. Registers the endpoint in the zone, and checks that the DNS records
       (the API and its .scm deployment site) really exist.
    4. Optional: -DisablePublicAccess turns off the API's public address, so it is
       only reachable privately. Do this after the end-to-end test.

    The NSG on snet-privateendpoints already allows on-prem (192.168.1.0/24)
    to reach this subnet on port 443 (rule 110).

.EXAMPLE
    .\deploy_api_private_endpoint.ps1
    .\deploy_api_private_endpoint.ps1 -DisablePublicAccess
#>

param(
    [switch]$DisablePublicAccess,
    [string]$Location       = "spaincentral",
    [string]$NetworkGroup   = "rg-kh-network-spain",
    [string]$AppGroup       = "rg-kh-app-spain",
    [string]$HubVnet        = "vnet-hub-spain",
    [string]$SpokeVnet      = "vnet-spoke-monitoring-spain",
    [string]$EndpointSubnet = "snet-privateendpoints",
    [string]$AppName        = "app-kh-monitoring-yailin01",
    [string]$EndpointName   = "pe-app-kh-monitoring",
    [string]$DnsZone        = "privatelink.azurewebsites.net"
)

$Tags = @("project=knowledgehub-cs2", "environment=lab", "owner=admin", "costcenter=it")

function Invoke-Az {
    param([string]$Step, [string[]]$Arguments)
    Write-Host "==> $Step" -ForegroundColor Cyan
    $output = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $Step. Read the error above." -ForegroundColor Red
        exit 1
    }
    return $output
}

function Test-AzResource {
    param([string[]]$Arguments)
    & az @Arguments --only-show-errors --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Skip([string]$What) {
    Write-Host "==> $What already exists, skipping" -ForegroundColor Yellow
}

# 1. Login check and IDs
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"
$appId = Invoke-Az "Looking up the web app" @(
    "webapp", "show", "--resource-group", $AppGroup, "--name", $AppName, "--query", "id", "--output", "tsv")
$subnetId = Invoke-Az "Looking up $EndpointSubnet" @(
    "network", "vnet", "subnet", "show", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $EndpointSubnet, "--query", "id", "--output", "tsv")
$hubId = Invoke-Az "Looking up $HubVnet" @(
    "network", "vnet", "show", "--resource-group", $NetworkGroup, "--name", $HubVnet, "--query", "id", "--output", "tsv")
$spokeId = Invoke-Az "Looking up $SpokeVnet" @(
    "network", "vnet", "show", "--resource-group", $NetworkGroup, "--name", $SpokeVnet, "--query", "id", "--output", "tsv")

# 2. Private endpoint for the web app ("sites" = the web app itself)
if (Test-AzResource @("network", "private-endpoint", "show", "--resource-group", $AppGroup, "--name", $EndpointName)) {
    Skip "Private endpoint $EndpointName"
} else {
    Invoke-Az "Creating private endpoint $EndpointName (takes 1-2 minutes)" (@(
        "network", "private-endpoint", "create", "--resource-group", $AppGroup, "--name", $EndpointName,
        "--location", $Location, "--subnet", $subnetId,
        "--private-connection-resource-id", $appId, "--group-id", "sites",
        "--connection-name", "$EndpointName-connection", "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 3. Private DNS zone, linked to both VNets
if (Test-AzResource @("network", "private-dns", "zone", "show", "--resource-group", $NetworkGroup, "--name", $DnsZone)) {
    Skip "Private DNS zone $DnsZone"
} else {
    Invoke-Az "Creating private DNS zone $DnsZone" (@(
        "network", "private-dns", "zone", "create", "--resource-group", $NetworkGroup, "--name", $DnsZone,
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}
foreach ($link in @(@{Name = "link-hub"; Vnet = $hubId}, @{Name = "link-spoke"; Vnet = $spokeId})) {
    if (Test-AzResource @("network", "private-dns", "link", "vnet", "show", "--resource-group", $NetworkGroup,
                          "--zone-name", $DnsZone, "--name", $link.Name)) {
        Skip "DNS link $($link.Name)"
    } else {
        Invoke-Az "Linking $DnsZone to the VNet ($($link.Name))" @(
            "network", "private-dns", "link", "vnet", "create", "--resource-group", $NetworkGroup,
            "--zone-name", $DnsZone, "--name", $link.Name, "--virtual-network", $link.Vnet,
            "--registration-enabled", "false", "--output", "none") | Out-Null
    }
}

# 4. Register the endpoint in the zone
$zoneId = Invoke-Az "Looking up the DNS zone ID" @(
    "network", "private-dns", "zone", "show", "--resource-group", $NetworkGroup, "--name", $DnsZone,
    "--query", "id", "--output", "tsv")
if (Test-AzResource @("network", "private-endpoint", "dns-zone-group", "show", "--resource-group", $AppGroup,
                      "--endpoint-name", $EndpointName, "--name", "default")) {
    Skip "DNS zone group"
} else {
    Invoke-Az "Registering the private endpoint in $DnsZone" @(
        "network", "private-endpoint", "dns-zone-group", "create", "--resource-group", $AppGroup,
        "--endpoint-name", $EndpointName, "--name", "default", "--private-dns-zone", $zoneId,
        "--zone-name", "sites", "--output", "none") | Out-Null
}

# 5. Check that the DNS records really exist (lesson from the database: the record was missing once)
$dnsConfigs = Invoke-Az "Looking up the private IP and names" @(
    "network", "private-endpoint", "show", "--resource-group", $AppGroup, "--name", $EndpointName,
    "--query", "customDnsConfigs[].[fqdn, ipAddresses[0]]", "--output", "tsv")
$privateIp = $null
foreach ($line in $dnsConfigs) {
    $parts = $line -split "\s+"
    $fqdn = $parts[0]; $ip = $parts[1]
    if (-not $privateIp) { $privateIp = $ip }
    $recordName = $fqdn -replace "\.azurewebsites\.net$", ""
    $existing = & az network private-dns record-set a show --resource-group $NetworkGroup --zone-name $DnsZone `
        --name $recordName --query "aRecords[0].ipv4Address" --output tsv --only-show-errors 2>$null
    if ($existing -eq $ip) {
        Skip "DNS record $recordName -> $ip"
    } else {
        Invoke-Az "Adding DNS record $recordName -> $ip" @(
            "network", "private-dns", "record-set", "a", "add-record", "--resource-group", $NetworkGroup,
            "--zone-name", $DnsZone, "--record-set-name", $recordName, "--ipv4-address", $ip,
            "--output", "none") | Out-Null
    }
}

# 6. Optional: turn off the public address
if ($DisablePublicAccess) {
    Invoke-Az "Turning off public access to the API" @(
        "webapp", "update", "--resource-group", $AppGroup, "--name", $AppName,
        "--set", "publicNetworkAccess=Disabled", "--output", "none") | Out-Null
    $publicState = "off (private only)"
} else {
    $publicState = "still on (turn off after the end-to-end test with -DisablePublicAccess)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    $AppName.azurewebsites.net now has private IP $privateIp"
Write-Host "    Public access: $publicState"
