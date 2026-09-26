param([ValidateSet('phase1','phase2a','production')][string]$Mode = 'production')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location -LiteralPath $root
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:JAVA_TOOL_OPTIONS = '-Djdk.util.zip.disableZip64ExtraFieldValidation=true'
$entry = Join-Path $root 'phone/src/main/ets/pages/Index.ets'
$original = [IO.File]::ReadAllBytes($entry)
$nativeRefresh = Join-Path $root 'phone/src/main/ets/pages/NativeRefresh.ets'
if (Test-Path -LiteralPath $nativeRefresh) { throw 'Temporary NativeRefresh.ets already exists; preserve and inspect it first.' }
if ($Mode -eq 'production') {
  foreach ($name in @('sync-phase2a-config.json','sync-phase2a-ca.pem','voice-review-fixture.json','sync-phase1-test-ca.pem')) {
    if (Test-Path -LiteralPath (Join-Path $root "phone/src/main/resources/rawfile/$name")) {
      throw "Remove the generated test resource before production build: $name"
    }
  }
}
try {
  if ($Mode -ne 'production') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "sync-$Mode-device/Index.ets") -Destination $entry
    if ($Mode -eq 'phase2a') {
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sync-phase2a-device/NativeRefresh.ets') -Destination $nativeRefresh
    }
  }
  & 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode project -p product=phone -p buildMode=debug clean assembleApp --no-daemon
  $buildExit = $LASTEXITCODE
} finally {
  [IO.File]::WriteAllBytes($entry, $original)
  if ($Mode -eq 'phase2a' -and (Test-Path -LiteralPath $nativeRefresh)) { Remove-Item -LiteralPath $nativeRefresh }
}
exit $buildExit
