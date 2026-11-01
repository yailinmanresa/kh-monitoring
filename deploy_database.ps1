<#
.SYNOPSIS
    Deploys the Azure SQL database for The Knowledge Hub monitoring API.

.DESCRIPTION
    Creates the data resource group, a logical SQL server that only accepts
    Microsoft Entra ID logins (no SQL passwords), and a database on the
    Azure SQL free offer. The database pauses when the free monthly limit
    is reached, so it can never cost money.

    The script is safe to run more than once: resources that already exist
    are skipped, not created twice.

.EXAMPLE
    .\deploy_database.ps1

.EXAMPLE
    .\deploy_database.ps1 -ServerName sql-kh-monitoring-ym02
#>

param(
    [string]$ResourceGroup = "rg-kh-data-spain",
    [string]$Location      = "spaincentral",
    [string]$ServerName    = "sql-kh-monitoring-ym01",
    [string]$DatabaseName  = "sqldb-kh-monitoring"
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

# 5. Database on the free offer, paused automatically when the free limit is used up
if (Test-AzResource @("sql", "db", "show", "--resource-group", $ResourceGroup, "--server", $ServerName, "--name", $DatabaseName)) {
    Write-Host "==> Database $DatabaseName already exists, skipping" -ForegroundColor Yellow
} else {
    Invoke-Az "Creating database $DatabaseName on the free offer" @(
        "sql", "db", "create",
        "--resource-group", $ResourceGroup, "--server", $ServerName, "--name", $DatabaseName,
        "--edition", "GeneralPurpose", "--compute-model", "Serverless",
        "--family", "Gen5", "--capacity", "2",
        "--use-free-limit", "true",
        "--free-limit-exhaustion-behavior", "AutoPause",
        "--backup-storage-redundancy", "Local",
        "--output", "none") | Out-Null
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
