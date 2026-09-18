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
    # Publish omits the NuGet runtime-pack licenses; include the exact versions shipped in this ZIP.
    $runtime = Get-Content (Join-Path $publish "GitHubSignal.runtimeconfig.json") -Raw | ConvertFrom-Json
    $assets = Get-Content "windows/GitHubSignal.Windows/obj/project.assets.json" -Raw | ConvertFrom-Json
    $licenses = Join-Path $publish "licenses"
    New-Item -ItemType Directory -Path $licenses -Force | Out-Null
    foreach ($framework in $runtime.runtimeOptions.includedFrameworks) {
        $package = "$($framework.name.ToLowerInvariant()).runtime.win-x64/$($framework.version)"
        $pack = $assets.packageFolders.PSObject.Properties.Name | ForEach-Object { Join-Path $_ $package } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $pack) { throw "Runtime license source missing: $package" }
        $documents = Get-ChildItem $pack -File | Where-Object { $_.Name -match '^(LICENSE|THIRD-PARTY-NOTICES)(\.TXT)?$' }
        if (-not $documents) { throw "Runtime license missing: $package" }
        foreach ($document in $documents) {
            Copy-Item $document.FullName (Join-Path $licenses "$($framework.name)-$($document.Name)")
        }
    }
    $archive = Join-Path $output "GitHubSignal-$version-windows-x64.zip"
    Compress-Archive -Path "$publish/*" -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($archive))" | Set-Content "$archive.sha256" -Encoding ascii
    Write-Output $archive
} finally { Pop-Location }
