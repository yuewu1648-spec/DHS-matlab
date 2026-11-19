# Convert every fixture's paper.docx to a text-based paper.pdf using the
# bundled LibreOffice Kit (no system LibreOffice installation required).
#
# Usage:
#   pwsh -File tests/fixtures/tools/convert_pdfs.ps1 [-Force]
#
# The PDF writer embeds timestamps, so output is reproducible only in content.

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$node = 'C:\Users\LEGION\AppData\Local\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
$cli  = 'C:\Users\LEGION\AppData\Local\Programs\DeepSeek Harness\resources\app.asar.unpacked\dsh\node_modules\@deepseek-ai\libreoffice-kit\lib\cli.js'

if (-not (Test-Path -LiteralPath $node)) { throw "node not found: $node" }
if (-not (Test-Path -LiteralPath $cli))  { throw "libreoffice-kit cli not found: $cli" }

$fixturesRoot = Split-Path -Parent $PSScriptRoot   # tools -> tests/fixtures
$papers = Get-ChildItem -Path (Join-Path $fixturesRoot 'literature') -Directory |
          ForEach-Object { Join-Path $_.FullName 'paper.docx' } |
          Where-Object { Test-Path -LiteralPath $_ }

if (-not $papers) { throw "no paper.docx found under $fixturesRoot/literature (run make_fixtures.py convert first)" }

$failed = 0
foreach ($docx in $papers) {
    $pdf = [System.IO.Path]::ChangeExtension($docx, '.pdf')
    $dir = Split-Path -Parent $docx
    $name = Split-Path -Leaf $dir
    if ((-not $Force) -and (Test-Path -LiteralPath $pdf) -and
        ((Get-Item -LiteralPath $pdf).LastWriteTime -ge (Get-Item -LiteralPath $docx).LastWriteTime)) {
        Write-Host "[skip] $name : paper.pdf is up to date"
        continue
    }
    Write-Host "[convert] $name : paper.docx -> paper.pdf"
    $out = & $node $cli convert --input $docx --output $pdf 2>&1
    $out | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pdf)) {
        Write-Warning "[fail] $name : conversion failed"
        $failed++
        continue
    }
    $head = [System.IO.File]::ReadAllBytes($pdf)[0..4]
    $sig = [System.Text.Encoding]::ASCII.GetString($head)
    if ($sig -ne '%PDF-') {
        Write-Warning "[fail] $name : output is not a PDF (signature '$sig')"
        $failed++
        continue
    }
    $size = (Get-Item -LiteralPath $pdf).Length
    Write-Host ("[ok] {0} : {1:N0} bytes" -f $name, $size)
}

if ($failed -gt 0) { throw "$failed PDF conversion(s) failed" }
Write-Host "all fixture PDFs ready."
