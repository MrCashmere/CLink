param(
  [string]$SdkNative = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native',
  [string[]]$Targets = @('aarch64-unknown-linux-ohos', 'x86_64-unknown-linux-ohos')
)
$ErrorActionPreference = 'Stop'
$mtaProject = Split-Path -Parent $PSScriptRoot
$mtaToolRoot = Join-Path $mtaProject '.toolhome\mta'
New-Item -ItemType Directory -Force $mtaToolRoot | Out-Null
if (Test-Path (Join-Path $mtaToolRoot 'cargo\bin\cargo.exe')) {
  $env:CARGO_HOME = Join-Path $mtaToolRoot 'cargo'
  $env:RUSTUP_HOME = Join-Path $mtaToolRoot 'rustup'
  $env:PATH = (Join-Path $env:CARGO_HOME 'bin') + ';' + $env:PATH
}
$mtaClang = Join-Path $SdkNative 'llvm\bin\clang.exe'
$env:OHOS_NDK_HOME = Split-Path -Parent $SdkNative
$mtaGnu = Get-ChildItem -LiteralPath $mtaToolRoot -Directory -Filter 'llvm-mingw-*-ucrt-x86_64' | Select-Object -First 1
if ($null -ne $mtaGnu) {
  $env:PATH = (Join-Path $mtaGnu.FullName 'bin') + ';' + $env:PATH
  $env:CARGO_BUILD_RUSTC_WRAPPER = ''
  $mtaHostLinker = Join-Path $mtaToolRoot 'host-gnu-linker.cmd'
  $mtaHostGcc = Join-Path $mtaGnu.FullName 'bin\x86_64-w64-mingw32-gcc.exe'
  $mtaHostLib = Join-Path $env:RUSTUP_HOME 'toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained'
  foreach ($mtaRuntimeLib in @('libgcc.a', 'libgcc_eh.a', 'libgcc_s.a')) {
    Copy-Item -LiteralPath (Join-Path $mtaHostLib $mtaRuntimeLib) -Destination (Join-Path $mtaGnu.FullName 'x86_64-w64-mingw32\lib') -Force
  }
  Set-Content -LiteralPath $mtaHostLinker -Value "@`"$mtaHostGcc`" %*" -Encoding ascii
  $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = $mtaHostLinker
}
if (!(Test-Path -LiteralPath $mtaClang)) { throw "OHOS clang 不存在：$mtaClang" }
foreach ($mtaTarget in $Targets) {
  $mtaWrapper = Join-Path $mtaToolRoot ($mtaTarget + '-clang.cmd')
  New-Item -ItemType Directory -Force $mtaToolRoot | Out-Null
  Set-Content -LiteralPath $mtaWrapper -Value "@`"$mtaClang`" --target=$mtaTarget --sysroot=`"$SdkNative\sysroot`" %*" -Encoding ascii
  $mtaEnvSuffix = $mtaTarget.Replace('-', '_')
  Set-Item "env:CC_$mtaEnvSuffix" $mtaWrapper
  Set-Item "env:AR_$mtaEnvSuffix" (Join-Path $SdkNative 'llvm\bin\llvm-ar.exe')
  Set-Item ('env:CARGO_TARGET_' + $mtaEnvSuffix.ToUpper() + '_LINKER') $mtaWrapper
  if ($null -ne $mtaGnu) {
    & cargo +stable-x86_64-pc-windows-gnu build --manifest-path (Join-Path $mtaProject 'mta_native\Cargo.toml') --release --target $mtaTarget
  } else {
    & cargo build --manifest-path (Join-Path $mtaProject 'mta_native\Cargo.toml') --release --target $mtaTarget
  }
  if ($LASTEXITCODE -ne 0) { throw "MTA Rust 构建失败：$mtaTarget" }
  $mtaAbi = if ($mtaTarget.StartsWith('aarch64')) { 'arm64-v8a' } else { 'x86_64' }
  $mtaOutput = Join-Path $mtaProject "entry\libs\$mtaAbi"
  New-Item -ItemType Directory -Force $mtaOutput | Out-Null
  Copy-Item -LiteralPath (Join-Path $mtaProject "mta_native\target\$mtaTarget\release\libmta_core.so") -Destination $mtaOutput
}
