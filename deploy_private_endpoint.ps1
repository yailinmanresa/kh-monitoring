<#
.SYNOPSIS
    Makes the Azure SQL database private: private endpoint, private DNS and an NSG.

.DESCRIPTION
    1. Turns on network policies on snet-privateendpoints, so NSG rules apply.
    2. Creates the NSG nsg-privateendpoints with the rules from the LO2 design
       and attaches it to snet-privateendpoints.
    3. Creates a private endpoint for the SQL server in snet-privateendpoints.
    4. Creates the private DNS zone privatelink.database.windows.net, links it
       to the hub and spoke VNets, and registers the private endpoint in it.
    5. Turns off public network access on the SQL server.

    Safe to run more than once: existing resources are skipped.

.EXAMPLE
    .\deploy_private_endpoint.ps1
#>

param(
    [string]$Location        = "spaincentral",
    [string]$NetworkGroup    = "rg-kh-network-spain",
    [string]$DataGroup       = "rg-kh-data-spain",
    [string]$HubVnet         = "vnet-hub-spain",
    [string]$SpokeVnet       = "vnet-spoke-monitoring-spain",
    [string]$EndpointSubnet  = "snet-privateendpoints",
    [string]$ServerName      = "sql-kh-monitoring-yailin01",
    [string]$EndpointName    = "pe-sql-kh-monitoring",
    [string]$NsgName         = "nsg-privateendpoints",
    [string]$DnsZone         = "privatelink.database.windows.net"
)

$Tags = @("project=knowledgehub-cs2", "environment=lab", "owner=admin", "costcenter=it")

# Runs one az command. Stops the whole script if the command fails.
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

# Returns $true if an az "show" command finds the resource.
function Test-AzResource {
    param([string[]]$Arguments)
    & az @Arguments --only-show-errors --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Skip([string]$What) {
    Write-Host "==> $What already exists, skipping" -ForegroundColor Yellow
}

# 1. Check the login and look up the IDs we need
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"

$serverId = Invoke-Az "Looking up the SQL server" @(
    "sql", "server", "show", "--resource-group", $DataGroup, "--name", $ServerName, "--query", "id", "--output", "tsv")
$subnetId = Invoke-Az "Looking up $EndpointSubnet" @(
    "network", "vnet", "subnet", "show", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $EndpointSubnet, "--query", "id", "--output", "tsv")
$hubId = Invoke-Az "Looking up $HubVnet" @(
    "network", "vnet", "show", "--resource-group", $NetworkGroup, "--name", $HubVnet, "--query", "id", "--output", "tsv")
$spokeId = Invoke-Az "Looking up $SpokeVnet" @(
    "network", "vnet", "show", "--resource-group", $NetworkGroup, "--name", $SpokeVnet, "--query", "id", "--output", "tsv")

# 2. Network policies on the subnet, so the NSG rules also apply to private endpoints
Invoke-Az "Turning on network policies on $EndpointSubnet" @(
    "network", "vnet", "subnet", "update", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $EndpointSubnet, "--private-endpoint-network-policies", "Enabled", "--output", "none") | Out-Null

# 3. NSG with the rules from the LO2 design (least privilege, explicit deny)
if (Test-AzResource @("network", "nsg", "show", "--resource-group", $NetworkGroup, "--name", $NsgName)) {
    Skip "NSG $NsgName"
} else {
    Invoke-Az "Creating NSG $NsgName" (@(
        "network", "nsg", "create", "--resource-group", $NetworkGroup, "--name", $NsgName,
        "--location", $Location, "--tags") + $Tags + @("--output", "none")) | Out-Null

    Invoke-Az "Rule 100: the API (snet-app) may reach SQL on port 1433" @(
        "network", "nsg", "rule", "create", "--resource-group", $NetworkGroup, "--nsg-name", $NsgName,
        "--name", "Allow-App-To-SQL", "--priority", "100", "--direction", "Inbound", "--access", "Allow",
        "--protocol", "Tcp", "--source-address-prefixes", "10.20.1.0/24", "--source-port-ranges", "*",
        "--destination-address-prefixes", "10.20.2.0/24", "--destination-port-ranges", "1433",
        "--output", "none") | Out-Null

    Invoke-Az "Rule 110: on-prem servers may reach the API on port 443" @(
        "network", "nsg", "rule", "create", "--resource-group", $NetworkGroup, "--nsg-name", $NsgName,
        "--name", "Allow-OnPrem-To-API", "--priority", "110", "--direction", "Inbound", "--access", "Allow",
        "--protocol", "Tcp", "--source-address-prefixes", "192.168.1.0/24", "--source-port-ranges", "*",
        "--destination-address-prefixes", "10.20.2.0/24", "--destination-port-ranges", "443",
        "--output", "none") | Out-Null

    Invoke-Az "Rule 4000: deny everything else" @(
        "network", "nsg", "rule", "create", "--resource-group", $NetworkGroup, "--nsg-name", $NsgName,
        "--name", "Deny-All-Inbound", "--priority", "4000", "--direction", "Inbound", "--access", "Deny",
        "--protocol", "*", "--source-address-prefixes", "*", "--source-port-ranges", "*",
        "--destination-address-prefixes", "*", "--destination-port-ranges", "*",
        "--output", "none") | Out-Null
}

Invoke-Az "Attaching $NsgName to $EndpointSubnet" @(
    "network", "vnet", "subnet", "update", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $EndpointSubnet, "--network-security-group", $NsgName, "--output", "none") | Out-Null

# 4. Private endpoint for the SQL server
if (Test-AzResource @("network", "private-endpoint", "show", "--resource-group", $DataGroup, "--name", $EndpointName)) {
    Skip "Private endpoint $EndpointName"
} else {
    Invoke-Az "Creating private endpoint $EndpointName (takes 1-2 minutes)" (@(
        "network", "private-endpoint", "create", "--resource-group", $DataGroup, "--name", $EndpointName,
        "--location", $Location, "--subnet", $subnetId,
        "--private-connection-resource-id", $serverId, "--group-id", "sqlServer",
        "--connection-name", "$EndpointName-connection", "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 5. Private DNS zone, linked to both VNets
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

# 6. Let the private endpoint write its own record in the DNS zone
$zoneId = Invoke-Az "Looking up the DNS zone ID" @(
    "network", "private-dns", "zone", "show", "--resource-group", $NetworkGroup, "--name", $DnsZone,
    "--query", "id", "--output", "tsv")
if (Test-AzResource @("network", "private-endpoint", "dns-zone-group", "show", "--resource-group", $DataGroup,
                      "--endpoint-name", $EndpointName, "--name", "default")) {
    Skip "DNS zone group"
} else {
    Invoke-Az "Registering the private endpoint in $DnsZone" @(
        "network", "private-endpoint", "dns-zone-group", "create", "--resource-group", $DataGroup,
        "--endpoint-name", $EndpointName, "--name", "default", "--private-dns-zone", $zoneId,
        "--zone-name", "sql", "--output", "none") | Out-Null
}

# 7. No more public access to the SQL server
Invoke-Az "Turning off public network access on $ServerName" @(
    "sql", "server", "update", "--resource-group", $DataGroup, "--name", $ServerName,
    "--enable-public-network", "false", "--output", "none") | Out-Null

# 8. Show the result
$privateIp = Invoke-Az "Looking up the private IP" @(
    "network", "private-endpoint", "show", "--resource-group", $DataGroup, "--name", $EndpointName,
    "--query", "customDnsConfigs[0].ipAddresses[0]", "--output", "tsv")

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    $ServerName.database.windows.net now points to $privateIp (private)"
Write-Host "    Public network access: off"
Write-Host "    NSG $NsgName attached to $EndpointSubnet"
