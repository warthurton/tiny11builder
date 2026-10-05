$ErrorActionPreference = 'Stop'

$scriptFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File |
    Where-Object { $_.Name -ne [System.IO.Path]::GetFileName($PSCommandPath) } |
    Sort-Object Name

if (-not $scriptFiles) {
    Write-Output 'No PowerShell scripts found to syntax-check.'
    exit 0
}

$allErrors = @()

foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if (-not $parseErrors -or $parseErrors.Count -eq 0) {
        Write-Output ("PASS  {0}" -f $file.Name)
        continue
    }

    Write-Output ("FAIL  {0}" -f $file.Name)
    foreach ($parseError in $parseErrors) {
        $allErrors += [pscustomobject]@{
            ScriptName = $file.Name
            Line       = $parseError.Extent.StartLineNumber
            Column     = $parseError.Extent.StartColumnNumber
            Message    = $parseError.Message
        }
        Write-Output ("  Line {0}, Col {1}: {2}" -f $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
    }
}

Write-Output ''
Write-Output ("Summary: Files={0} ParseErrors={1}" -f $scriptFiles.Count, $allErrors.Count)

if ($allErrors.Count -gt 0) {
    exit 1
}

exit 0
