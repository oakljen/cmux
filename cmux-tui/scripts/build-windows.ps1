# Build cmux-tui on Windows. Needs: git, Python (for libclang wheel), Visual Studio Build Tools.
# Installs Rust 1.95.0 via rustup, Zig 0.16.0 and libclang into $Toolchains (no system PATH changes).
param([string]$Toolchains = "$env:USERPROFILE\cmux-toolchains")
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path "$PSScriptRoot\..\.."
New-Item -ItemType Directory -Force $Toolchains | Out-Null

if (-not (Get-Command cargo -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:USERPROFILE\.cargo\bin\cargo.exe")) {
    $init = "$Toolchains\rustup-init.exe"
    Invoke-WebRequest https://win.rustup.rs/x86_64 -OutFile $init
    & $init -y --default-toolchain 1.95.0 --profile minimal
}

$zigDir = "$Toolchains\zig-x86_64-windows-0.16.0"
if (-not (Test-Path "$zigDir\zig.exe")) {
    $zip = "$Toolchains\zig.zip"
    Invoke-WebRequest https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e') { throw "Zig checksum mismatch: $hash" }
    Expand-Archive $zip -DestinationPath $Toolchains
}

$clang = "$Toolchains\libclang-pkg\clang\native"
if (-not (Test-Path "$clang\libclang.dll")) {
    python -m pip install --quiet --target "$Toolchains\libclang-pkg" libclang
}

$env:PATH = "$env:USERPROFILE\.cargo\bin;$zigDir;$env:PATH"
$env:LIBCLANG_PATH = $clang
git -C $Root submodule update --init --depth 1 ghostty
Push-Location "$Root\cmux-tui"
try { cargo build -p cmux-tui } finally { Pop-Location }
Write-Host "built: $Root\cmux-tui\target\debug\cmux-tui.exe"
