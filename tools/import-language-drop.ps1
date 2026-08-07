[CmdletBinding()]
param(
    [string]$DropRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DropRoot)) {
    $DropRoot = Join-Path $repoRoot "a_publier"
}

$DropRoot = [IO.Path]::GetFullPath($DropRoot)
$downloadsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "downloads"))
$sourcesRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "sources"))
$sourceIndexPath = Join-Path $PSScriptRoot "model-sources.json"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Utf8Json([string]$Path, [object]$Value, [int]$Depth = 12) {
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-PropertyValue([object]$Object, [string]$Name, $Default = $null) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Assert-SafeFileName([string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($FileName) -or
        [IO.Path]::GetFileName($FileName) -ne $FileName -or
        -not $FileName.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Le nom ZIP doit être un simple nom de fichier se terminant par .zip : $FileName"
    }
}

function Get-VoskArchiveInfo([string]$ArchivePath) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $path = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($path) -or
                $path.StartsWith('/') -or
                $path.Contains(':') -or
                ($path.Split('/') -contains '..')) {
                throw "Chemin dangereux dans l'archive $ArchivePath : $path"
            }
            $segments = $path.Split('/')
            if ($segments.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($segments[0])) {
                [void]$roots.Add($segments[0])
            }
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                if (-not $paths.Add($path)) { throw "Chemin dupliqué dans l'archive : $path" }
            }
        }

        if ($roots.Count -ne 1) {
            throw "Le ZIP Vosk doit contenir exactement un dossier racine. Racines trouvées : $($roots -join ', ')"
        }
        $root = [string]($roots | Select-Object -First 1)
        foreach ($required in @(
            "$root/am/final.mdl",
            "$root/conf/mfcc.conf",
            "$root/conf/model.conf",
            "$root/graph/phones/word_boundary.int"
        )) {
            if (-not $paths.Contains($required)) { throw "Fichier Vosk absent : $required" }
        }
        $hasMonolithicGraph = $paths.Contains("$root/graph/HCLG.fst")
        $hasCompactGraph = $paths.Contains("$root/graph/HCLr.fst") -and $paths.Contains("$root/graph/Gr.fst")
        if (-not $hasMonolithicGraph -and -not $hasCompactGraph) {
            throw "Le graphe Vosk est incomplet dans $ArchivePath"
        }
        return [ordered]@{
            root = $root
            size = [long](Get-Item -LiteralPath $ArchivePath).Length
            sha256 = Get-Sha256 $ArchivePath
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-VariantDefaults([string]$VariantId) {
    if ($VariantId -eq "small") {
        return [ordered]@{
            name = "Small"
            description = "Reconnaissance légère et plus approximative, idéale pour les petits PC."
            hardware = "Environ 300 Mo de RAM · petits PC et Raspberry Pi"
            runtime_memory_mb = 300
            recommended = $true
        }
    }
    if ($VariantId -eq "normal") {
        return [ordered]@{
            name = "Normal"
            description = "Reconnaissance plus précise, mais modèle très lourd réservé aux PC puissants."
            hardware = "Jusqu’à 16 Go de RAM · Intel i7 ou AMD Ryzen récent recommandé"
            runtime_memory_mb = 16384
            recommended = $false
        }
    }
    return [ordered]@{
        name = (Get-Culture).TextInfo.ToTitleCase($VariantId)
        description = "Modèle de reconnaissance vocale $VariantId."
        hardware = "Configuration dépendante du modèle choisi"
        runtime_memory_mb = 1024
        recommended = $false
    }
}

function Convert-WordsCsvToDictionary([string]$CsvPath, [string]$LanguageId, [string]$DestinationPath) {
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter ';' -Encoding UTF8)
    if ($rows.Count -eq 0) { throw "Le tableau de mots est vide : $CsvPath" }
    $aliases = [Collections.Generic.List[object]]::new()
    $allowedTypes = @("block", "item", "entity", "potion", "family")
    foreach ($row in $rows) {
        $words = @(
            ([string]$row.words).Split('|') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $type = ([string]$row.type).Trim().ToLowerInvariant()
        $target = ([string]$row.target).Trim().ToLowerInvariant()
        if ($words.Count -eq 0) { throw "Une ligne de mots est vide dans $CsvPath" }
        if ($allowedTypes -notcontains $type) { throw "Type invalide '$type' dans $CsvPath" }
        if ($target -notmatch '^[a-z0-9_.-]+:[a-z0-9_./-]+$') { throw "Cible Minecraft invalide '$target'" }
        $alias = [ordered]@{
            words = $words
            type = $type
            target = $target
        }
        $notes = ([string]$row.notes).Trim()
        if (-not [string]::IsNullOrWhiteSpace($notes)) { $alias["notes"] = $notes }
        $aliases.Add($alias)
    }
    $dictionary = [ordered]@{
        '$schema' = "../../schemas/dictionary.schema.json"
        schema_version = 1
        language = $LanguageId
        aliases = $aliases
    }
    Write-Utf8Json -Path $DestinationPath -Value $dictionary
}

[IO.Directory]::CreateDirectory($DropRoot) | Out-Null
[IO.Directory]::CreateDirectory($downloadsRoot) | Out-Null
[IO.Directory]::CreateDirectory($sourcesRoot) | Out-Null

$languageFolders = @(
    Get-ChildItem -LiteralPath $DropRoot -Directory |
        Where-Object { -not $_.Name.StartsWith('_') } |
        Sort-Object Name
)

if ($languageFolders.Count -eq 0) {
    Write-Host "Aucune nouvelle langue trouvée dans $DropRoot"
    return
}

$sourceIndex = Get-Content -Raw -Encoding utf8 -LiteralPath $sourceIndexPath | ConvertFrom-Json
$imported = [Collections.Generic.List[string]]::new()

foreach ($folder in $languageFolders) {
    $definitionPath = Join-Path $folder.FullName "language.json"
    $dictionaryPath = Join-Path $folder.FullName "dictionary.json"
    $wordsCsvPath = Join-Path $folder.FullName "mots.csv"
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        throw "Fichier absent : $definitionPath"
    }

    $definition = Get-Content -Raw -Encoding utf8 -LiteralPath $definitionPath | ConvertFrom-Json
    $languageId = [string]$definition.id
    if (Test-Path -LiteralPath $wordsCsvPath -PathType Leaf) {
        Write-Host "Conversion automatique de mots.csv pour $languageId"
        Convert-WordsCsvToDictionary -CsvPath $wordsCsvPath -LanguageId $languageId -DestinationPath $dictionaryPath
    }
    if (-not (Test-Path -LiteralPath $dictionaryPath -PathType Leaf)) {
        throw "Ajoute mots.csv avec l'assistant AJOUTER_UNE_LANGUE.bat."
    }
    $dictionary = Get-Content -Raw -Encoding utf8 -LiteralPath $dictionaryPath | ConvertFrom-Json
    if ($languageId -notmatch '^[a-z]{2,3}_[a-z0-9]{2,8}$') {
        throw "Identifiant de langue invalide : $languageId (exemple : es_es)"
    }
    if ($folder.Name -ne $languageId) {
        throw "Le dossier '$($folder.Name)' doit porter le même nom que l'identifiant '$languageId'."
    }
    if ([string]$dictionary.language -ne $languageId) {
        throw "dictionary.json doit contenir language = '$languageId'."
    }
    if ($null -eq $definition.variants -or $definition.variants.Count -eq 0) {
        throw "La langue $languageId ne contient aucune variante."
    }

    $variantIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $packVariants = [Collections.Generic.List[object]]::new()
    $languageSourceIndex = [pscustomobject]@{}

    foreach ($variant in $definition.variants) {
        $variantId = [string]$variant.id
        if ($variantId -notmatch '^[a-z0-9_-]{2,16}$' -or -not $variantIds.Add($variantId)) {
            throw "Variante invalide ou dupliquée pour $languageId : $variantId"
        }
        $zipName = [string]$variant.zip
        Assert-SafeFileName $zipName
        $incomingZip = Join-Path $folder.FullName $zipName
        if (-not (Test-Path -LiteralPath $incomingZip -PathType Leaf)) {
            throw "Modèle ZIP absent : $incomingZip"
        }

        Write-Host "Vérification de $languageId/$variantId : $zipName"
        $archiveInfo = Get-VoskArchiveInfo $incomingZip
        $storedZip = Join-Path $downloadsRoot $zipName
        if (Test-Path -LiteralPath $storedZip -PathType Leaf) {
            $storedHash = Get-Sha256 $storedZip
            if ($storedHash -ne $archiveInfo.sha256) {
                throw "Un fichier différent porte déjà le nom $zipName dans downloads/."
            }
        } else {
            Copy-Item -LiteralPath $incomingZip -Destination $storedZip
        }

        $defaults = Get-VariantDefaults $variantId
        $sourceUrl = [string](Get-PropertyValue $variant "upstream_url" "")
        if ($sourceUrl -notmatch '^https://') {
            throw "upstream_url doit être une URL HTTPS pour $languageId/$variantId."
        }
        $modelName = [string](Get-PropertyValue $variant "model_name" $archiveInfo.root)
        $license = [string](Get-PropertyValue $variant "license" "Apache-2.0")
        $sourcePage = [string](Get-PropertyValue $variant "source_page" "https://alphacephei.com/vosk/models")

        $packVariants.Add([ordered]@{
            id = $variantId
            name = [string](Get-PropertyValue $variant "name" $defaults.name)
            description = [string](Get-PropertyValue $variant "description" $defaults.description)
            hardware = [string](Get-PropertyValue $variant "hardware" $defaults.hardware)
            runtime_memory_mb = [int](Get-PropertyValue $variant "runtime_memory_mb" $defaults.runtime_memory_mb)
            recommended = [bool](Get-PropertyValue $variant "recommended" $defaults.recommended)
            model = [ordered]@{
                name = $modelName
                upstream_url = $sourceUrl
                license = $license
                source_page = $sourcePage
            }
        })

        $variantSource = [pscustomobject][ordered]@{
            archive = $zipName
            archive_size = [long]$archiveInfo.size
            sha256 = [string]$archiveInfo.sha256
            root = [string]$archiveInfo.root
        }
        $languageSourceIndex | Add-Member -NotePropertyName $variantId -NotePropertyValue $variantSource
    }

    $sourceDirectory = Join-Path $sourcesRoot $languageId
    [IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
    $packDescriptor = [ordered]@{
        '$schema' = "../../schemas/pack.schema.json"
        schema_version = 2
        id = $languageId
        language = [string]$definition.language
        native_name = [string]$definition.native_name
        version = [string]$definition.version
        engine = "vosk"
        dictionary = "dictionary.json"
        min_mod_version = [string](Get-PropertyValue $definition "min_mod_version" "1.5.0")
        variants = $packVariants
    }
    Write-Utf8Json -Path (Join-Path $sourceDirectory "pack.json") -Value $packDescriptor
    Copy-Item -LiteralPath $dictionaryPath -Destination (Join-Path $sourceDirectory "dictionary.json") -Force
    $sourceIndex | Add-Member -NotePropertyName $languageId -NotePropertyValue $languageSourceIndex -Force
    $imported.Add($languageId)
}

Write-Utf8Json -Path $sourceIndexPath -Value $sourceIndex
Write-Host "Langues importées : $($imported -join ', ')"
