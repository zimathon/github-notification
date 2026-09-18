param([string]$OutputDirectory = "dist")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $version = ([xml](Get-Content "windows/Directory.Build.props")).Project.PropertyGroup.Version
    $output = [System.IO.Path]::GetFullPath($OutputDirectory)
    $publish = Join-Path $output "windows-x64"
    # Use a fresh staging directory so removed assemblies cannot leak into later packages.
    if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
    dotnet publish windows/GitHubSignal.Windows -c Release -r win-x64 --self-contained true -o $publish -p:DebugType=None -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) { throw "Windows publish failed" }
    Copy-Item windows/README.txt $publish
    $archive = Join-Path $output "GitHubSignal-$version-windows-x64.zip"
    Compress-Archive -Path "$publish/*" -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($archive))" | Set-Content "$archive.sha256" -Encoding ascii
    Write-Output $archive
} finally { Pop-Location }
