<#
    Renders this repo's markdown docs to print-friendly PDFs under docs\pdf\.

    Requires PowerShell 7+ (pwsh) for ConvertFrom-Markdown (Markdig-backed) -- NOT the repo's
    PowerShell-5.1 requirement, since this is a docs convenience tool, independent of the
    Windows-image build pipeline. Run it as:

        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Export-RepoDocsToPdf.ps1

    Also requires Microsoft Edge (used headless for --print-to-pdf rendering); no other external
    dependency. Regenerate after editing any source doc -- nothing here detects staleness.
#>
param(
    [string[]]$Path = (Join-Path $PSScriptRoot 'docs\*.md'),
    [string]$OutputDir = (Join-Path $PSScriptRoot 'docs\pdf')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Export-RepoDocsToPdf.ps1 requires PowerShell 7+ for ConvertFrom-Markdown. Run it via: pwsh -NoProfile -ExecutionPolicy Bypass -File .\Export-RepoDocsToPdf.ps1"
}

function Find-EdgeExecutable {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    $onPath = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }
    throw "Could not find msedge.exe (checked Program Files, Program Files (x86), and PATH)."
}

function ConvertTo-PrintableHtml {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$BodyHtml
    )

    return @"
<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>$Title</title>
<style>
  @page { size: A4; margin: 18mm 16mm; }
  body {
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 11pt;
    line-height: 1.45;
    color: #1a1a1a;
    max-width: 920px;
    margin: 0 auto;
  }
  h1, h2, h3, h4 { font-family: Calibri, Arial, sans-serif; color: #10243a; page-break-after: avoid; }
  h1 { font-size: 20pt; border-bottom: 2px solid #10243a; padding-bottom: 6px; }
  h2 { font-size: 15pt; margin-top: 1.6em; border-bottom: 1px solid #b8c4d0; padding-bottom: 3px; }
  h3 { font-size: 12.5pt; margin-top: 1.3em; }
  code, pre { font-family: Consolas, 'Courier New', monospace; font-size: 9.5pt; }
  code { background: #eef1f4; padding: 1px 4px; border-radius: 3px; }
  pre { background: #eef1f4; padding: 10px; border-radius: 4px; overflow-wrap: break-word; white-space: pre-wrap; page-break-inside: avoid; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 9.5pt; page-break-inside: avoid; }
  th, td { border: 1px solid #b8c4d0; padding: 5px 8px; text-align: left; vertical-align: top; }
  th { background: #10243a; color: white; }
  tr:nth-child(even) td { background: #f4f6f8; }
  ul.contains-task-list { list-style: none; padding-left: 0.5em; }
  li.task-list-item input { margin-right: 6px; }
  blockquote { border-left: 3px solid #b8c4d0; margin: 0.8em 0; padding: 0.2em 1em; color: #444; }
  a { color: #0b5fa5; }
  hr { border: none; border-top: 1px solid #b8c4d0; margin: 1.5em 0; }
</style>
</head>
<body>
$BodyHtml
</body>
</html>
"@
}

$mdFiles = @(Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue | Sort-Object Name)

if ($mdFiles.Count -eq 0) {
    Write-Host "No markdown files matched: $Path"
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$edgePath = Find-EdgeExecutable
Write-Host "Using Edge: $edgePath"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("asl-win11-docs-pdf-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$failed = @()

try {
    foreach ($md in $mdFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($md.Name)
        $pdfPath = Join-Path $OutputDir "$baseName.pdf"
        $htmlPath = Join-Path $tempDir "$baseName.html"

        try {
            $converted = ConvertFrom-Markdown -Path $md.FullName
            $html = ConvertTo-PrintableHtml -Title $baseName -BodyHtml $converted.Html
            Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

            $fileUri = 'file:///' + ($htmlPath -replace '\\', '/')
            $pdfArg = '--print-to-pdf=' + $pdfPath

            & $edgePath '--headless=new' '--disable-gpu' $pdfArg '--print-to-pdf-no-header' $fileUri 2>$null | Out-Null

            if (-not (Test-Path -LiteralPath $pdfPath) -or (Get-Item -LiteralPath $pdfPath).Length -eq 0) {
                throw "Edge did not produce a non-empty PDF."
            }

            Write-Host ("PASS  {0,-40} -> {1}" -f $md.Name, (Resolve-Path -Relative $pdfPath))
        } catch {
            $failed += $md.Name
            Write-Host ("FAIL  {0,-40} -> {1}" -f $md.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Summary: Files={0} Failed={1}" -f $mdFiles.Count, $failed.Count)

if ($failed.Count -gt 0) {
    exit 1
}

exit 0
