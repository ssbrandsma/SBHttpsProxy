[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://49.12.198.91/sbhttpsproxy',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -Raw).Trim()
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "VERSION must contain a semantic version; found '$Version'"
}
$BaseUrl = $BaseUrl.TrimEnd('/')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $Root 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$Source = Join-Path $Root 'applet/HTTPSProxy'
$Binary = Join-Path $Root 'build/arm/sbproxy'
$CaBundle = Join-Path $Root 'certs/cacert.pem'
$StageRoot = Join-Path ([IO.Path]::GetTempPath()) ('HTTPSProxy-' + [guid]::NewGuid().ToString('N'))
$Stage = Join-Path $StageRoot 'HTTPSProxy'
$ZipName = "HTTPSProxy-$Version.zip"
$ZipPath = Join-Path $OutputDirectory $ZipName

$RootFiles = @(
    'HTTPSProxyApplet.lua',
    'HTTPSProxyMeta.lua',
    'HTTPSProxyService.lua',
    'strings.txt'
)
$ExpectedEntries = @(
    'HTTPSProxyApplet.lua',
    'HTTPSProxyMeta.lua',
    'HTTPSProxyService.lua',
    'strings.txt',
    'bin/sbproxy',
    'certs/cacert.pem'
)

New-Item -ItemType Directory -Force $OutputDirectory, (Join-Path $Stage 'bin'), (Join-Path $Stage 'certs') | Out-Null
try {
    foreach ($File in $RootFiles) {
        Copy-Item -LiteralPath (Join-Path $Source $File) -Destination $Stage
    }
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $Stage 'bin/sbproxy')
    Copy-Item -LiteralPath $CaBundle -Destination (Join-Path $Stage 'certs/cacert.pem')

    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    $PackagePaths = @($RootFiles) + @('bin', 'certs')
    Push-Location $Stage
    try { Compress-Archive -Path $PackagePaths -DestinationPath $ZipPath -CompressionLevel Optimal }
    finally { Pop-Location }
}
finally {
    if (Test-Path -LiteralPath $StageRoot) { Remove-Item -LiteralPath $StageRoot -Recurse -Force }
}

$Archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $Entries = @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName.Replace([char]92, '/') })
}
finally { $Archive.Dispose() }
$Unexpected = @($Entries | Where-Object { $_ -notin $ExpectedEntries })
$Missing = @($ExpectedEntries | Where-Object { $_ -notin $Entries })
if ($Unexpected.Count -or $Missing.Count) {
    throw "Unexpected ZIP layout. Entries: $($Entries -join ', ')"
}

$ZipSha1 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA1).Hash.ToLowerInvariant()
$ZipUrl = "$BaseUrl/$ZipName"
$Xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
  <details><title lang="EN">SBHttpsProxy Applet Repository</title></details>
  <applets>
    <applet name="HTTPSProxy" version="$Version" target="baby" minTarget="7.7" maxTarget="*"><title lang="EN">HTTPS Proxy</title><desc lang="EN">Local HTTPS-to-HTTP streaming proxy for Squeezebox Radio applets.</desc><changes lang="EN">Initial Applet Installer release with static ARM proxy and current CA bundle.</changes><creator>Sjoerd Brandsma</creator><url>$ZipUrl</url><sha>$ZipSha1</sha></applet>
    <applet name="HTTPSProxy" version="$Version" target="fab4" minTarget="7.7" maxTarget="*"><title lang="EN">HTTPS Proxy</title><desc lang="EN">Local HTTPS-to-HTTP streaming proxy for Squeezebox Touch applets.</desc><changes lang="EN">Initial Applet Installer release with static ARM proxy and current CA bundle.</changes><creator>Sjoerd Brandsma</creator><url>$ZipUrl</url><sha>$ZipSha1</sha></applet>
  </applets>
</extensions>
"@
$Utf8 = New-Object Text.UTF8Encoding($false)
$XmlPath = Join-Path $OutputDirectory 'extensions.xml'
[IO.File]::WriteAllText($XmlPath, $Xml, $Utf8)
$XmlSha1 = (Get-FileHash -LiteralPath $XmlPath -Algorithm SHA1).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'extensions.xml.sha1'), $XmlSha1, $Utf8)

[xml]$Parsed = Get-Content -LiteralPath $XmlPath -Raw
$Applets = @($Parsed.extensions.applets.applet)
if ($Applets.Count -ne 2) { throw 'extensions.xml must contain baby and fab4 entries' }
foreach ($Target in @('baby', 'fab4')) {
    $Applet = @($Applets | Where-Object target -eq $Target)
    if ($Applet.Count -ne 1 -or $Applet[0].name -ne 'HTTPSProxy' -or $Applet[0].version -ne $Version -or $Applet[0].url -ne $ZipUrl -or $Applet[0].sha -ne $ZipSha1) {
        throw "Invalid $Target repository metadata"
    }
}

Write-Host "ZIP: $ZipPath"
Write-Host "ZIP size: $((Get-Item -LiteralPath $ZipPath).Length) bytes"
Write-Host "ZIP SHA-1: $ZipSha1"
Write-Host "XML: $XmlPath"
Write-Host "XML SHA-1: $XmlSha1"
Write-Host "URL: $ZipUrl"
Write-Host "Entries: $($Entries -join ', ')"
