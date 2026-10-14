param()
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$entryPath=Join-Path $taskRoot 'phone/src/main/ets/pages/Index.ets'
$helperPath=Join-Path $taskRoot 'phone/src/main/ets/pages/ProductAcceptance.ets'
$fixturePath=Join-Path $taskRoot 'phone/src/main/resources/rawfile/product-v2-fixture.json'
$wavePath=Join-Path $taskRoot 'phone/src/main/resources/rawfile/product-v2-fixture.wav'
foreach ($testPath in @($helperPath,$fixturePath,$wavePath)){if(Test-Path -LiteralPath $testPath){throw ('Preserve existing acceptance resource first: '+$testPath)}}
$entryBytes=[IO.File]::ReadAllBytes($entryPath)
Set-Location -LiteralPath $taskRoot
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME='C:\Program Files\Huawei\DevEco Studio\jbr'
$env:JAVA_TOOL_OPTIONS='-Djdk.util.zip.disableZip64ExtraFieldValidation=true'
New-Item -ItemType Directory -Force -Path (Join-Path $taskRoot 'phone/src/main/resources/rawfile') | Out-Null
try{
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'phone-product-device/Index.ets') -Destination $entryPath
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'phone-product-device/ProductAcceptance.ets') -Destination $helperPath
  Copy-Item -LiteralPath (Join-Path $taskRoot 'tests/fixtures/phone-product-v2.json') -Destination $fixturePath
  & python -c "import wave; from pathlib import Path; p=Path('phone/src/main/resources/rawfile/product-v2-fixture.wav'); w=wave.open(str(p),'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(16000*2*12)); w.close()"
  if($LASTEXITCODE -ne 0){throw 'Fixture WAV generation failed'}
  $ErrorActionPreference='Continue'
  & 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap --mode module -p product=phone -p module=phone@default -p buildMode=debug --no-daemon *> outputs/phone-product-v2/build-native-acceptance.log
  $buildCode=$LASTEXITCODE
  $ErrorActionPreference='Stop'
  if($buildCode -eq 0){Copy-Item -LiteralPath 'phone/build/phone/outputs/default/AllDayRecording-phone.hap' -Destination 'outputs/phone-product-v2/AllDayRecording-phone-acceptance.hap'}
}finally{
  [IO.File]::WriteAllBytes($entryPath,$entryBytes)
  foreach($testPath in @($helperPath,$fixturePath,$wavePath)){if(Test-Path -LiteralPath $testPath){Remove-Item -LiteralPath $testPath}}
}
Get-Content outputs/phone-product-v2/build-native-acceptance.log -Tail 25
exit $buildCode


