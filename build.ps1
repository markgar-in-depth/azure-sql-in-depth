#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build the Azure SQL In Depth epub from manuscript sources.
.DESCRIPTION
    Assembles metadata, frontmatter, chapters, appendices, and backmatter
    in book order and runs Pandoc to produce an epub3 file.
#>
param(
    [string]$Output = "Azure-SQL-In-Depth.epub"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Find Pandoc ---
$pandoc = $null
if (Get-Command pandoc -ErrorAction SilentlyContinue) {
    $pandoc = 'pandoc'
} elseif (Test-Path 'C:\Program Files\Pandoc\pandoc.exe') {
    $pandoc = 'C:\Program Files\Pandoc\pandoc.exe'
}

if (-not $pandoc) {
    Write-Error "Pandoc not found. Install from https://pandoc.org/installing.html"
    exit 1
}

Write-Host "Using Pandoc: $pandoc"
& $pandoc --version | Select-Object -First 1

# --- Assemble sources in book order ---
$sources = @()

# Metadata
$sources += 'assets/metadata.yaml'

# Frontmatter (copyright before preface, skip title-page — epub has its own)
$sources += 'manuscript/frontmatter/copyright.md'
$sources += 'manuscript/frontmatter/preface.md'

# Chapters (sorted by filename, exclude review files)
$sources += Get-ChildItem 'manuscript/chapters/ch*.md' |
    Where-Object { $_.Name -notmatch 'review' } |
    Sort-Object Name |
    ForEach-Object { $_.FullName }

# Appendices (sorted by filename, exclude review files)
$sources += Get-ChildItem 'manuscript/chapters/app*.md' |
    Where-Object { $_.Name -notmatch 'review' } |
    Sort-Object Name |
    ForEach-Object { $_.FullName }

# Backmatter
$sources += 'manuscript/backmatter/about-the-author.md'

Write-Host "`nAssembling $($sources.Count) source files..."

# --- Build output directory ---
if (-not (Test-Path 'build')) {
    New-Item -ItemType Directory -Path 'build' | Out-Null
}

$outputPath = "build/$Output"

# --- Pandoc arguments ---
$args = @(
    '--from', 'markdown'
    '--to', 'epub3'
    '--toc'
    '--toc-depth=2'
    "--css=assets/epub.css"
    '-o', $outputPath
)

# Optional cover image
if (Test-Path 'assets/cover.png') {
    $args += '--epub-cover-image=assets/cover.png'
    Write-Host "Cover image: assets/cover.png"
}

# --- Run Pandoc ---
Write-Host "Building epub..."
& $pandoc @args @sources

if ($LASTEXITCODE -ne 0) {
    Write-Error "Pandoc failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# --- Report ---
$file = Get-Item $outputPath
$sizeMB = [math]::Round($file.Length / 1MB, 2)
Write-Host "`n✅ Built: $outputPath ($sizeMB MB)"
