$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# Read the version by its plist key rather than relying on element order.
$plist = [xml](Get-Content (Join-Path $root 'App/Info.plist') -Raw)
$version = $plist.SelectSingleNode('//key[text()="CFBundleShortVersionString"]').NextSibling.InnerText
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$archive = Join-Path $dist "Codex-Quota-HUD-$version-windows.zip"
$files = @(Get-ChildItem (Join-Path $root 'Windows') -File | ForEach-Object { $_.FullName })
$files += @('LICENSE', 'PRIVACY.md', 'DISCLAIMER.md') | ForEach-Object { Join-Path $root $_ }
Compress-Archive -Path $files -DestinationPath $archive -Force
$checksum = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower() + '  ' + (Split-Path $archive -Leaf)
[IO.File]::WriteAllText("$archive.sha256", $checksum + "`n", [Text.Encoding]::ASCII)
Write-Output $archive
