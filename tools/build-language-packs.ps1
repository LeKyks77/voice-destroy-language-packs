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

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
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
    [string]$Destination
) {
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    [IO.Directory]::CreateDirectory($destinationFull) | Out-Null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
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
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally {
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

function New-DeterministicZip([string]$SourceDirectory, [string]$DestinationZip) {
    if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
    $sourceFull = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $output = [IO.File]::Open($DestinationZip, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($output, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $files = Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File |
            Sort-Object { $_.FullName.Substring($sourceFull.Length).Replace('\', '/') }
        foreach ($file in $files) {
            $entryName = $file.FullName.Substring($sourceFull.Length).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $input = [IO.File]::OpenRead($file.FullName)
            $entryStream = $entry.Open()
            try { $input.CopyTo($entryStream) } finally { $entryStream.Dispose(); $input.Dispose() }
        }
    } finally {
        $archive.Dispose()
        $output.Dispose()
    }
}

function Test-PackArchive([string]$ArchivePath) {
    $required = @(
        "pack.json", "dictionary.json", "model/am/final.mdl", "model/conf/mfcc.conf",
        "model/conf/model.conf", "model/graph/phones/word_boundary.int",
        "LICENSES/VOSK_MODEL_LICENSE.txt", "LICENSES/THIRD_PARTY_NOTICES.md"
    )
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $entryPath = Assert-SafeRelativePath $entry.FullName
            if (-not $paths.Add($entryPath)) { throw "Duplicate final pack path: $entryPath" }
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                $stream = $entry.Open()
                try {
                    $buffer = [byte[]]::new(131072)
                    while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
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
        $archive.Dispose()
    }
}

$sourceIndex = Get-Content -Raw -Encoding utf8 -LiteralPath $sourceIndexPath | ConvertFrom-Json
[IO.Directory]::CreateDirectory($workRoot) | Out-Null
[IO.Directory]::CreateDirectory($distRoot) | Out-Null
$manifestLanguages = [Collections.Generic.List[object]]::new()
$languageDirectories = Get-ChildItem -LiteralPath (Join-Path $repoRoot "sources") -Directory | Sort-Object Name

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
        $variantId = [string]$variant.id
        $source = $languageSources.$variantId
        if ($null -eq $source) { throw "Missing model source for $languageId/$variantId" }
        $archivePath = Join-Path $downloadsRoot $source.archive
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "Missing source model: $archivePath" }
        $archiveFile = Get-Item -LiteralPath $archivePath
        if ($archiveFile.Length -ne [long]$source.archive_size) {
            throw "Unexpected size for $($source.archive): $($archiveFile.Length)"
        }
        $archiveHash = Get-Sha256 $archivePath
        if ($archiveHash -ne [string]$source.sha256) {
            throw "SHA-256 mismatch for $($source.archive): $archiveHash"
        }

        $packRoot = Join-Path $workRoot "$languageId\$variantId"
        if (Test-Path -LiteralPath $packRoot) { Remove-Item -LiteralPath $packRoot -Recurse -Force }
        [IO.Directory]::CreateDirectory($packRoot) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $packRoot "LICENSES")) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceDirectory $pack.dictionary) -Destination (Join-Path $packRoot "dictionary.json")
        Copy-Item -LiteralPath $licensePath -Destination (Join-Path $packRoot "LICENSES\VOSK_MODEL_LICENSE.txt")
        Expand-VerifiedModel -ArchivePath $archivePath -ExpectedRoot $source.root -Destination (Join-Path $packRoot "model")

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
        New-DeterministicZip -SourceDirectory $packRoot -DestinationZip $outputPath
        Test-PackArchive $outputPath
        $outputFile = Get-Item -LiteralPath $outputPath
        $outputHash = Get-Sha256 $outputPath
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
        Write-Host "Built $outputName ($($outputFile.Length) bytes, SHA-256 $outputHash)"
    }

    $manifestLanguages.Add([ordered]@{
        id = [string]$pack.id
        language = [string]$pack.language
        native_name = [string]$pack.native_name
        variants = $manifestVariants
    })
}

$manifest = [ordered]@{
    '$schema' = "./schemas/manifest.schema.json"
    schema_version = 2
    catalog_version = 2
    languages = $manifestLanguages
}
$manifestJson = $manifest | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($manifestPath, $manifestJson + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Updated manifest.json for release $ReleaseTag"
