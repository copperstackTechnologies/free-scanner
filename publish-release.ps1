param(
    [string]$Repository = 'copperstackTechnologies/free-scanner'
)

$ErrorActionPreference = 'Stop'

function Get-GitHubHeaders {
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_TERMINAL_PROMPT = '0'
    $credentialLines = "protocol=https`nhost=github.com`n`n" | git credential fill
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read a stored GitHub credential. Sign in with Git Credential Manager first.'
    }

    $credential = @{}
    foreach ($line in $credentialLines) {
        if ($line -match '^(username|password)=(.*)$') {
            $credential[$matches[1]] = $matches[2]
        }
    }
    if (-not $credential.ContainsKey('password')) {
        throw 'No stored GitHub token is available. Sign in with Git Credential Manager first.'
    }

    return @{
        Authorization = "Bearer $($credential.password)"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'Free-Scanner-Release-Publisher'
    }
}

$projectRoot = $PSScriptRoot
$pubspec = Get-Content (Join-Path $projectRoot 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw 'Set pubspec.yaml version to MAJOR.MINOR.PATCH+BUILD before publishing.'
}
$version = $matches[1]
$tag = "v$version"

$branch = git -C $projectRoot branch --show-current
if ($branch -ne 'main') {
    throw 'Publish releases from the main branch.'
}
if (git -C $projectRoot status --porcelain) {
    throw 'Commit or stash all project changes before publishing a release.'
}

Push-Location $projectRoot
try {
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
} finally {
    Pop-Location
}

$apkPath = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
    throw "Release APK not found at $apkPath"
}

$dist = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$apkName = "Free-Scanner-$version.apk"
$releaseApk = Join-Path $dist $apkName
Copy-Item -LiteralPath $apkPath -Destination $releaseApk -Force
$sha256 = (Get-FileHash -LiteralPath $releaseApk -Algorithm SHA256).Hash.ToLowerInvariant()
$downloadUrl = "https://github.com/$Repository/releases/download/$tag/$apkName"
$metadataPath = Join-Path $dist 'latest.json'
@{
    version = $version
    apkUrl = $downloadUrl
    sha256 = $sha256
} | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM

$headers = Get-GitHubHeaders
$releaseBody = @{
    tag_name = $tag
    name = "Free Scanner $version"
    body = "Free Scanner Android release $version. Install updates using Settings > Check for updates."
    draft = $false
    prerelease = $false
} | ConvertTo-Json
$releaseTagUri = "https://api.github.com/repos/$Repository/releases/tags/$tag"
try {
    $release = Invoke-RestMethod -Method Get -Uri $releaseTagUri -Headers $headers
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
    $release = Invoke-RestMethod -Method Post `
        -Uri "https://api.github.com/repos/$Repository/releases" `
        -Headers $headers -ContentType 'application/json' -Body $releaseBody
}
$uploadBase = $release.upload_url -replace '\{\?.*$', ''

foreach ($asset in @(
    @{ Path = $releaseApk; Name = $apkName; ContentType = 'application/vnd.android.package-archive' },
    @{ Path = $metadataPath; Name = 'latest.json'; ContentType = 'application/json' }
)) {
    $existingAsset = $release.assets | Where-Object { $_.name -eq $asset.Name }
    if ($existingAsset) {
        Invoke-RestMethod -Method Delete `
            -Uri "https://api.github.com/repos/$Repository/releases/assets/$($existingAsset.id)" `
            -Headers $headers | Out-Null
    }
    Invoke-RestMethod -Method Post `
        -Uri "${uploadBase}?name=$([Uri]::EscapeDataString($asset.Name))" `
        -Headers $headers -ContentType $asset.ContentType -InFile $asset.Path | Out-Null
}

Write-Host "Published ${tag}: $($release.html_url)"
Write-Host "APK SHA-256: $sha256"
