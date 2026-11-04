<#
.SYNOPSIS
    Deploys the Knowledge Hub monitoring API to Azure App Service.

.DESCRIPTION
    1. Registers the Microsoft.Web resource provider if needed.
    2. Creates the resource group rg-kh-app-spain with tags.
    3. Creates a Linux App Service plan (Basic B1) and a Python web app.
    4. Turns on HTTPS only and a system-assigned managed identity.
    5. Connects the web app to snet-app in the spoke VNet (VNet integration).
    6. Puts the API key from .env and the Azure SQL server name in the app
       settings (never in the code). With SQL_SERVER set, the API uses Azure SQL.
    7. Uploads app.py and requirements.txt; Azure installs the packages.

    Safe to run more than once: existing resources are skipped, and the
    code is uploaded again, so you can also use it to deploy new versions.

.EXAMPLE
    .\deploy_api.ps1
#>

param(
    [string]$Location      = "spaincentral",
    [string]$AppGroup      = "rg-kh-app-spain",
    [string]$NetworkGroup  = "rg-kh-network-spain",
    [string]$SpokeVnet     = "vnet-spoke-monitoring-spain",
    [string]$AppSubnet     = "snet-app",
    [string]$PlanName      = "asp-kh-monitoring",
    [string]$AppName       = "app-kh-monitoring-yailin01",
    [string]$Sku           = "B1",
    [string]$Runtime       = "PYTHON:3.12",
    [string]$SqlServer     = "sql-kh-monitoring-yailin01.database.windows.net",
    [string]$SqlDatabase   = "sqldb-kh-monitoring"
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

# 0. Read the API key from .env (it is never printed)
if (-not (Test-Path ".env")) {
    Write-Host "FAILED: no .env file in this folder. Run the script from kh-monitoring." -ForegroundColor Red
    exit 1
}
$apiKeyLine = Get-Content ".env" | Where-Object { $_ -like "API_KEY=*" } | Select-Object -First 1
$apiKey = ($apiKeyLine -replace "^API_KEY=", "").Trim()
if (-not $apiKey) {
    Write-Host "FAILED: API_KEY not found in .env" -ForegroundColor Red
    exit 1
}

# 1. Login check
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"

# 2. Microsoft.Web resource provider (App Service), registered once per subscription
$webState = Invoke-Az "Checking the Microsoft.Web resource provider" @(
    "provider", "show", "--namespace", "Microsoft.Web", "--query", "registrationState", "--output", "tsv")
if ($webState -ne "Registered") {
    Invoke-Az "Registering Microsoft.Web (takes 1-2 minutes)" @(
        "provider", "register", "--namespace", "Microsoft.Web", "--wait") | Out-Null
}

# 3. Resource group with tags
Invoke-Az "Creating resource group $AppGroup in $Location" (@(
    "group", "create", "--name", $AppGroup, "--location", $Location,
    "--tags") + $Tags + @("--output", "none")) | Out-Null

# 4. App Service plan (Linux, Basic B1: the cheapest tier with VNet integration)
if (Test-AzResource @("appservice", "plan", "show", "--resource-group", $AppGroup, "--name", $PlanName)) {
    Skip "App Service plan $PlanName"
} else {
    Invoke-Az "Creating App Service plan $PlanName ($Sku, Linux)" (@(
        "appservice", "plan", "create", "--resource-group", $AppGroup, "--name", $PlanName,
        "--location", $Location, "--sku", $Sku, "--is-linux", "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 5. Web app with Python
if (Test-AzResource @("webapp", "show", "--resource-group", $AppGroup, "--name", $AppName)) {
    Skip "Web app $AppName"
} else {
    Invoke-Az "Creating web app $AppName ($Runtime)" (@(
        "webapp", "create", "--resource-group", $AppGroup, "--plan", $PlanName, "--name", $AppName,
        "--runtime", $Runtime, "--tags") + $Tags + @("--output", "none")) | Out-Null
}

# 6. HTTPS only, minimum TLS 1.2
Invoke-Az "Turning on HTTPS only" @(
    "webapp", "update", "--resource-group", $AppGroup, "--name", $AppName,
    "--https-only", "true", "--output", "none") | Out-Null
Invoke-Az "Setting minimum TLS version 1.2" @(
    "webapp", "config", "set", "--resource-group", $AppGroup, "--name", $AppName,
    "--min-tls-version", "1.2", "--output", "none") | Out-Null

# 7. Managed identity (used later to log in to Azure SQL without a password)
$principalId = Invoke-Az "Turning on the managed identity" @(
    "webapp", "identity", "assign", "--resource-group", $AppGroup, "--name", $AppName,
    "--query", "principalId", "--output", "tsv")
Write-Host "    Managed identity ID: $principalId"

# 8. VNet integration with snet-app (the subnet must be delegated to App Service)
$subnetId = Invoke-Az "Looking up $AppSubnet" @(
    "network", "vnet", "subnet", "show", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $AppSubnet, "--query", "id", "--output", "tsv")
Invoke-Az "Delegating $AppSubnet to App Service" @(
    "network", "vnet", "subnet", "update", "--resource-group", $NetworkGroup, "--vnet-name", $SpokeVnet,
    "--name", $AppSubnet, "--delegations", "Microsoft.Web/serverFarms", "--output", "none") | Out-Null
# (No brackets in the query: az.cmd on Windows can't handle them.)
$integrated = Invoke-Az "Checking the VNet integration" @(
    "webapp", "vnet-integration", "list", "--resource-group", $AppGroup, "--name", $AppName,
    "--query", "[].name", "--output", "tsv")
if ($integrated) {
    Skip "VNet integration"
} else {
    $vnetId = Invoke-Az "Looking up $SpokeVnet" @(
        "network", "vnet", "show", "--resource-group", $NetworkGroup, "--name", $SpokeVnet,
        "--query", "id", "--output", "tsv")
    Invoke-Az "Connecting the web app to $AppSubnet (VNet integration)" @(
        "webapp", "vnet-integration", "add", "--resource-group", $AppGroup, "--name", $AppName,
        "--vnet", $vnetId, "--subnet", $subnetId, "--output", "none") | Out-Null
}

# 9. App settings: the API key, and build the packages during deployment
Invoke-Az "Saving the API key in the app settings (not shown)" @(
    "webapp", "config", "appsettings", "set", "--resource-group", $AppGroup, "--name", $AppName,
    "--settings", "API_KEY=$apiKey", "SCM_DO_BUILD_DURING_DEPLOYMENT=true",
    "SQL_SERVER=$SqlServer", "SQL_DATABASE=$SqlDatabase",
    "--output", "none") | Out-Null

# Changing app settings restarts the app, including the deployment service (Kudu).
# Uploading straight away can then fail with HTTP 502, so wait until it is back.
Write-Host "==> Waiting 60 seconds for the app to restart after the settings change" -ForegroundColor Cyan
Start-Sleep -Seconds 60

# 10. Upload the code (only app.py and requirements.txt)
$zip = Join-Path $env:TEMP "kh-monitoring-deploy.zip"
Write-Host "==> Packing app.py and requirements.txt" -ForegroundColor Cyan
Compress-Archive -Path "app.py", "requirements.txt" -DestinationPath $zip -Force
Invoke-Az "Uploading the code (Azure installs the packages; takes 2-5 minutes)" @(
    "webapp", "deploy", "--resource-group", $AppGroup, "--name", $AppName,
    "--src-path", $zip, "--type", "zip", "--output", "none") | Out-Null
Remove-Item $zip

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    API: https://$AppName.azurewebsites.net"
Write-Host "    Test: Invoke-RestMethod https://$AppName.azurewebsites.net/health"
