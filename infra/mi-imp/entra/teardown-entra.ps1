<#
.SYNOPSIS
    Deletes the app registrations created by setup-entra.ps1. The managed identity's Graph grants
    are removed with the identity itself when its resource group is deleted.

.EXAMPLE
    ./teardown-entra.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ApiAppName = 'PoC API (MI)',
    [string] $SpaAppName = 'PoC SPA (MI)'
)

$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

foreach ($name in @($SpaAppName, $ApiAppName)) {
    $found = @(& az ad app list --display-name $name --output json | ConvertFrom-Json)
    if ($found.Count -eq 0) {
        Write-Host "No app registration named '$name'."
        continue
    }

    foreach ($app in $found) {
        if ($PSCmdlet.ShouldProcess("$name ($($app.appId))", 'Delete app registration')) {
            & az ad app delete --id $app.appId | Out-Null
            Write-Host "Deleted $name ($($app.appId))"
        }
    }
}

$outputFile = Join-Path $PSScriptRoot 'entra-output.json'
if (Test-Path $outputFile) {
    Remove-Item $outputFile -Force
    Write-Host "Removed $outputFile"
}
