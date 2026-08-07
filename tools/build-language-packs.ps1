[CmdletBinding()]
param(
    [string]$ReleaseTag = "packs-v1.1.0"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$downloadsRoot = Join-Path $repoRoot "downloads"
$workRoot = Join-Path $repoRoot "work"
$distRoot = Join-Path $repoRoot "dist"
$sourceIndexPath = Join-Path $PSScriptRoot "model-sources.json"
$licensePath = Join-Path $repoRoot "licenses\APACHE-2.0.txt"
$manifestPath = Join-Path $repoRoot "manifest.json"
$releaseBaseUrl = "https://github.com/LeKyks77/voice-destroy-language-packs/releases/download/$ReleaseTag"
$fixedTimestamp = [DateTimeOffset]::new(2024, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Sha256([string]$Path, [int]$ProgressId = 0, [string]$Activity = "Calcul SHA-256") {
    if ($ProgressId -le 0) {
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = [byte[]]::new(1048576)
        $processed = [long]0
        $total = [long]$stream.Length
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $processed += $read
            if ($stopwatch.ElapsedMilliseconds -ge 200) {
                $percent = if ($total -gt 0) { [Math]::Min(100, [int](100 * $processed / $total)) } else { 100 }
                Write-Progress -Id $ProgressId -Activity $Activity -Status ("{0}% · {1:N1}/{2:N1} Mo" -f $percent, ($processed / 1MB), ($total / 1MB)) -PercentComplete $percent
                $stopwatch.Restart()
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '')
    } finally {
        Write-Progress -Id $ProgressId -Activity $Activity -Completed
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Assert-SafeRelativePath([string]$Path) {
    $normalized = $Path.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $normalized.StartsWith('/') -or
        $normalized.Contains(':') -or
        ($normalized.Split('/') -contains '..')) {
        throw "Unsafe path in archive: $Path"
    }
    return $normalized
}

function Expand-VerifiedModel(
    [string]$ArchivePath,
    [string]$ExpectedRoot,
    [string]$Destination,
    [int]$ProgressId = 0,
    [string]$Activity = "Extraction du modèle"
) {
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    [IO.Directory]::CreateDirectory($destinationFull) | Out-Null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $totalBytes = [long](($archive.Entries | Measure-Object -Property Length -Sum).Sum)
        $processedBytes = [long]0
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($entry in $archive.Entries) {
            $entryPath = Assert-SafeRelativePath $entry.FullName
            $segments = $entryPath.Split('/')
            if ($segments[0] -ne $ExpectedRoot) {
                throw "Unexpected model root '$($segments[0])'; expected '$ExpectedRoot'."
            }
            if ($segments.Count -eq 1 -or [string]::IsNullOrEmpty($entry.Name)) { continue }
            $relativePath = [string]::Join('/', $segments[1..($segments.Count - 1)])
            if (-not $seen.Add($relativePath)) { throw "Duplicate path in archive: $relativePath" }
            $targetPath = [IO.Path]::GetFullPath((Join-Path $Destination $relativePath))
            if (-not $targetPath.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive path escapes destination: $relativePath"
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
            $input = $entry.Open()
            $output = [IO.File]::Create($targetPath)
            try {
                $buffer = [byte[]]::new(1048576)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $output.Write($buffer, 0, $read)
                    $processedBytes += $read
                    if ($ProgressId -gt 0 -and $stopwatch.ElapsedMilliseconds -ge 200) {
                        $percent = if ($totalBytes -gt 0) { [Math]::Min(100, [int](100 * $processedBytes / $totalBytes)) } else { 100 }
                        Write-Progress -Id $ProgressId -Activity $Activity -Status ("{0}% · {1:N1}/{2:N1} Mo" -f $percent, ($processedBytes / 1MB), ($totalBytes / 1MB)) -PercentComplete $percent
                        $stopwatch.Restart()
                    }
                }
            } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally {
        if ($ProgressId -gt 0) { Write-Progress -Id $ProgressId -Activity $Activity -Completed }
        $archive.Dispose()
    }

    foreach ($required in @("am\final.mdl", "conf\mfcc.conf", "conf\model.conf", "graph\phones\word_boundary.int")) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $required) -PathType Leaf)) {
            throw "Required Vosk model file is missing: $required"
        }
    }
    $hasMonolithicGraph = Test-Path -LiteralPath (Join-Path $Destination "graph\HCLG.fst") -PathType Leaf
    $hasCompactGraph =
        (Test-Path -LiteralPath (Join-Path $Destination "graph\HCLr.fst") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Destination "graph\Gr.fst") -PathType Leaf)
    if (-not $hasMonolithicGraph -and -not $hasCompactGraph) {
        throw "The Vosk decoding graph is incomplete (expected HCLG.fst or HCLr.fst + Gr.fst)."
    }
}

function New-DeterministicZip(
    [string]$SourceDirectory,
    [string]$DestinationZip,
    [int]$ProgressId = 0,
    [string]$Activity = "Compression du pack"
) {
    if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
    $sourceFull = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $output = [IO.File]::Open($DestinationZip, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($output, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $files = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File |
            Sort-Object { $_.FullName.Substring($sourceFull.Length).Replace('\', '/') })
        $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        $processedBytes = [long]0
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($file in $files) {
            $entryName = $file.FullName.Substring($sourceFull.Length).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $input = [IO.File]::OpenRead($file.FullName)
            $entryStream = $entry.Open()
            try {
                $buffer = [byte[]]::new(1048576)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryStream.Write($buffer, 0, $read)
                    $processedBytes += $read
                    if ($ProgressId -gt 0 -and $stopwatch.ElapsedMilliseconds -ge 200) {
                        $percent = if ($totalBytes -gt 0) { [Math]::Min(100, [int](100 * $processedBytes / $totalBytes)) } else { 100 }
                        Write-Progress -Id $ProgressId -Activity $Activity -Status ("{0}% · {1:N1}/{2:N1} Mo" -f $percent, ($processedBytes / 1MB), ($totalBytes / 1MB)) -PercentComplete $percent
                        $stopwatch.Restart()
                    }
                }
            } finally { $entryStream.Dispose(); $input.Dispose() }
        }
    } finally {
        if ($ProgressId -gt 0) { Write-Progress -Id $ProgressId -Activity $Activity -Completed }
        $archive.Dispose()
        $output.Dispose()
    }
}

function Test-PackArchive(
    [string]$ArchivePath,
    [int]$ProgressId = 0,
    [string]$Activity = "Vérification du pack"
) {
    $required = @(
        "pack.json", "dictionary.json", "model/am/final.mdl", "model/conf/mfcc.conf",
        "model/conf/model.conf", "model/graph/phones/word_boundary.int",
        "LICENSES/VOSK_MODEL_LICENSE.txt", "LICENSES/THIRD_PARTY_NOTICES.md"
    )
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $totalBytes = [long](($archive.Entries | Measure-Object -Property Length -Sum).Sum)
        $processedBytes = [long]0
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $entryPath = Assert-SafeRelativePath $entry.FullName
            if (-not $paths.Add($entryPath)) { throw "Duplicate final pack path: $entryPath" }
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                $stream = $entry.Open()
                try {
                    $buffer = [byte[]]::new(131072)
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $processedBytes += $read
                        if ($ProgressId -gt 0 -and $stopwatch.ElapsedMilliseconds -ge 200) {
                            $percent = if ($totalBytes -gt 0) { [Math]::Min(100, [int](100 * $processedBytes / $totalBytes)) } else { 100 }
                            Write-Progress -Id $ProgressId -Activity $Activity -Status ("{0}% · {1:N1}/{2:N1} Mo" -f $percent, ($processedBytes / 1MB), ($totalBytes / 1MB)) -PercentComplete $percent
                            $stopwatch.Restart()
                        }
                    }
                } finally { $stream.Dispose() }
            }
        }
        foreach ($path in $required) {
            if (-not $paths.Contains($path)) { throw "Final pack file is missing: $path" }
        }
        $hasMonolithicGraph = $paths.Contains("model/graph/HCLG.fst")
        $hasCompactGraph = $paths.Contains("model/graph/HCLr.fst") -and $paths.Contains("model/graph/Gr.fst")
        if (-not $hasMonolithicGraph -and -not $hasCompactGraph) {
            throw "The final pack does not contain a complete Vosk decoding graph."
        }
    } finally {
        if ($ProgressId -gt 0) { Write-Progress -Id $ProgressId -Activity $Activity -Completed }
        $archive.Dispose()
    }
}

$sourceIndex = Get-Content -Raw -Encoding utf8 -LiteralPath $sourceIndexPath | ConvertFrom-Json
[IO.Directory]::CreateDirectory($workRoot) | Out-Null
[IO.Directory]::CreateDirectory($distRoot) | Out-Null
$manifestLanguages = [Collections.Generic.List[object]]::new()
$languageDirectories = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "sources") -Directory | Sort-Object Name)
$totalVariants = 0
foreach ($directory in $languageDirectories) {
    $descriptor = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $directory.FullName "pack.json") | ConvertFrom-Json
    $totalVariants += @($descriptor.variants).Count
}
$currentVariant = 0

foreach ($languageDirectory in $languageDirectories) {
    $languageId = $languageDirectory.Name
    $sourceDirectory = $languageDirectory.FullName
    $pack = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $sourceDirectory "pack.json") | ConvertFrom-Json
    $dictionary = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $sourceDirectory $pack.dictionary) | ConvertFrom-Json
    if ($pack.id -ne $languageId -or $dictionary.language -ne $languageId) {
        throw "Language identifier mismatch in $languageId source files."
    }
    $languageSources = $sourceIndex.$languageId
    if ($null -eq $languageSources) { throw "Missing model source index for $languageId" }
    $manifestVariants = [Collections.Generic.List[object]]::new()

    foreach ($variant in $pack.variants) {
        $currentVariant++
        $variantId = [string]$variant.id
        $packLabel = "$languageId / $variantId"
        $overallPercent = if ($totalVariants -gt 0) { [int](100 * ($currentVariant - 1) / $totalVariants) } else { 0 }
        Write-Progress -Id 1 -Activity "Construction des packs de langues" -Status "Pack $currentVariant/$totalVariants · $packLabel" -PercentComplete $overallPercent
        Write-Host ""
        Write-Host "[$currentVariant/$totalVariants] $packLabel" -ForegroundColor Cyan
        $source = $languageSources.$variantId
        if ($null -eq $source) { throw "Missing model source for $languageId/$variantId" }
        $archivePath = Join-Path $downloadsRoot $source.archive
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "Missing source model: $archivePath" }
        $archiveFile = Get-Item -LiteralPath $archivePath
        if ($archiveFile.Length -ne [long]$source.archive_size) {
            throw "Unexpected size for $($source.archive): $($archiveFile.Length)"
        }
        Write-Host "  [1/5] Vérification du modèle source..."
        $archiveHash = Get-Sha256 -Path $archivePath -ProgressId 3 -Activity "$packLabel · vérification source"
        if ($archiveHash -ne [string]$source.sha256) {
            throw "SHA-256 mismatch for $($source.archive): $archiveHash"
        }

        $packRoot = Join-Path $workRoot "$languageId\$variantId"
        if (Test-Path -LiteralPath $packRoot) { Remove-Item -LiteralPath $packRoot -Recurse -Force }
        [IO.Directory]::CreateDirectory($packRoot) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $packRoot "LICENSES")) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceDirectory $pack.dictionary) -Destination (Join-Path $packRoot "dictionary.json")
        Copy-Item -LiteralPath $licensePath -Destination (Join-Path $packRoot "LICENSES\VOSK_MODEL_LICENSE.txt")
        Write-Host "  [2/5] Extraction du modèle..."
        Expand-VerifiedModel -ArchivePath $archivePath -ExpectedRoot $source.root -Destination (Join-Path $packRoot "model") -ProgressId 3 -Activity "$packLabel · extraction"

        $installedDescriptor = [ordered]@{
            schema_version = 2
            id = [string]$pack.id
            language = [string]$pack.language
            native_name = [string]$pack.native_name
            variant = $variantId
            version = [string]$pack.version
            engine = [string]$pack.engine
            dictionary = "dictionary.json"
            model = [ordered]@{
                name = [string]$variant.model.name
                license = [string]$variant.model.license
                source_page = [string]$variant.model.source_page
            }
        }
        $descriptorJson = $installedDescriptor | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $packRoot "pack.json"), $descriptorJson + "`n", [Text.UTF8Encoding]::new($false))

        $notice = @"
# Third-party notices

This language pack contains **$($variant.model.name)**, distributed by the Vosk project / Alpha Cephei.

- Variant: $variantId
- Upstream archive: $($variant.model.upstream_url)
- Source page: $($variant.model.source_page)
- Upstream archive SHA-256: $archiveHash
- License: $($variant.model.license)

The complete license text is included in `VOSK_MODEL_LICENSE.txt`.
"@
        [IO.File]::WriteAllText((Join-Path $packRoot "LICENSES\THIRD_PARTY_NOTICES.md"), $notice, [Text.UTF8Encoding]::new($false))

        $outputName = "voice-destroy-language-$languageId-$variantId-$($pack.version).zip"
        $outputPath = Join-Path $distRoot $outputName
        Write-Host "  [3/5] Compression du pack final..."
        New-DeterministicZip -SourceDirectory $packRoot -DestinationZip $outputPath -ProgressId 3 -Activity "$packLabel · compression"
        Write-Host "  [4/5] Lecture complète de contrôle..."
        Test-PackArchive -ArchivePath $outputPath -ProgressId 3 -Activity "$packLabel · contrôle intégral"
        $outputFile = Get-Item -LiteralPath $outputPath
        Write-Host "  [5/5] Calcul de l'empreinte finale..."
        $outputHash = Get-Sha256 -Path $outputPath -ProgressId 3 -Activity "$packLabel · SHA-256 final"
        $manifestVariants.Add([ordered]@{
            id = $variantId
            name = [string]$variant.name
            version = [string]$pack.version
            engine = [string]$pack.engine
            download_url = "$releaseBaseUrl/$outputName"
            archive_size = [long]$outputFile.Length
            sha256 = $outputHash
            license = [string]$variant.model.license
            min_mod_version = [string]$pack.min_mod_version
            description = [string]$variant.description
            hardware = [string]$variant.hardware
            runtime_memory_mb = [int]$variant.runtime_memory_mb
            recommended = [bool]$variant.recommended
        })
        Write-Host "  Terminé : $outputName ($([Math]::Round($outputFile.Length / 1MB, 1)) Mo)" -ForegroundColor Green
    }

    $manifestLanguages.Add([ordered]@{
        id = [string]$pack.id
        language = [string]$pack.language
        native_name = [string]$pack.native_name
        variants = $manifestVariants
    })
}

Write-Progress -Id 1 -Activity "Construction des packs de langues" -Completed

$manifest = [ordered]@{
    '$schema' = "./schemas/manifest.schema.json"
    schema_version = 2
    catalog_version = 2
    languages = $manifestLanguages
}
$manifestJson = $manifest | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($manifestPath, $manifestJson + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Updated manifest.json for release $ReleaseTag"
