<#
.SYNOPSIS
    Sets up Azure Monitor for the Knowledge Hub monitoring API and database.

.DESCRIPTION
    1. Creates the resource group rg-kh-monitoring-spain and a Log Analytics workspace.
    2. Diagnostic settings: sends the logs and metrics of the API (App Service) and the
       database (Azure SQL) to the workspace.
    3. Creates an action group that emails the admin.
    4. Creates two alert rules:
       - Database CPU above 80% (5 minutes)
       - More than 5 rejected API requests (HTTP 4xx) in 5 minutes,
         for example someone trying wrong API keys
    Safe to run more than once.

.EXAMPLE
    .\deploy_monitoring.ps1 -Email you@example.com
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Email,
    [string]$Location     = "spaincentral",
    [string]$MonitorGroup = "rg-kh-monitoring-spain",
    [string]$AppGroup     = "rg-kh-app-spain",
    [string]$DataGroup    = "rg-kh-data-spain",
    [string]$AppName      = "app-kh-monitoring-yailin01",
    [string]$ServerName   = "sql-kh-monitoring-yailin01",
    [string]$DatabaseName = "sqldb-kh-monitoring",
    [string]$Workspace    = "log-kh-monitoring",
    [string]$ActionGroup  = "ag-kh-admin"
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

# 1. Login, provider, resource group
$subscription = Invoke-Az "Checking the Azure login" @("account", "show", "--query", "name", "--output", "tsv")
Write-Host "    Subscription: $subscription"
foreach ($provider in @("Microsoft.OperationalInsights", "Microsoft.Insights")) {
    $state = Invoke-Az "Checking the $provider resource provider" @(
        "provider", "show", "--namespace", $provider, "--query", "registrationState", "--output", "tsv")
    if ($state -ne "Registered") {
        Invoke-Az "Registering $provider (takes 1-2 minutes)" @(
            "provider", "register", "--namespace", $provider, "--wait") | Out-Null
    }
}
Invoke-Az "Creating resource group $MonitorGroup" (@(
    "group", "create", "--name", $MonitorGroup, "--location", $Location,
    "--tags") + $Tags + @("--output", "none")) | Out-Null

# 2. Log Analytics workspace (where logs and metrics are collected)
if (Test-AzResource @("monitor", "log-analytics", "workspace", "show", "--resource-group", $MonitorGroup, "--workspace-name", $Workspace)) {
    Skip "Log Analytics workspace $Workspace"
} else {
    Invoke-Az "Creating Log Analytics workspace $Workspace" (@(
        "monitor", "log-analytics", "workspace", "create", "--resource-group", $MonitorGroup,
        "--workspace-name", $Workspace, "--location", $Location, "--retention-time", "30",
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}
$workspaceId = Invoke-Az "Looking up the workspace ID" @(
    "monitor", "log-analytics", "workspace", "show", "--resource-group", $MonitorGroup,
    "--workspace-name", $Workspace, "--query", "id", "--output", "tsv")

# 3. Diagnostic settings: all logs + all metrics to the workspace
#    (The settings are written to small JSON files, because Windows mangles JSON on the command line.)
$logsFile = Join-Path $env:TEMP "kh-logs.json"
$metricsFile = Join-Path $env:TEMP "kh-metrics.json"
'[{"categoryGroup":"allLogs","enabled":true}]' | Out-File -Encoding ascii $logsFile
'[{"category":"AllMetrics","enabled":true}]'   | Out-File -Encoding ascii $metricsFile

$appId = Invoke-Az "Looking up the API" @(
    "webapp", "show", "--resource-group", $AppGroup, "--name", $AppName, "--query", "id", "--output", "tsv")
$dbId = Invoke-Az "Looking up the database" @(
    "sql", "db", "show", "--resource-group", $DataGroup, "--server", $ServerName, "--name", $DatabaseName,
    "--query", "id", "--output", "tsv")

foreach ($target in @(@{Name = "diag-api"; Id = $appId}, @{Name = "diag-database"; Id = $dbId})) {
    if (Test-AzResource @("monitor", "diagnostic-settings", "show", "--resource", $target.Id, "--name", $target.Name)) {
        Skip "Diagnostic setting $($target.Name)"
    } else {
        Invoke-Az "Sending logs and metrics to the workspace ($($target.Name))" @(
            "monitor", "diagnostic-settings", "create", "--name", $target.Name, "--resource", $target.Id,
            "--workspace", $workspaceId, "--logs", "@$logsFile", "--metrics", "@$metricsFile",
            "--output", "none") | Out-Null
    }
}
Remove-Item $logsFile, $metricsFile

# 4. Action group: email the admin
if (Test-AzResource @("monitor", "action-group", "show", "--resource-group", $MonitorGroup, "--name", $ActionGroup)) {
    Skip "Action group $ActionGroup"
} else {
    Invoke-Az "Creating action group $ActionGroup (email to $Email)" (@(
        "monitor", "action-group", "create", "--resource-group", $MonitorGroup, "--name", $ActionGroup,
        "--short-name", "khadmin", "--action", "email", "admin", $Email,
        "--tags") + $Tags + @("--output", "none")) | Out-Null
}
$actionGroupId = Invoke-Az "Looking up the action group ID" @(
    "monitor", "action-group", "show", "--resource-group", $MonitorGroup, "--name", $ActionGroup,
    "--query", "id", "--output", "tsv")

# 5. Alert rules
$alerts = @(
    @{
        Name        = "alert-sql-cpu-high"
        Scope       = $dbId
        Condition   = "avg cpu_percent > 80"
        Description = "Database CPU above 80 percent for 5 minutes"
        Severity    = "2"
    },
    @{
        Name        = "alert-api-rejected-requests"
        Scope       = $appId
        Condition   = "total Http4xx > 5"
        Description = "More than 5 rejected API requests (4xx) in 5 minutes, for example wrong API keys"
        Severity    = "3"
    }
)
foreach ($alert in $alerts) {
    if (Test-AzResource @("monitor", "metrics", "alert", "show", "--resource-group", $MonitorGroup, "--name", $alert.Name)) {
        Skip "Alert rule $($alert.Name)"
    } else {
        Invoke-Az "Creating alert rule $($alert.Name): $($alert.Description)" (@(
            "monitor", "metrics", "alert", "create", "--resource-group", $MonitorGroup, "--name", $alert.Name,
            "--scopes", $alert.Scope, "--condition", $alert.Condition,
            "--window-size", "5m", "--evaluation-frequency", "1m", "--severity", $alert.Severity,
            "--action", $actionGroupId, "--description", $alert.Description,
            "--tags") + $Tags + @("--output", "none")) | Out-Null
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "    Logs and metrics of the API and database go to Log Analytics ($Workspace)."
Write-Host "    Alerts email $Email when the database CPU is above 80%, or when more than"
Write-Host "    5 API requests are rejected within 5 minutes."
