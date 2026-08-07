[CmdletBinding()]
param(
    [string]$ReleaseTag,
    [string]$Repository = "LeKyks77/voice-destroy-language-packs",
    [switch]$DryRun,
    [switch]$SkipBuild,
    [switch]$RepublishExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$dropRoot = Join-Path $repoRoot "a_publier"
$distRoot = Join-Path $repoRoot "dist"
$workRoot = Join-Path $repoRoot "work"
$builderPath = Join-Path $PSScriptRoot "build-language-packs.ps1"
$importerPath = Join-Path $PSScriptRoot "import-language-drop.ps1"
$validatorPath = Join-Path $PSScriptRoot "validate_catalog.py"

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Commande échouée ($LASTEXITCODE) : $Program $($Arguments -join ' ')"
    }
}

function Test-NativeCommand([string]$Program, [string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Program @Arguments 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Get-GitHubCli {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    foreach ($candidate in @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "GitHub CLI est absent. Installe-le depuis https://cli.github.com/ puis relance ce fichier."
    }
    Write-Host "GitHub CLI est absent. Installation officielle en cours..." -ForegroundColor Yellow
    Invoke-Checked $winget.Source @(
        "install", "--id", "GitHub.cli", "--exact", "--source", "winget",
        "--accept-package-agreements", "--accept-source-agreements"
    )
    foreach ($candidate in @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "GitHub CLI a été installé mais gh.exe reste introuvable. Rouvre le script." }
    return $command.Source
}

function Assert-CleanRepository([switch]$AllowPreparedLanguageChanges) {
    $changes = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "Impossible de lire l'état Git du dépôt." }
    if ($changes) {
        if ($AllowPreparedLanguageChanges) {
            $unexpected = @(
                foreach ($change in $changes) {
                    if ($change.Length -lt 4) { $change; continue }
                    $status = $change.Substring(0, 2)
                    $path = $change.Substring(3).Trim('"').Replace('\', '/')
                    $isGeneratedPath =
                        $path -eq "manifest.json" -or
                        $path -eq "tools/model-sources.json" -or
                        $path.StartsWith("sources/", [StringComparison]::OrdinalIgnoreCase)
                    if (-not $isGeneratedPath -or $status.Contains('D')) { $change }
                }
            )
            if ($unexpected.Count -eq 0) {
                Write-Host "Reprise d'une publication interrompue : fichiers de langue déjà préparés." -ForegroundColor Yellow
                return
            }
        }
        throw "Le dépôt contient déjà des changements. Committe-les ou range-les avant de publier.`n$($changes -join "`n")"
    }
}

function Get-ReleaseNotes([string]$Tag) {
    $manifest = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $repoRoot "manifest.json") | ConvertFrom-Json
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Voice Destroy language packs $Tag")
    $lines.Add("")
    $lines.Add("Packs de reconnaissance vocale vérifiés pour Voice Destroy.")
    $lines.Add("")
    foreach ($language in $manifest.languages) {
        $variants = @($language.variants | ForEach-Object { "$($_.name) ($([Math]::Round([long]$_.archive_size / 1MB, 1)) Mo)" })
        $lines.Add("- $($language.native_name) : $($variants -join ', ')")
    }
    $lines.Add("")
    $lines.Add("Chaque téléchargement est contrôlé par taille exacte et SHA-256 avant installation.")
    return $lines -join "`n"
}

function Get-ManifestAssets([string]$Tag) {
    $manifest = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $repoRoot "manifest.json") | ConvertFrom-Json
    $expectedPrefix = "https://github.com/$Repository/releases/download/$Tag/"
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($language in $manifest.languages) {
        foreach ($variant in $language.variants) {
            $url = [string]$variant.download_url
            if (-not $url.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Le manifeste référence une autre release pour $($language.id)/$($variant.id) : $url"
            }
            $fileName = [Uri]::UnescapeDataString($url.Substring($expectedPrefix.Length))
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or -not $seen.Add($fileName)) {
                throw "Nom d'archive invalide ou dupliqué dans le manifeste : $fileName"
            }
            $assetPath = Join-Path $distRoot $fileName
            if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
                throw "Archive finale absente : $assetPath"
            }
            $asset = Get-Item -LiteralPath $assetPath
            if ($asset.Length -ne [long]$variant.archive_size) {
                throw "Taille différente du manifeste pour $fileName."
            }
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToUpperInvariant()
            if ($hash -ne [string]$variant.sha256) {
                throw "SHA-256 différent du manifeste pour $fileName."
            }
            $result.Add($asset)
        }
    }
    return $result.ToArray()
}

Push-Location $repoRoot
try {
    if (-not (Test-Path -LiteralPath ".git" -PathType Container)) {
        throw "Ce script doit être lancé depuis le dépôt Git des packs de langues."
    }
    Assert-CleanRepository -AllowPreparedLanguageChanges

    $gh = $null
    if (-not $DryRun) {
        $gh = Get-GitHubCli
        $isAuthenticated = Test-NativeCommand $gh @("auth", "status", "--hostname", "github.com")
        if (-not $isAuthenticated) {
            Write-Host "Une page GitHub va s'ouvrir pour la connexion unique." -ForegroundColor Yellow
            Invoke-Checked $gh @("auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web")
        }
        Invoke-Checked $gh @("auth", "setup-git")
        Invoke-Checked $gh @("repo", "view", $Repository, "--json", "nameWithOwner")
        Invoke-Checked "git" @("fetch", "origin", "main")
        $publisherIsMerged = Test-NativeCommand "git" @("cat-file", "-e", "origin/main:tools/publish-language-packs.ps1")
        if (-not $publisherIsMerged) {
            throw "Fusionne d'abord la pull request des packs Small/Normal dans main : https://github.com/$Repository/pull/new/codex/language-model-variants"
        }
        Invoke-Checked "git" @("switch", "main")
        Invoke-Checked "git" @("pull", "--ff-only", "origin", "main")
        Assert-CleanRepository -AllowPreparedLanguageChanges
    }

    if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        $ReleaseTag = Read-Host "Tag de publication (exemple : packs-v1.2.0)"
    }
    if ($ReleaseTag -notmatch '^packs-v[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Tag invalide : $ReleaseTag. Format attendu : packs-v1.2.0"
    }

    [IO.Directory]::CreateDirectory($dropRoot) | Out-Null
    $dropLanguages = @(Get-ChildItem -LiteralPath $dropRoot -Directory | Where-Object { -not $_.Name.StartsWith('_') })
    if ($dropLanguages.Count -eq 0 -and -not $RepublishExisting) {
        if ($DryRun) {
            Write-Host "Aucune nouvelle langue dans a_publier/ : vérification du catalogue existant."
        } else {
            $answer = Read-Host "Aucune nouvelle langue trouvée. Republier toutes les langues existantes ? (O/N)"
            if ($answer -notmatch '^(o|oui|y|yes)$') { throw "Publication annulée." }
        }
    }

    if ($dropLanguages.Count -gt 0) {
        & $importerPath -DropRoot $dropRoot
    }

    if (-not $SkipBuild) {
        & $builderPath -ReleaseTag $ReleaseTag
    } else {
        Write-Host "Construction ignorée (-SkipBuild)."
    }
    Invoke-Checked "python" @($validatorPath)

    if ($SkipBuild) {
        if (-not $DryRun) { throw "-SkipBuild est réservé au mode -DryRun." }
        $assets = @()
    } else {
        $assets = @(Get-ManifestAssets $ReleaseTag | Sort-Object Name)
        if ($assets.Count -eq 0) { throw "Aucun pack final n'a été créé dans dist/." }
    }

    Write-Host ""
    Write-Host "Résumé de la publication $ReleaseTag" -ForegroundColor Cyan
    foreach ($asset in $assets) {
        Write-Host ("  {0} - {1:N1} Mo" -f $asset.Name, ($asset.Length / 1MB))
    }

    if ($DryRun) {
        Write-Host "Mode test terminé : aucun commit, push, PR ou release n'a été créé." -ForegroundColor Green
        return
    }

    $localTagExists = [bool](& git tag --list $ReleaseTag)
    $remoteReleaseExists = Test-NativeCommand $gh @("release", "view", $ReleaseTag, "--repo", $Repository)
    if ($localTagExists -or $remoteReleaseExists) {
        throw "Le tag ou la release $ReleaseTag existe déjà. Choisis une nouvelle version."
    }

    $confirmation = Read-Host "Tape PUBLIER pour envoyer la branche, fusionner la PR et publier les ZIP"
    if ($confirmation -cne "PUBLIER") { throw "Publication annulée." }

    $safeTag = $ReleaseTag -replace '[^a-zA-Z0-9._-]', '-'
    Invoke-Checked "git" @("add", "--", "manifest.json", "sources", "tools/model-sources.json")
    & git diff --cached --quiet
    $hasCatalogChanges = $LASTEXITCODE -ne 0

    [IO.Directory]::CreateDirectory($workRoot) | Out-Null
    $prBodyPath = Join-Path $workRoot "pr-$safeTag.md"
    $notesPath = Join-Path $workRoot "release-$safeTag.md"
    [IO.File]::WriteAllText($notesPath, (Get-ReleaseNotes $ReleaseTag), [Text.UTF8Encoding]::new($false))
    $prUrl = $null

    if ($hasCatalogChanges) {
        $branch = "release/$safeTag-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
        Invoke-Checked "git" @("switch", "-c", $branch)
        Invoke-Checked "git" @("diff", "--cached", "--check")
        Invoke-Checked "git" @("commit", "-m", "release: publish language packs $ReleaseTag")
        Invoke-Checked "git" @("push", "--set-upstream", "origin", $branch)

        $prBody = @"
## Publication

- reconstruit tous les packs de langues
- vérifie chaque modèle et chaque archive finale
- met à jour les tailles et SHA-256 du catalogue
- prépare la release `$ReleaseTag`

La publication de la release est effectuée automatiquement après validation de cette pull request.
"@
        [IO.File]::WriteAllText($prBodyPath, $prBody, [Text.UTF8Encoding]::new($false))

        $prOutput = & $gh pr create --repo $Repository --base main --head $branch --title "Publish language packs $ReleaseTag" --body-file $prBodyPath
        if ($LASTEXITCODE -ne 0) { throw "Impossible de créer la pull request." }
        $prUrl = [string]($prOutput | Select-Object -Last 1)
        Write-Host "Pull request : $prUrl" -ForegroundColor Cyan
        Invoke-Checked $gh @("pr", "checks", $prUrl, "--repo", $Repository, "--watch", "--interval", "10")
    } else {
        Write-Host "Le catalogue est déjà à jour : publication de la release sans PR inutile." -ForegroundColor Yellow
    }

    $releaseArguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @("release", "create", $ReleaseTag, "--repo", $Repository, "--target", "main", "--title", "Voice Destroy language packs $ReleaseTag", "--notes-file", $notesPath, "--draft")) {
        $releaseArguments.Add($argument)
    }
    foreach ($asset in $assets) { $releaseArguments.Add($asset.FullName) }
    Invoke-Checked $gh ($releaseArguments.ToArray())

    if ($hasCatalogChanges) {
        Invoke-Checked $gh @("pr", "merge", $prUrl, "--repo", $Repository, "--squash", "--delete-branch")
        Invoke-Checked "git" @("switch", "main")
        Invoke-Checked "git" @("pull", "--ff-only", "origin", "main")
    }
    Invoke-Checked $gh @("release", "edit", $ReleaseTag, "--repo", $Repository, "--draft=false", "--latest")

    Write-Host ""
    Write-Host "Publication terminée." -ForegroundColor Green
    Invoke-Checked $gh @("release", "view", $ReleaseTag, "--repo", $Repository, "--json", "url,isDraft,assets")
    Write-Host "Le catalogue Minecraft sera relu au prochain rafraîchissement du menu des langues."
} finally {
    Pop-Location
}
