<#
.SYNOPSIS
    Redeploys the Site-to-Site VPN between Azure and pfSense (The Knowledge Hub).

.DESCRIPTION
    1. Creates a static public IP for the VPN Gateway.
    2. Creates the VPN Gateway (route-based, Basic SKU) in the GatewaySubnet of the hub.
       This takes about 30-45 minutes.
    3. Checks the local network gateway (the on-prem side: public IP + LAN ranges).
    4. Creates the IPsec connection with the pre-shared key. The key is asked for
       on screen and never stored in this script or in Git.
    5. Turns on gateway transit on the peering, so on-prem can also reach the spoke.
    6. Shows the new public IP to fill in as "Remote Gateway" in pfSense.

    The VPN Gateway costs money for every hour it exists. Delete it after testing with:
        az network vnet-gateway delete -g rg-kh-network-spain -n vpngw-hub-spain

.EXAMPLE
    .\deploy_vpn.ps1
#>

param(
    [string]$Location       = "spaincentral",
    [string]$NetworkGroup   = "rg-kh-network-spain",
    [string]$HubVnet        = "vnet-hub-spain",
    [string]$SpokeVnet      = "vnet-spoke-monitoring-spain",
    [string]$GatewayName    = "vpngw-hub-spain",
    [string]$PublicIpName   = "pip-vpngw-spain",
    [string]$LocalGateway   = "lng-knowledgehub-onprem",
    [string]$ConnectionName = "cn-hub-to-knowledgehub",
    [string]$OnPremPublicIp = "145.220.72.5"
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

# 0. Ask for the pre-shared key (the same one as in pfSense). It is not shown or stored.
$secureKey = Read-Host "Pre-shared key (the same as in pfSense Phase 1)" -AsSecureString
$psk = [System.Net.NetworkCredential]::new("", $secureKey).Password
if (-not $psk) {
    Write-Host "FAILED: no pre-shared key entered" -ForegroundColor Red
    exit 1
}

# 1. Login check
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"

# 2. Public IP for the gateway
if (Test-AzResource @("network", "public-ip", "show", "--resource-group", $NetworkGroup, "--name", $PublicIpName)) {
    Skip "Public IP $PublicIpName"
} else {
    Invoke-Az "Creating public IP $PublicIpName (static)" (@(
        "network", "public-ip", "create", "--resource-group", $NetworkGroup, "--name", $PublicIpName,
        "--location", $Location, "--sku", "Standard", "--allocation-method", "Static",
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 3. VPN Gateway (the slow part)
if (Test-AzResource @("network", "vnet-gateway", "show", "--resource-group", $NetworkGroup, "--name", $GatewayName)) {
    Skip "VPN Gateway $GatewayName"
} else {
    Invoke-Az "Creating VPN Gateway $GatewayName (Basic, route-based). This takes 30-45 minutes" (@(
        "network", "vnet-gateway", "create", "--resource-group", $NetworkGroup, "--name", $GatewayName,
        "--location", $Location, "--vnet", $HubVnet, "--public-ip-addresses", $PublicIpName,
        "--gateway-type", "Vpn", "--vpn-type", "RouteBased", "--sku", "Basic",
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 4. Local network gateway: make sure it has the current on-prem public IP
if (Test-AzResource @("network", "local-gateway", "show", "--resource-group", $NetworkGroup, "--name", $LocalGateway)) {
    $currentIp = Invoke-Az "Checking local network gateway $LocalGateway" @(
        "network", "local-gateway", "show", "--resource-group", $NetworkGroup, "--name", $LocalGateway,
        "--query", "gatewayIpAddress", "--output", "tsv")
    if ($currentIp -ne $OnPremPublicIp) {
        Invoke-Az "Updating the on-prem public IP to $OnPremPublicIp" @(
            "network", "local-gateway", "update", "--resource-group", $NetworkGroup, "--name", $LocalGateway,
            "--gateway-ip-address", $OnPremPublicIp, "--output", "none") | Out-Null
    } else {
        Write-Host "    On-prem public IP is $currentIp (correct)"
    }
} else {
    Invoke-Az "Creating local network gateway $LocalGateway" (@(
        "network", "local-gateway", "create", "--resource-group", $NetworkGroup, "--name", $LocalGateway,
        "--location", $Location, "--gateway-ip-address", $OnPremPublicIp,
        "--local-address-prefixes", "192.168.1.0/24", "192.168.2.0/24", "192.168.3.0/24", "192.168.4.0/24",
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 5. The IPsec connection (IKEv2, with the pre-shared key)
if (Test-AzResource @("network", "vpn-connection", "show", "--resource-group", $NetworkGroup, "--name", $ConnectionName)) {
    Skip "Connection $ConnectionName"
} else {
    Invoke-Az "Creating connection $ConnectionName (IPsec, IKEv2)" (@(
        "network", "vpn-connection", "create", "--resource-group", $NetworkGroup, "--name", $ConnectionName,
        "--location", $Location, "--vnet-gateway1", $GatewayName, "--local-gateway2", $LocalGateway,
        "--shared-key", $psk, "--tags") + $Tags + @("--output", "none")) | Out-Null
}
$psk = $null

# 6. Gateway transit: the spoke may use the hub's VPN Gateway
$hubPeering = Invoke-Az "Looking up the hub peering" @(
    "network", "vnet", "peering", "list", "--resource-group", $NetworkGroup, "--vnet-name", $HubVnet,
    "--query", "[0].name", "--output", "tsv")
$spokePeering = Invoke-Az "Looking up the spoke peering" @(
    "network", "vnet", "peering", "list", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--query", "[0].name", "--output", "tsv")
Invoke-Az "Hub side: Allow gateway transit ($hubPeering)" @(
    "network", "vnet", "peering", "update", "--resource-group", $NetworkGroup, "--vnet-name", $HubVnet,
    "--name", $hubPeering, "--set", "allowGatewayTransit=true", "--output", "none") | Out-Null
Invoke-Az "Spoke side: Use remote gateway ($spokePeering)" @(
    "network", "vnet", "peering", "update", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $spokePeering, "--set", "useRemoteGateways=true", "--output", "none") | Out-Null

# 7. Result
$gatewayIp = Invoke-Az "Looking up the VPN Gateway's public IP" @(
    "network", "public-ip", "show", "--resource-group", $NetworkGroup, "--name", $PublicIpName,
    "--query", "ipAddress", "--output", "tsv")

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    New VPN Gateway public IP: $gatewayIp"
Write-Host "    In pfSense: VPN > IPsec > edit Phase 1 > Remote Gateway = $gatewayIp > Save > Apply Changes"
Write-Host "    Remember: the gateway costs money every hour. Delete it after testing."
