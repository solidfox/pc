# GPU-only check for a used RTX 3090 (stability, thermals, throttling, driver errors). Run from an ADMINISTRATOR cmd:
#   powershell "irm https://is.gd/pcz440|iex"      (in PowerShell: irm https://is.gd/pcz440|iex)
# Full 24 GB VRAM test (memtest_vulkan, 0.6 MB) + compute load (llama.cpp Vulkan 38 MB + 1 GB model). ~9 min. Quick mode (0.5 GB model): set QUICK=1 first.
$SelfUrl = 'https://raw.githubusercontent.com/solidfox/pc/main/z.ps1'
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$W = Join-Path $env:TEMP 'pccheck'; New-Item -ItemType Directory -Force $W | Out-Null
$Log = Join-Path $W 'report.txt'
try { Invoke-WebRequest $SelfUrl -OutFile (Join-Path $W 'z.ps1') -UseBasicParsing } catch {}
try { Start-Transcript -Path $Log -Force | Out-Null } catch {}
$Failures = New-Object System.Collections.ArrayList
$Verdicts = New-Object System.Collections.ArrayList
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Hdr($t){ Write-Host "`n==== $t ====" -ForegroundColor Cyan }
function V($lvl,$msg){ [void]$Verdicts.Add([pscustomobject]@{L=$lvl;M=$msg}); $c=@{PASS='Green';WARN='Yellow';FAIL='Red'}[$lvl]; Write-Host "  [$lvl] $msg" -ForegroundColor $c }
function Step($name,[scriptblock]$b){ Hdr $name; try { & $b } catch { [void]$Failures.Add("${name}: $($_.Exception.Message)"); V 'WARN' "Check '$name' crashed: $($_.Exception.Message)" } }
function Num($s){ $d=0.0; if([double]::TryParse(("$s" -replace '[^\d\.\-]',''),[Globalization.NumberStyles]::Float,$Inv,[ref]$d)){ $d } else { $null } }
function Events($filter){ try { ,@(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) } catch { if($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found'){ ,@() } else { $null } } }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ V 'WARN' 'Not running as Administrator: the NVIDIA driver log may be unreadable. Re-run from an admin cmd for full results.' }
$Start = Get-Date

Step 'NVIDIA driver error history (last 90 days)' {
  $nv=Events @{LogName='System';ProviderName='nvlddmkm';StartTime=(Get-Date).AddDays(-90)}
  if($null -eq $nv){ V 'WARN' 'Could not read NVIDIA driver log' } elseif($nv.Count){ V 'WARN' "$($nv.Count) NVIDIA driver errors in the past (TDR/Xid)"; $nv|Select -First 5|%{ "    $($_.TimeCreated) $(("$($_.Message)" -split "`n")[0])" } } else { V 'PASS' 'No NVIDIA driver errors' }
  # TDR recoveries are logged by the 'Display' provider (event 4101), not nvlddmkm
  $td=Events @{LogName='System';ProviderName='Display';Id=4101;StartTime=(Get-Date).AddDays(-90)}
  if($td){ $td=@($td|?{ "$($_.Message)" -match 'nvlddmkm' }); if($td.Count){ V 'WARN' "$($td.Count) NVIDIA driver timeouts/recoveries in the past (TDR, event 4101)"; $td|Select -First 3|%{ "    $($_.TimeCreated)" } } }
}

$smi=$null
Step 'GPU info' {
  $script:smi=(Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
  if(-not $script:smi){ foreach($p in "$env:WINDIR\System32\nvidia-smi.exe","C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"){ if(Test-Path $p){ $script:smi=$p } } }
  if(-not $script:smi){ $script:smi=(Get-ChildItem "$env:WINDIR\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe" -ErrorAction SilentlyContinue | Select -First 1).FullName }
  if(-not $script:smi){ throw 'nvidia-smi not found (NVIDIA driver missing?)' }
  & $script:smi -i 0 --query-gpu=name,vbios_version,driver_version,memory.total,pcie.link.gen.max,pcie.link.width.max,power.limit,temperature.gpu,fan.speed --format=csv
  $g=(& $script:smi -i 0 --query-gpu=name,memory.total --format=csv,noheader,nounits) -split ','
  if($LASTEXITCODE -ne 0){ throw "nvidia-smi exit $LASTEXITCODE" }
  if($g[0] -match '3090'){ V 'PASS' $g[0].Trim() } else { V 'FAIL' "GPU is '$($g[0])', not a 3090" }
  $vr=Num $g[1]; if($vr -ge 24000){ V 'PASS' "$vr MiB VRAM" } else { V 'FAIL' "VRAM $vr MiB" }
}

$mtv=$null
Step 'Download VRAM tester (memtest_vulkan)' {
  if(-not $smi){ throw 'skipped: no nvidia-smi' }
  $e=Join-Path $W 'memtest_vulkan.exe'
  if(-not (Test-Path $e)){
    $u='https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0.exe'
    try { $r=Invoke-RestMethod 'https://api.github.com/repos/GpuZelenograd/memtest_vulkan/releases/latest' -Headers @{'User-Agent'='pccheck'}; $a=$r.assets|?{ $_.name -match '^memtest_vulkan-v[\d\.]+\.exe$' }|Select -First 1; if($a){ $u=$a.browser_download_url } } catch {}
    & curl.exe -L --fail -s -S -o "$e.part" $u; if($LASTEXITCODE -ne 0){ Remove-Item "$e.part" -ErrorAction SilentlyContinue; throw 'memtest_vulkan download failed' }
    Move-Item "$e.part" $e -Force
  }
  $script:mtv=$e; V 'PASS' 'VRAM tester ready'
}

$bench=$null; $model=$null
Step 'Download GPU stress tool (llama.cpp Vulkan) and small test model' {
  if(-not $smi){ throw 'skipped: no nvidia-smi' }
  $L=Join-Path $W 'llamavk'
  $script:bench=Get-ChildItem $L -Recurse -Filter llama-bench.exe -ErrorAction SilentlyContinue | Select -First 1
  if($script:bench -and -not (Test-Path (Join-Path $script:bench.DirectoryName 'ggml-vulkan*.dll'))){ $script:bench=$null }
  if(-not $script:bench){
    $rels=Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30' -Headers @{'User-Agent'='pccheck'}
    $bin=$null; foreach($r in $rels){ $bin=$r.assets | ? { $_.name -match '^llama-.*-bin-win-vulkan-x64\.zip$' } | Select -First 1; if($bin){ break } }
    if(-not $bin){ throw 'No llama.cpp release with a Windows Vulkan build found' }
    New-Item -ItemType Directory -Force $L | Out-Null
    $z=Join-Path $W $bin.name; "  $($bin.name) ($([int]($bin.size/1MB)) MB)"
    & curl.exe -L --fail -s -S -o $z $bin.browser_download_url; if($LASTEXITCODE -ne 0){ throw "download failed: $($bin.name)" }
    Expand-Archive $z -DestinationPath $L -Force
    $script:bench=Get-ChildItem $L -Recurse -Filter llama-bench.exe | Select -First 1
    if(-not $script:bench){ throw 'llama-bench.exe not in archive' }
  }
  if($env:QUICK -eq '1'){ $u='https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q8_0.gguf' }
  else { $u='https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf' }
  $m=Join-Path $W (Split-Path $u -Leaf)
  if(-not (Test-Path $m)){
    "  model $(Split-Path $u -Leaf) (0.5-1 GB)..."; $t=Get-Date
    & curl.exe -L --fail -S -# -o "$m.part" $u
    if($LASTEXITCODE -ne 0){ Remove-Item "$m.part" -ErrorAction SilentlyContinue; throw 'model download failed' }
    $fs=[IO.File]::OpenRead("$m.part"); $hdr=New-Object byte[] 4; [void]$fs.Read($hdr,0,4); $fs.Close()
    if([Text.Encoding]::ASCII.GetString($hdr) -ne 'GGUF'){ Remove-Item "$m.part"; throw 'downloaded model is not a GGUF file' }
    Move-Item "$m.part" $m -Force; "  took $([int]((Get-Date)-$t).TotalSeconds) s"
  }
  $script:model=$m; V 'PASS' 'Benchmark tools ready'
}

function RunBench($argList,$timeoutSec){
  $out=Join-Path $W ('bench-'+[guid]::NewGuid().ToString('N')+'.txt')
  $p=Start-Process $bench.FullName -ArgumentList $argList -RedirectStandardOutput $out -RedirectStandardError "$out.err" -PassThru -NoNewWindow
  $null=$p.Handle
  if(-not $p.WaitForExit($timeoutSec*1000)){ try{ $p.Kill() }catch{}; throw "llama-bench timed out after $timeoutSec s" }
  $txt=Get-Content $out -Raw -ErrorAction SilentlyContinue
  if($p.ExitCode -ne 0){ throw "llama-bench exit $($p.ExitCode): $((Get-Content "$out.err" -Tail 5) -join ' | ')" }
  $txt
}

$csv=Join-Path $W 'gpu-log.csv'; $mon=$null; $TestStart=$null; $cols=@()
Remove-Item $csv -ErrorAction SilentlyContinue  # a stale log from an earlier run must not be summarised if the test is skipped
Step 'GPU test: full VRAM (~5 min) then compute load (~3 min)' {
  if(-not $mtv -and (-not $bench -or -not $model)){ throw 'skipped: test tools unavailable (GPU info above still valid)' }
  $fields='timestamp','temperature.gpu','utilization.gpu','power.draw','clocks.sm','clocks.mem','fan.speed','memory.used','pcie.link.gen.current','pcie.link.width.current'
  $tr=$null; foreach($pre in 'clocks_event_reasons','clocks_throttle_reasons'){ & $smi -i 0 --query-gpu="$pre.active" --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $tr=$pre; break } }
  $ok=@(); foreach($f in $fields){ & $smi -i 0 --query-gpu=$f --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $ok+=$f } }
  if($tr){ foreach($s in 'hw_slowdown','sw_thermal_slowdown','hw_thermal_slowdown','hw_power_brake_slowdown'){ & $smi -i 0 --query-gpu="$tr.$s" --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $ok+="$tr.$s" } } }
  $script:cols=$ok; Remove-Item $csv -ErrorAction SilentlyContinue
  $script:TestStart=Get-Date
  $script:mon=Start-Process $smi -ArgumentList '-i','0',"--query-gpu=$($ok -join ',')",'--format=csv,noheader,nounits','-l','2' -RedirectStandardOutput $csv -PassThru -WindowStyle Hidden
  try {
    if($mtv){
      "  VRAM test: memtest_vulkan writes and checks nearly all 24 GB repeatedly (standard 5-minute run)..."
      $mo=Join-Path $W 'mtv-out.txt'; Remove-Item $mo,(Join-Path $W 'memtest_vulkan.log') -ErrorAction SilentlyContinue
      Get-Process memtest_vulkan* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      $mp=Start-Process $mtv -WorkingDirectory $W -RedirectStandardOutput $mo -RedirectStandardError "$mo.err" -PassThru -WindowStyle Hidden
      $mEnd=(Get-Date).AddSeconds(420); $mt=''
      while((Get-Date) -lt $mEnd){
        Start-Sleep 10; $mt=(Get-Content $mo -Raw -ErrorAction SilentlyContinue) + (Get-Content (Join-Path $W 'memtest_vulkan.log') -Raw -ErrorAction SilentlyContinue)
        if($mt -match 'Standard 5-minute test (PASSed|fail)|Error found' -or $mt -match 'testing finished|testing PASSed|INIT OR FIRST testing failed|runtime error occured'){ break }
        if($mp.HasExited -and -not (Get-Process memtest_vulkan* -ErrorAction SilentlyContinue)){ break }
      }
      Get-Process memtest_vulkan* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      $sz=[regex]::Matches($mt,'Test memory size\s+([\d\.]+)GB') | Select -Last 1
      $gb=if($sz){ Num $sz.Groups[1].Value }else{ $null }
      if($gb){ "  Tested $gb GB of VRAM" }
      ($mt -split "`n" | ? { $_ -match 'written:|Error found|Errors address|Standard 5-minute' } | Select -Last 4) | % { "    $($_.Trim())" }
      if($mt -match 'ERRORS FOUND|Error found'){ V 'FAIL' 'VRAM errors found by memtest_vulkan (faulty memory or overheating VRAM)' }
      elseif($mt -match 'Standard 5-minute test PASSed'){ if($gb -and $gb -lt 20){ V 'WARN' "VRAM test passed but covered only $gb GB" } elseif($gb){ V 'PASS' "VRAM test passed ($gb GB written and verified, no errors)" } else { V 'PASS' 'VRAM test passed (no errors)' } }
      else { [void]$Failures.Add("VRAM test: did not complete. Output tail: $((($mt -split "`n") | Select -Last 5) -join ' | ')"); V 'WARN' 'VRAM test did not complete (see output above)' }
    }
    if(-not $bench -or -not $model){ throw 'compute load skipped: llama.cpp tools unavailable' }
    "  Warm-up benchmark:"; RunBench @('-m',"`"$model`"",'-ngl','99','-p','512','-n','128','-r','3') 300 | Write-Host
    $end=(Get-Date).AddMinutes(2)
    while((Get-Date) -lt $end){
      [void](RunBench @('-m',"`"$model`"",'-ngl','99','-p','4096','-n','0','-ub','2048','-r','30') 240)
      $last=Get-Content $csv -Tail 1 -ErrorAction SilentlyContinue
      if($last){ $v=$last -split ','; $h=@{}; for($i=0;$i -lt $ok.Count -and $i -lt $v.Count;$i++){ $h[$ok[$i]]=$v[$i].Trim() }
        "  temp $($h['temperature.gpu'])C  util $($h['utilization.gpu'])%  power $($h['power.draw'])W  sm $($h['clocks.sm'])MHz  mem $($h['clocks.mem'])MHz  fan $($h['fan.speed'])%" }
    }
    "  Hot benchmark:"; RunBench @('-m',"`"$model`"",'-ngl','99','-p','512','-n','128','-r','3') 300 | Write-Host
  } finally { if($script:mon){ try{ Stop-Process $script:mon -Force }catch{} }; Start-Sleep 1 }
}

Step 'GPU load summary' {
  if(-not (Test-Path $csv)){ throw 'no GPU monitor log (load test did not run)' }
  $rows=@(Get-Content $csv | ? { $_ -match '\d' } | % { $v=$_ -split ','; $h=@{}; for($i=0;$i -lt $cols.Count -and $i -lt $v.Count;$i++){ $h[$cols[$i]]=$v[$i].Trim() }; $h })
  $busy=@($rows | ? { (Num $_['utilization.gpu']) -ge 80 })
  "  Samples: $($rows.Count), under load: $($busy.Count)"
  if($busy.Count -lt 20){ V 'FAIL' "GPU barely loaded ($($busy.Count) busy samples) - test inconclusive"; return }
  $temps=@($rows|%{ Num $_['temperature.gpu'] }|?{ $_ -ne $null }); $pw=@($rows|%{ Num $_['power.draw'] }|?{ $_ -ne $null })
  $mt=($temps|Measure-Object -Maximum).Maximum; $mp=($pw|Measure-Object -Maximum).Maximum
  $sm=($busy|%{ Num $_['clocks.sm'] }|?{ $_ -ne $null }|Measure-Object -Average).Average
  "  Max core temp: $mt C   Max power: $mp W   Avg SM clock under load: $([int]$sm) MHz"
  if($mt -eq $null){ V 'WARN' 'No temperature data' } elseif($mt -ge 87){ V 'FAIL' "Hot: $mt C core (repaste/pads likely)" } elseif($mt -ge 83){ V 'WARN' "Warm: $mt C core (normal-ish for OEM blower)" } else { V 'PASS' "Core temp OK ($mt C)" }
  if($mp -ne $null -and $mp -lt 250){ V 'WARN' "Peak power only $mp W - may be power-limited" }
  # No GDDR6X temp in nvidia-smi; an overheating GDDR6X shows up as the memory clock dropping under load
  $mc=@($busy|%{ Num $_['clocks.mem'] }|?{ $_ -ne $null })
  if($mc.Count){ $mx=($mc|Measure-Object -Maximum).Maximum; $low=@($mc|?{ $_ -lt 0.85*$mx }).Count
    if($low -ge 3){ V 'WARN' "Memory clock fell below 85% of $mx MHz in $low loaded samples (possible hot GDDR6X throttling)" } else { V 'PASS' "Memory clock steady under load ($mx MHz)" } }
  $w=$busy|%{ Num $_['pcie.link.width.current'] }|?{ $_ -ne $null }|Select -First 1
  $gn=$busy|%{ $_['pcie.link.gen.current'] }|Select -First 1
  if($w -eq $null){ V 'WARN' 'PCIe width unknown' } elseif($w -lt 16){ V 'FAIL' "PCIe link x$w (should be x16)" } else { V 'PASS' "PCIe gen $gn x$w" }
  $thr=@($cols|?{ $_ -match 'slowdown' })
  if(-not $thr.Count){ V 'WARN' 'Throttle reasons not supported by this driver' }
  foreach($c in $thr){ $hits=@($rows|?{ $_[$c] -eq 'Active' }).Count; if($hits){ $lvl=if($c -match 'hw_'){'FAIL'}else{'WARN'}; V $lvl "$c active in $hits samples" } }
  if($thr.Count -and -not ($thr|?{ $c=$_; @($rows|?{ $_[$c] -eq 'Active' }).Count })){ V 'PASS' 'No throttling or power-brake events' }
  $nv2=Events @{LogName='System';ProviderName='nvlddmkm';StartTime=$TestStart}
  if($null -eq $nv2){ V 'WARN' 'Could not read NVIDIA log after test' } elseif($nv2.Count){ V 'FAIL' "NVIDIA driver errors during test: $($nv2.Count)" } else { V 'PASS' 'No driver errors during test' }
  $td2=Events @{LogName='System';ProviderName='Display';Id=4101;StartTime=$TestStart}
  if($td2){ $td2=@($td2|?{ "$($_.Message)" -match 'nvlddmkm' }); if($td2.Count){ V 'FAIL' "NVIDIA driver timed out and recovered during test (TDR) $($td2.Count)x" } }
}

Hdr 'VERDICT'
foreach($l in 'FAIL','WARN','PASS'){ $Verdicts | ? { $_.L -eq $l } | % { Write-Host "  [$l] $($_.M)" -ForegroundColor (@{PASS='Green';WARN='Yellow';FAIL='Red'}[$l]) } }
"  Note: GPU-only check (RAM, disks and CPU not tested). Full VRAM write/verify (memtest_vulkan) plus sustained compute load; core temp does not show GDDR6X memory temperature (memory-clock drops are flagged instead)."
if($Failures.Count){ "`n  Checks that crashed:"; $Failures | % { "   - $_" } }
try { Stop-Transcript | Out-Null } catch {}
Write-Host "`nReport: $Log" -ForegroundColor Cyan

if($Failures.Count){
  $a=Read-Host "`nSome checks crashed. Install/launch Claude Code to diagnose and fix them? You'll log in yourself in the browser (y/N)"
  if($a -match '^(y|j)'){
    $claude=(Get-Command claude -ErrorAction SilentlyContinue).Source
    if(-not $claude -and (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")){ $claude="$env:USERPROFILE\.local\bin\claude.exe" }
    if(-not $claude){ Write-Host 'Installing Claude Code (official installer)...'
      # Child process: the installer may 'exit' or change StrictMode/ErrorActionPreference, which would kill or alter this session
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://claude.ai/install.ps1 | iex"
      $env:Path="$env:USERPROFILE\.local\bin;$env:Path"; $claude=(Get-Command claude -ErrorAction SilentlyContinue).Source
      if(-not $claude -and (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")){ $claude="$env:USERPROFILE\.local\bin\claude.exe" } }
    if(-not $claude){ Write-Host 'Claude Code install failed.' -ForegroundColor Red }
    else {
      $fl=Join-Path $W 'failures.txt'; $Failures | Set-Content $fl
      $prompt="I'm testing the RTX 3090 in a used PC before buying it (GPU-only check). The check script $W\z.ps1 (source: $SelfUrl) ran and some checks crashed; failures are in $fl and the full report is $Log. Diagnose why those checks failed, fix the test code (not drivers, BIOS or hardware settings), and re-run only the failed checks. Summarize the hardware results plainly at the end."
      Push-Location $W; & $claude $prompt; Pop-Location
      Write-Host "`nWhen done: type /logout inside Claude before quitting (or delete $env:USERPROFILE\.claude and $env:USERPROFILE\.claude.json) so your login isn't left on this PC." -ForegroundColor Yellow
    }
  }
}
Write-Host "Cleanup when finished: Remove-Item -Recurse -Force '$W'" -ForegroundColor Cyan
