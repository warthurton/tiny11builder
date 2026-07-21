param(
    [string]$SettingsPath = "$PSScriptRoot\PSScriptAnalyzerSettings.psd1"
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
} catch {
    Write-Error "PSScriptAnalyzer module is not installed. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    exit 2
}

$scriptFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File |
    Where-Object { $_.Name -ne [System.IO.Path]::GetFileName($PSCommandPath) } |
    Select-Object -ExpandProperty FullName

if (-not $scriptFiles) {
    Write-Output 'No PowerShell scripts found to analyze.'
    exit 0
}

$results = @()
foreach ($file in $scriptFiles) {
    $results += Invoke-ScriptAnalyzer -Path $file -Settings $SettingsPath
}

if (-not $results -or $results.Count -eq 0) {
    Write-Output 'PSScriptAnalyzer: no issues found.'
    exit 0
}

$results |
    Sort-Object ScriptName, Line, RuleName |
    Format-Table -AutoSize ScriptName, Line, Severity, RuleName, Message

$errors = @($results | Where-Object { $_.Severity -eq 'Error' })
$warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })

Write-Output "Summary: Errors=$($errors.Count) Warnings=$($warnings.Count)"

if ($errors.Count -gt 0) {
    exit 1
}

exit 0
