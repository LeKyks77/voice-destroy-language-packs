[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$dropRoot = Join-Path $repoRoot "a_publier"
$englishDictionaryPath = Join-Path $repoRoot "sources\en_us\dictionary.json"

function Read-Required([string]$Prompt, [string]$Pattern, [string]$Example) {
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if ($value -match $Pattern) { return $value }
        Write-Host "Valeur invalide. Exemple : $Example" -ForegroundColor Yellow
    }
}

function Read-WithDefault([string]$Prompt, [string]$Default) {
    $value = (Read-Host "$Prompt [$Default]").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Read-Name([string]$Prompt, [string]$ExistingValue, [string]$Example) {
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        return Read-WithDefault $Prompt $ExistingValue
    }
    while ($true) {
        $value = (Read-Host "$Prompt (exemple : $Example)").Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-Host "Cette valeur est obligatoire." -ForegroundColor Yellow
    }
}

function Get-PropertyValue([object]$Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
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
    return [ordered]@{
        name = "Normal"
        description = "Reconnaissance plus précise, mais modèle très lourd réservé aux PC puissants."
        hardware = "Jusqu’à 16 Go de RAM · Intel i7 ou AMD Ryzen récent recommandé"
        runtime_memory_mb = 16384
        recommended = $false
    }
}

function Read-Model([string]$VariantId, [object]$ExistingVariant, [string]$DestinationFolder) {
    $existingZip = [string](Get-PropertyValue $ExistingVariant "zip" "")
    $label = if ($VariantId -eq "small") { "Small (léger)" } else { "Normal (précis et lourd)" }
    if ([string]::IsNullOrWhiteSpace($existingZip)) {
        $prompt = "Chemin du ZIP Vosk $label (Entrée pour ne pas l'ajouter)"
    } else {
        $prompt = "Chemin du nouveau ZIP $label (Entrée pour conserver $existingZip)"
    }
    $path = (Read-Host $prompt).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $ExistingVariant
    }
    $fullPath = [IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
        -not $fullPath.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) {
        throw "ZIP introuvable ou invalide : $fullPath"
    }
    $zipName = [IO.Path]::GetFileName($fullPath)
    $destination = Join-Path $DestinationFolder $zipName
    if ([IO.Path]::GetFullPath($destination) -ne $fullPath) {
        Copy-Item -LiteralPath $fullPath -Destination $destination -Force
    }
    $defaultUrl = "https://alphacephei.com/vosk/models/$zipName"
    $upstreamUrl = Read-WithDefault "Adresse officielle du modèle" $defaultUrl
    if ($upstreamUrl -notmatch '^https://') { throw "L'adresse du modèle doit commencer par https://" }
    $defaults = Get-VariantDefaults $VariantId
    return [ordered]@{
        id = $VariantId
        zip = $zipName
        upstream_url = $upstreamUrl
        name = $defaults.name
        description = $defaults.description
        hardware = $defaults.hardware
        runtime_memory_mb = $defaults.runtime_memory_mb
        recommended = $defaults.recommended
    }
}

function New-WordsCsv([string]$Destination) {
    $dictionary = Get-Content -Raw -Encoding utf8 -LiteralPath $englishDictionaryPath | ConvertFrom-Json
    $rows = foreach ($alias in $dictionary.aliases) {
        [pscustomobject][ordered]@{
            words = ([string[]]$alias.words -join '|')
            type = [string]$alias.type
            target = [string]$alias.target
            notes = "TRADUIRE les mots de la première colonne"
        }
    }
    $rows | Export-Csv -LiteralPath $Destination -Delimiter ';' -Encoding UTF8 -NoTypeInformation
}

Write-Host ""
Write-Host "VOICE DESTROY - AJOUTER OU COMPLÉTER UNE LANGUE" -ForegroundColor Cyan
Write-Host "Aucun fichier JSON n'est à écrire manuellement." -ForegroundColor Green
Write-Host ""

[IO.Directory]::CreateDirectory($dropRoot) | Out-Null
$languageId = Read-Required "Code de langue" '^[a-z]{2,3}_[a-z0-9]{2,8}$' "es_es"
$languageFolder = Join-Path $dropRoot $languageId
[IO.Directory]::CreateDirectory($languageFolder) | Out-Null
$definitionPath = Join-Path $languageFolder "language.json"
$existing = $null
if (Test-Path -LiteralPath $definitionPath -PathType Leaf) {
    $existing = Get-Content -Raw -Encoding utf8 -LiteralPath $definitionPath | ConvertFrom-Json
    Write-Host "La langue $languageId existe déjà : les valeurs actuelles seront proposées par défaut." -ForegroundColor Yellow
}

$language = Read-Name "Nom international de la langue" ([string](Get-PropertyValue $existing "language" "")) "Spanish"
$nativeName = Read-Name "Nom affiché dans le jeu" ([string](Get-PropertyValue $existing "native_name" "")) "Español"
$version = Read-WithDefault "Version de ce pack" ([string](Get-PropertyValue $existing "version" "1.0.0"))
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Version invalide. Exemple : 1.0.0" }

$variantsById = @{}
if ($null -ne $existing) {
    foreach ($variant in $existing.variants) { $variantsById[[string]$variant.id] = $variant }
}
foreach ($variantId in @("small", "normal")) {
    $variant = Read-Model -VariantId $variantId -ExistingVariant $variantsById[$variantId] -DestinationFolder $languageFolder
    if ($null -ne $variant) { $variantsById[$variantId] = $variant }
}
if ($variantsById.Count -eq 0) { throw "Ajoute au moins un modèle Small ou Normal." }

$variants = [Collections.Generic.List[object]]::new()
foreach ($variantId in @("small", "normal")) {
    if ($variantsById.ContainsKey($variantId)) { $variants.Add($variantsById[$variantId]) }
}
$definition = [ordered]@{
    id = $languageId
    language = $language
    native_name = $nativeName
    version = $version
    min_mod_version = "1.5.0"
    variants = $variants
}
$definitionJson = $definition | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($definitionPath, $definitionJson + "`n", [Text.UTF8Encoding]::new($false))

$wordsPath = Join-Path $languageFolder "mots.csv"
if (-not (Test-Path -LiteralPath $wordsPath -PathType Leaf)) {
    New-WordsCsv $wordsPath
    Write-Host "Un tableau de mots a été créé à partir du dictionnaire anglais." -ForegroundColor Green
}

Write-Host ""
Write-Host "Langue préparée : $languageFolder" -ForegroundColor Green
Write-Host "1. Ouvre mots.csv."
Write-Host "2. Traduis uniquement la colonne 'words' ; sépare les synonymes avec |."
Write-Host "3. Enregistre, ferme le fichier, puis lance PUBLIER_LANGUES.bat."
$openWords = Read-Host "Ouvrir mots.csv maintenant ? (O/N)"
if ($openWords -match '^(o|oui|y|yes)$') {
    Start-Process -FilePath "notepad.exe" -ArgumentList @($wordsPath)
}
