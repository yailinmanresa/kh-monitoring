<#
.SYNOPSIS
    Deploys the Azure SQL database for The Knowledge Hub monitoring API.

.DESCRIPTION
    Creates the data resource group, registers the Microsoft.Sql resource
    provider if needed, a logical SQL server that only accepts Microsoft
    Entra ID logins (no SQL passwords), and a database on the Basic tier
    (or on the free offer with -Tier Free, where the region supports it).

    The script is safe to run more than once: resources that already exist
    are skipped, not created twice.

.EXAMPLE
    .\deploy_database.ps1

.EXAMPLE
    .\deploy_database.ps1 -Tier Free -Location westeurope
#>

param(
    [string]$ResourceGroup = "rg-kh-data-spain",
    [string]$Location      = "spaincentral",
    [string]$ServerName    = "sql-kh-monitoring-yailin01",
    [string]$DatabaseName  = "sqldb-kh-monitoring",
    # Basic: about EUR 4-5 per month. Free: the Azure SQL free offer
    # (not available in every region, for example not in Spain Central).
    [ValidateSet("Basic", "Free")]
    [string]$Tier          = "Basic"
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

# 1. Check that we are logged in to Azure
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"

# 2. Resource group with tags (the policy requires the owner tag)
Invoke-Az "Creating resource group $ResourceGroup in $Location" (@(
    "group", "create", "--name", $ResourceGroup, "--location", $Location,
    "--tags") + $Tags + @("--output", "none")) | Out-Null

# 2b. Register the Microsoft.Sql resource provider (needed once per subscription)
$sqlState = Invoke-Az "Checking the Microsoft.Sql resource provider" @(
    "provider", "show", "--namespace", "Microsoft.Sql", "--query", "registrationState", "--output", "tsv")
if ($sqlState -ne "Registered") {
    Invoke-Az "Registering Microsoft.Sql (takes 1-2 minutes)" @(
        "provider", "register", "--namespace", "Microsoft.Sql", "--wait") | Out-Null
}

# 3. Find out who I am, so I become the Entra admin of the SQL server
$me = Invoke-Az "Looking up the signed-in user" @(
    "ad", "signed-in-user", "show", "--query", "{id:id, upn:userPrincipalName}", "--output", "json") | ConvertFrom-Json
Write-Host "    Entra admin will be: $($me.upn)"

# 4. Logical SQL server: Entra ID logins only, TLS 1.2 minimum
if (Test-AzResource @("sql", "server", "show", "--resource-group", $ResourceGroup, "--name", $ServerName)) {
    Write-Host "==> SQL server $ServerName already exists, skipping" -ForegroundColor Yellow
} else {
    Invoke-Az "Creating SQL server $ServerName (takes a few minutes)" @(
        "sql", "server", "create",
        "--resource-group", $ResourceGroup, "--name", $ServerName, "--location", $Location,
        "--enable-ad-only-auth",
        "--external-admin-principal-type", "User",
        "--external-admin-name", $me.upn,
        "--external-admin-sid", $me.id,
        "--minimal-tls-version", "1.2",
        "--output", "none") | Out-Null
}

# 5. Database: Basic tier by default, or the free offer with -Tier Free
if (Test-AzResource @("sql", "db", "show", "--resource-group", $ResourceGroup, "--server", $ServerName, "--name", $DatabaseName)) {
    Write-Host "==> Database $DatabaseName already exists, skipping" -ForegroundColor Yellow
} else {
    $dbArgs = @(
        "sql", "db", "create",
        "--resource-group", $ResourceGroup, "--server", $ServerName, "--name", $DatabaseName,
        "--backup-storage-redundancy", "Local",
        "--output", "none")
    if ($Tier -eq "Free") {
        # Serverless General Purpose with the free monthly limit; pauses when the limit is used up
        $dbArgs += @("--edition", "GeneralPurpose", "--compute-model", "Serverless",
                     "--family", "Gen5", "--capacity", "2",
                     "--use-free-limit", "true", "--free-limit-exhaustion-behavior", "AutoPause")
    } else {
        # Basic tier: 5 DTU, 2 GB, fixed low monthly price
        $dbArgs += @("--service-objective", "Basic", "--max-size", "2GB")
    }
    Invoke-Az "Creating database $DatabaseName ($Tier tier)" $dbArgs | Out-Null
}

# 6. Put the same tags on the server and the database, for Cost Management
$serverId = Invoke-Az "Looking up the server ID" @(
    "sql", "server", "show", "--resource-group", $ResourceGroup, "--name", $ServerName, "--query", "id", "--output", "tsv")
$databaseId = Invoke-Az "Looking up the database ID" @(
    "sql", "db", "show", "--resource-group", $ResourceGroup, "--server", $ServerName, "--name", $DatabaseName, "--query", "id", "--output", "tsv")
foreach ($id in @($serverId, $databaseId)) {
    Invoke-Az "Adding tags" (@("tag", "update", "--resource-id", $id, "--operation", "Merge", "--tags") + $Tags + @("--output", "none")) | Out-Null
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    Server:   $ServerName.database.windows.net"
Write-Host "    Database: $DatabaseName"
Write-Host "    No firewall rules are set, so nobody can connect yet. That's on purpose:"
Write-Host "    access will come through the private endpoint."
