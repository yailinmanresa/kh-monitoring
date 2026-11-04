<#
.SYNOPSIS
    Temporarily opens the SQL server for my own IP address, or closes it again.

.DESCRIPTION
    The SQL server normally has public access turned off: it is only reachable
    through the private endpoint. To run setup_database.sql once in the portal's
    Query editor, my own IP needs short access.

    -Open : turns public access on and allows ONLY my current IP address.
    -Close: removes that rule and turns public access off again.

.EXAMPLE
    .\sql_access.ps1 -Open
    .\sql_access.ps1 -Close
#>

param(
    [switch]$Open,
    [switch]$Close,
    [string]$DataGroup  = "rg-kh-data-spain",
    [string]$ServerName = "sql-kh-monitoring-yailin01",
    [string]$RuleName   = "temp-admin-access"
)

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

if ($Open -eq $Close) {
    Write-Host "Use exactly one: -Open or -Close" -ForegroundColor Red
    exit 1
}

if ($Open) {
    $myIp = (Invoke-RestMethod "https://api.ipify.org").Trim()
    Write-Host "    My public IP: $myIp"
    Invoke-Az "Turning on public access (temporarily)" @(
        "sql", "server", "update", "--resource-group", $DataGroup, "--name", $ServerName,
        "--enable-public-network", "true", "--output", "none") | Out-Null
    Invoke-Az "Allowing only my IP ($myIp)" @(
        "sql", "server", "firewall-rule", "create", "--resource-group", $DataGroup, "--server", $ServerName,
        "--name", $RuleName, "--start-ip-address", $myIp, "--end-ip-address", $myIp, "--output", "none") | Out-Null
    Write-Host ""
    Write-Host "Open for $myIp only. Run setup_database.sql in the Query editor," -ForegroundColor Yellow
    Write-Host "then close it again with:  .\sql_access.ps1 -Close" -ForegroundColor Yellow
}

if ($Close) {
    & az sql server firewall-rule delete --resource-group $DataGroup --server $ServerName --name $RuleName --only-show-errors 2>$null
    Write-Host "==> Removed the firewall rule (if it was there)" -ForegroundColor Cyan
    Invoke-Az "Turning public access off again" @(
        "sql", "server", "update", "--resource-group", $DataGroup, "--name", $ServerName,
        "--enable-public-network", "false", "--output", "none") | Out-Null
    Write-Host ""
    Write-Host "Closed. The database is only reachable through the private endpoint again." -ForegroundColor Green
}
