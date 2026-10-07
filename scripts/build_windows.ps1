param([string]$Flutter = "flutter", [string]$InnoSetup = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe")
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
function Run-Checked([scriptblock]$Command) { & $Command; if ($LASTEXITCODE -ne 0) { throw "Build command failed ($LASTEXITCODE)." } }
Run-Checked { & $Flutter pub get --enforce-lockfile }
Run-Checked { & $Flutter build windows --release }
Run-Checked { cmake -S native/whisper -B build/whisper-win -A x64 -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF }
Run-Checked { cmake --build build/whisper-win --config Release --parallel 6 }
Copy-Item build/whisper-win/Release/lumawhisper.dll build/windows/x64/runner/Release/
Copy-Item docs/licenses build/windows/x64/runner/Release/licenses -Recurse -Force
Copy-Item docs/THIRD_PARTY_NOTICES.md build/windows/x64/runner/Release/
# Install official VC runtime app-locally so the user needs no development tools.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Get-ChildItem "$vs\VC\Redist\MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$crt = Join-Path $redist.FullName 'x64\Microsoft.VC143.CRT'
if (!(Test-Path $crt)) { throw 'VC143 app-local runtime not found; install the VS2022 C++ build tools.' }
Copy-Item "$crt\*.dll" build/windows/x64/runner/Release/
if (!(Test-Path $InnoSetup)) { throw 'Inno Setup 6 is required for the installer.' }
Run-Checked { & $InnoSetup scripts/installer.iss }
Get-ChildItem dist/LumaCaption-*-windows-x64.exe | ForEach-Object { $Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); "$Hash  $($_.Name)" | Set-Content "$($_.FullName).sha256" -Encoding ascii }
Get-ChildItem dist/LumaCaption-*-windows-x64.exe | ForEach-Object { $Artifact = $_.FullName; Run-Checked { dart run scripts/artifact_manifest.dart $Artifact windows x64 } }
