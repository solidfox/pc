# GPU-only check for a used RTX 3090 (stability, thermals, throttling, driver errors). Run from an ADMINISTRATOR cmd:
#   powershell "irm test.schlaug.com|iex"   (backup: powershell "irm https://is.gd/pcz440|iex"). No NVIDIA driver? It installs the latest Game Ready driver automatically (~1 GB).
# Full 24 GB VRAM test (memtest_vulkan, 0.6 MB) + compute load (llama.cpp Vulkan 38 MB + 1 GB model). ~9 min. Quick mode (0.5 GB model): set QUICK=1 first.
# Never restarts Windows by itself. If a restart is needed it says so: restart, then paste the same line again.
$SelfUrls = 'https://test.schlaug.com/z.ps1','https://raw.githubusercontent.com/solidfox/pc/main/z.ps1'
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$W = Join-Path $env:TEMP 'pccheck'; New-Item -ItemType Directory -Force $W | Out-Null
$Log = Join-Path $W 'report.txt'
$SelfUrl = $null
foreach($u in $SelfUrls){ try { Invoke-WebRequest $u -OutFile (Join-Path $W 'z.ps1') -UseBasicParsing; $SelfUrl = $u; break } catch {} }
try { Start-Transcript -Path $Log -Force | Out-Null } catch {}
$Failures = New-Object System.Collections.ArrayList
$Verdicts = New-Object System.Collections.ArrayList
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Halt = $null; $NeedReboot = $false        # Halt: later checks are pointless (no GPU, restart needed, ...)
$MemRes = 'NOT RUN'; $LoadRes = 'NOT RUN'; $SummaryDone = $false
function Hdr($t){ Write-Host "`n==== $t ====" -ForegroundColor Cyan }
function V($lvl,$msg){ if($Verdicts | ? { $_.L -eq $lvl -and $_.M -eq $msg }){ return }; [void]$Verdicts.Add([pscustomobject]@{L=$lvl;M=$msg}); $c=@{PASS='Green';WARN='Yellow';FAIL='Red'}[$lvl]; Write-Host "  [$lvl] $msg" -ForegroundColor $c }
# throw 'SKIP: ...' = handled (verdict already given or a tool is missing); anything else is a crash for the self-heal
function Step($name,[scriptblock]$b){ if($script:Halt){ return }; Hdr $name; try { & $b } catch { $m="$($_.Exception.Message)"; if($m -like 'SKIP:*'){ Write-Host "  Skipped: $($m.Substring(5).Trim())" -ForegroundColor DarkYellow } else { [void]$Failures.Add("${name}: $m"); V 'WARN' "Check '$name' crashed: $m" } } }
function Num($s){ $d=0.0; if([double]::TryParse(("$s" -replace '[^\d\.\-]',''),[Globalization.NumberStyles]::Float,$Inv,[ref]$d)){ $d } else { $null } }
function Events($filter){ try { ,@(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) } catch { if($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found'){ ,@() } else { $null } } }
function Dl($url,$dest,[switch]$Bar){
  $part="$dest.part"; Remove-Item $part -Force -ErrorAction SilentlyContinue
  $curl=(Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  if($curl){ $pa=if($Bar){'-#'}else{'-s'}; & $curl -L --fail -S $pa --retry 3 --retry-delay 3 -o $part $url; $ok=($LASTEXITCODE -eq 0) }
  else { try { Invoke-WebRequest $url -OutFile $part -UseBasicParsing -UserAgent 'pccheck'; $ok=$true } catch { $ok=$false } }  # Windows without curl.exe (before 1803)
  if(-not $ok -or -not (Test-Path $part)){ Remove-Item $part -Force -ErrorAction SilentlyContinue; throw "download failed: $url" }
  Move-Item $part $dest -Force
}
function Magic($f,$n){ $fs=[IO.File]::OpenRead($f); try { $h=New-Object byte[] $n; [void]$fs.Read($h,0,$n); [Text.Encoding]::ASCII.GetString($h) } finally { $fs.Close() } }

# --- NVIDIA card / driver state (language-independent: PCI IDs, display class GUID, driver service name, status codes) ---
$DisplayClass='{4d36e968-e325-11ce-bfc1-08002be10318}'
function NvDevs { @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'PCI\\VEN_10DE%'" -ErrorAction Stop | ? { $_.ClassGuid -eq $DisplayClass -or (-not $_.ClassGuid -and "$($_.CompatibleID)" -match 'CC_03') } | Sort-Object @{e={ if($_.PNPDeviceID -match 'DEV_220[34]'){0}else{1} }}) }
function SmiCandidates {
  $c=New-Object System.Collections.ArrayList
  # nvidia-smi next to the nvlddmkm.sys Windows is actually using (DCH drivers keep it in the DriverStore)
  try { $pn="$((Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'" -ErrorAction Stop | Select -First 1).PathName)" -replace '^\\SystemRoot',$env:WINDIR -replace '^\\\?\?\\',''
    if($pn){ if(-not [IO.Path]::IsPathRooted($pn)){ $pn=Join-Path $env:WINDIR $pn }; [void]$c.Add((Join-Path (Split-Path $pn) 'nvidia-smi.exe')) } } catch {}
  [void]$c.Add("$((Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source)")
  [void]$c.Add("$env:WINDIR\System32\nvidia-smi.exe"); [void]$c.Add("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")
  Get-ChildItem "$env:WINDIR\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | % { [void]$c.Add($_.FullName) }
  $c | ? { $_ -and (Test-Path $_) } | Select -Unique
}
function SmiTry($p){ try { $o=(& $p -L 2>&1 | Out-String).Trim(); [pscustomobject]@{OK=($LASTEXITCODE -eq 0 -and $o -match 'GPU \d+:');Out=$o} } catch { [pscustomobject]@{OK=$false;Out="$($_.Exception.Message)"} } }
function DrvState {
  $d=@(NvDevs); if(-not $d.Count){ return $null }
  $t=[pscustomobject]@{OK=$false;Out='nvidia-smi not found'}; $sp=$null; $mm=$false
  foreach($p in @(SmiCandidates)){ $r=SmiTry $p; if($r.Out -match 'mismatch'){ $mm=$true }; if(-not $sp -or $r.OK){ $t=$r; $sp=$p }; if($r.OK){ break } }
  [pscustomobject]@{ Dev=$d[0]; Count=$d.Count; Code=[int]$d[0].ConfigManagerErrorCode; Bound=("$($d[0].Service)" -eq 'nvlddmkm'); Smi=$sp; SmiOK=$t.OK; SmiOut=$t.Out; Mismatch=($mm -and -not $t.OK) }
}
function NeedRestart($why){
  $script:NeedReboot=$true; $script:Halt='restart'
  V 'WARN' "GPU NOT TESTED YET: $why"
  Write-Host "`n  >>> Restart Windows now (Start > Power > Restart). Then open cmd as Administrator again and paste the same line:" -ForegroundColor Yellow
  Write-Host '      powershell "irm test.schlaug.com|iex"' -ForegroundColor Yellow
  throw 'SKIP: Windows restart required (this script never restarts by itself)'
}
function CheckState($s){
  if(-not $s){ throw 'the NVIDIA card disappeared from the PCI bus' }
  if($s.Code -eq 14){ NeedRestart 'Windows says the NVIDIA card needs a restart to finish installing its driver (Device Manager code 14).' }
  if($s.Mismatch){ NeedRestart 'a new NVIDIA driver is installed but the old one is still loaded (nvidia-smi: driver/library version mismatch).' }
  if($s.Code -eq 22){ V 'WARN' 'GPU NOT TESTED: the NVIDIA card is disabled in Device Manager. Enable it, then paste the same line again.'; $script:Halt='disabled'; throw 'SKIP: card disabled in Device Manager' }
  if($s.Code -eq 43 -and $s.Bound){ V 'FAIL' 'Windows stopped the NVIDIA card with error Code 43 (typical of a failing GPU or VRAM, sometimes a broken driver install)'
    if(-not $s.SmiOK){ $script:Halt='code 43'; throw 'SKIP: card stopped by Windows (Code 43), nothing more can be tested' } }
}
function WaitDriver($sec){ $end=(Get-Date).AddSeconds($sec); do { $n=DrvState; if(-not $n -or $n.SmiOK -or $n.Code -in 14,22,43 -or $n.Mismatch){ break }; Start-Sleep 5 } while((Get-Date) -lt $end); $n }
function DriverArrived($when){  # Windows Update often installs the NVIDIA driver by itself a few minutes after the card is first seen
  $n=DrvState; CheckState $n
  if($n.Bound -and -not $n.SmiOK){ Write-Host "  Windows is loading an NVIDIA driver ($when); waiting up to 60 s..."; $n=WaitDriver 60; CheckState $n
    if(-not $n.SmiOK){ throw "an NVIDIA driver is bound to the card but nvidia-smi does not work: $($n.SmiOut)" } }
  if($n.SmiOK){ Write-Host "  A working NVIDIA driver is now installed (probably by Windows Update, $when); skipping our download/install."; $script:smi=$n.Smi; return $true }
  $false
}
# Game Ready only, no HP package: the HP Z440 SoftPaqs checked (sp141290 516.40, sp140569 512.78) list only Quadro/RTX A/T cards,
# and the driver is matched on the GPU's own PCI ID (10DE:2204), not on the HP board/firmware. Revisit only if an HP SoftPaq names the RTX 3090.
function InstallDriver {
  if($env:NODRIVER -eq '1'){ throw 'NVIDIA driver missing; auto-install disabled by NODRIVER=1' }
  if(-not $isAdmin){ V 'WARN' 'GPU NOT TESTED: no working NVIDIA driver, and installing one needs Administrator. Open cmd with "Run as administrator" and paste the same line.'; $script:Halt='not admin'; throw 'SKIP: driver install needs Administrator' }
  "  No working NVIDIA driver. Installing the latest NVIDIA Game Ready driver (~1 GB). It matches the GPU's PCI device ID, so Dell/Alienware OEM 3090 cards normally take it too..."
  $q='https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&pfid=930&osID=57&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1'
  $r=Invoke-RestMethod $q -Headers @{'User-Agent'='pccheck'}; if($r -is [string]){ $r=$r | ConvertFrom-Json }
  $di=$r.IDS[0].downloadInfo
  if(-not $di.DownloadURL -or $di.DownloadURL -notmatch '^https://[a-z0-9\.]*nvidia\.com/'){ throw 'Could not look up the NVIDIA driver download' }
  $ver="$($di.Version)".Trim()
  $de=Join-Path $W (Split-Path $di.DownloadURL -Leaf)
  "  Driver $ver ($($di.DownloadURLFileSize)) from $($di.DownloadURL)"
  if(DriverArrived 'before the download'){ return }
  if(-not (Test-Path $de)){ Dl $di.DownloadURL $de -Bar }
  $sig=Get-AuthenticodeSignature $de
  if($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'NVIDIA'){ Remove-Item $de -Force -ErrorAction SilentlyContinue; throw "driver installer signature not valid/NVIDIA ($($sig.Status))" }
  if(DriverArrived 'during the download'){ return }
  "  Installing silently (a few minutes; the screen may flicker or go black briefly). Do not restart..."
  $ip=Start-Process $de -ArgumentList '-s','-noreboot','-noeula','-clean' -PassThru -Wait
  $rc=$ip.ExitCode; "  Installer exit code $rc. Waiting for Windows to load the driver..."
  $n=WaitDriver 120; CheckState $n
  "  Windows device status code $($n.Code), driver service '$($n.Dev.Service)'"
  if(-not $n.SmiOK){ throw "driver installer exit $rc, but the card is still not running on the NVIDIA driver (status code $($n.Code), service '$($n.Dev.Service)'). Restart Windows and paste the same line; if it still fails, this driver did not accept the card. nvidia-smi: $($n.SmiOut)" }
  $script:smi=$n.Smi
  $got="$(& $n.Smi --query-gpu=driver_version --format=csv,noheader 2>$null | Select -First 1)".Trim()
  if($got -eq $ver){ V 'PASS' "Installed NVIDIA driver $ver (nvidia-smi confirms it is running)" }
  else { V 'WARN' "Driver installer exit $rc, but nvidia-smi reports driver '$got' instead of $ver. Testing continues on the running driver; if anything fails, restart and paste the same line." }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ V 'WARN' 'Not running as Administrator: a missing NVIDIA driver cannot be installed and logs may be unreadable. Re-run from an admin cmd for full results.' }
try { $root=[IO.Path]::GetPathRoot($W); $free=(New-Object IO.DriveInfo $root).AvailableFreeSpace/1GB; if($free -lt 5){ V 'WARN' ("Only {0:N1} GB free on {1} - the downloads and the driver install need about 4 GB" -f $free,$root) } } catch {}
$Start = Get-Date

Step 'NVIDIA driver error history (last 90 days)' {
  try { $old=(Get-WinEvent -LogName System -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated; if($old -gt (Get-Date).AddDays(-90)){ "  Note: the System log only goes back to $old (fresh Windows or cleared log), so the history is short." } } catch {}
  $nv=Events @{LogName='System';ProviderName='nvlddmkm';Level=1,2,3;StartTime=(Get-Date).AddDays(-90)}
  if($null -eq $nv){ if(Get-WinEvent -ListProvider nvlddmkm -ErrorAction SilentlyContinue){ V 'WARN' 'Could not read NVIDIA driver log' } else { '  No NVIDIA driver has been installed on this Windows yet, so there is no driver history.' } }
  elseif($nv.Count){ V 'WARN' "$($nv.Count) NVIDIA driver errors in the past (TDR/Xid)"; $nv|Select -First 5|%{ "    $($_.TimeCreated) $(("$($_.Message)" -split "`n")[0])" } } else { V 'PASS' 'No NVIDIA driver errors' }
  # TDR recoveries are logged by the 'Display' provider (event 4101), not nvlddmkm
  $td=Events @{LogName='System';ProviderName='Display';Id=4101;StartTime=(Get-Date).AddDays(-90)}
  if($td){ $td=@($td|?{ "$($_.Message)" -match 'nvlddmkm' }); if($td.Count){ V 'WARN' "$($td.Count) NVIDIA driver timeouts/recoveries in the past (TDR, event 4101)"; $td|Select -First 3|%{ "    $($_.TimeCreated)" } } }
}

$smi=$null; $GI='0'
Step 'GPU info and NVIDIA driver' {
  $s=DrvState
  if(-not $s){ V 'FAIL' 'No NVIDIA graphics card detected on the PCI bus (card missing, not seated, or not powered)'; $script:Halt='no GPU'; throw 'SKIP: no NVIDIA GPU detected' }
  $id="$($s.Dev.PNPDeviceID)"; $dv=if($id -match 'DEV_([0-9A-F]{4})'){ $matches[1] }; $sv=if($id -match 'SUBSYS_[0-9A-F]{4}([0-9A-F]{4})'){ $matches[1] }
  "  GPU PCI: $($s.Dev.Name) [$id]$(if($sv -eq '1028'){' - Dell/Alienware OEM version of the card (the PC itself can be any make)'})"
  "  Windows device status code $($s.Code) (0 = working), driver service '$($s.Dev.Service)'$(if($s.Count -gt 1){", $($s.Count) NVIDIA display devices"})"
  # Identity: the PCI device ID decides the driver; the card maker (SUBSYS: Dell 1028, NVIDIA, ASUS...) is only informational.
  # Not a hard FAIL: nvidia-smi's name + 24 GB check below is the authoritative 3090 test once a driver runs.
  if($dv -eq '2204'){ "  PCI ID 10DE:2204 = GeForce RTX 3090" } elseif($dv -eq '2203'){ "  PCI ID 10DE:2203 = GeForce RTX 3090 Ti" }
  elseif($dv){ V 'WARN' "PCI device ID 10DE:$dv is not the usual RTX 3090 ID (10DE:2204) - check the GPU name below" }
  CheckState $s
  if($s.SmiOK){ $script:smi=$s.Smi }
  elseif($s.Bound){ [void](DriverArrived 'at start') }   # driver bound but nvidia-smi not answering yet: wait, never install over it
  else { InstallDriver }
  if(-not $script:smi){ throw 'no working nvidia-smi' }
  $list=@(& $smi --query-gpu=index,name --format=csv,noheader 2>$null)
  $pick=@($list | ? { $_ -match '3090' }); if($pick.Count){ $script:GI=($pick[0] -split ',')[0].Trim() }
  if($list.Count -gt 1){ "  $($list.Count) NVIDIA GPUs: monitoring nvidia-smi GPU $GI. memtest_vulkan and llama.cpp choose their own Vulkan device - check the tested size below." }
  & $smi -i $GI --query-gpu=name,vbios_version,driver_version,memory.total,pcie.link.gen.max,pcie.link.width.max,power.limit,temperature.gpu,fan.speed --format=csv
  $g=(& $smi -i $GI --query-gpu=name,memory.total --format=csv,noheader,nounits) -split ','
  if($LASTEXITCODE -ne 0){ throw "nvidia-smi exit $LASTEXITCODE" }
  if($g[0] -match '3090'){ V 'PASS' $g[0].Trim() } else { V 'FAIL' "GPU is '$($g[0])', not a 3090" }
  $vr=Num $g[1]; if($vr -ge 24000){ V 'PASS' "$vr MiB VRAM" } else { V 'FAIL' "VRAM $vr MiB" }
}

$mtv=$null
Step 'Download VRAM tester (memtest_vulkan)' {
  if(-not $smi){ throw 'SKIP: no working NVIDIA driver' }
  $e=Join-Path $W 'memtest_vulkan.exe'
  if((Test-Path $e) -and (Magic $e 2) -ne 'MZ'){ Remove-Item $e -Force }
  if(-not (Test-Path $e)){
    $u='https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0.exe'
    try { $r=Invoke-RestMethod 'https://api.github.com/repos/GpuZelenograd/memtest_vulkan/releases/latest' -Headers @{'User-Agent'='pccheck'}; $a=$r.assets|?{ $_.name -match '^memtest_vulkan-v[\d\.]+\.exe$' }|Select -First 1; if($a){ $u=$a.browser_download_url } } catch {}
    Dl $u $e
    if((Magic $e 2) -ne 'MZ'){ Remove-Item $e -Force; throw 'downloaded memtest_vulkan is not a Windows program' }
  }
  $script:mtv=$e; V 'PASS' 'VRAM tester ready'
}

$bench=$null; $model=$null
Step 'Download GPU stress tool (llama.cpp Vulkan) and small test model' {
  if(-not $smi){ throw 'SKIP: no working NVIDIA driver' }
  $L=Join-Path $W 'llamavk'
  $script:bench=Get-ChildItem $L -Recurse -Filter llama-bench.exe -ErrorAction SilentlyContinue | Select -First 1
  if($script:bench -and -not (Test-Path (Join-Path $script:bench.DirectoryName 'ggml-vulkan*.dll'))){ $script:bench=$null }
  if(-not $script:bench){
    $rels=Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30' -Headers @{'User-Agent'='pccheck'}
    $bin=$null; foreach($r in $rels){ $bin=$r.assets | ? { $_.name -match '^llama-.*-bin-win-vulkan-x64\.zip$' } | Select -First 1; if($bin){ break } }
    if(-not $bin){ throw 'No llama.cpp release with a Windows Vulkan build found' }
    New-Item -ItemType Directory -Force $L | Out-Null
    $z=Join-Path $W $bin.name; "  $($bin.name) ($([int]($bin.size/1MB)) MB)"
    Dl $bin.browser_download_url $z
    try { Expand-Archive $z -DestinationPath $L -Force } catch { Remove-Item $z -Force -ErrorAction SilentlyContinue; throw "could not unpack $($bin.name): $($_.Exception.Message)" }
    $script:bench=Get-ChildItem $L -Recurse -Filter llama-bench.exe | Select -First 1
    if(-not $script:bench){ throw 'llama-bench.exe not in archive' }
  }
  if($env:QUICK -eq '1'){ $u='https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q8_0.gguf' }
  else { $u='https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf' }
  $m=Join-Path $W (Split-Path $u -Leaf)
  if(-not (Test-Path $m)){
    "  model $(Split-Path $u -Leaf) (0.5-1 GB)..."; $t=Get-Date
    Dl $u $m -Bar
    if((Magic $m 4) -ne 'GGUF'){ Remove-Item $m -Force; throw 'downloaded model is not a GGUF file' }
    "  took $([int]((Get-Date)-$t).TotalSeconds) s"
  }
  $script:model=$m; V 'PASS' 'Benchmark tools ready'
}

$LastBenchErr=''
function RunBench($argList,$timeoutSec){
  $out=Join-Path $W ('bench-'+[guid]::NewGuid().ToString('N')+'.txt')
  $p=Start-Process $bench.FullName -ArgumentList $argList -RedirectStandardOutput $out -RedirectStandardError "$out.err" -PassThru -NoNewWindow
  $null=$p.Handle
  if(-not $p.WaitForExit($timeoutSec*1000)){ try{ $p.Kill() }catch{}; throw "llama-bench timed out after $timeoutSec s" }
  $txt=Get-Content $out -Raw -ErrorAction SilentlyContinue
  $script:LastBenchErr=Get-Content "$out.err" -Raw -ErrorAction SilentlyContinue
  if($p.ExitCode -ne 0){ throw "llama-bench exit $($p.ExitCode): $((Get-Content "$out.err" -Tail 5) -join ' | ')" }
  $txt
}

$csv=Join-Path $W 'gpu-log.csv'; $mon=$null; $TestStart=$null; $cols=@()
Remove-Item $csv -ErrorAction SilentlyContinue  # a stale log from an earlier run must not be summarised if the test is skipped
Step 'GPU test: full VRAM (~5 min) then compute load (~3 min)' {
  if(-not $mtv -and (-not $bench -or -not $model)){ throw 'SKIP: test tools unavailable (GPU info above still valid)' }
  $fields='timestamp','temperature.gpu','utilization.gpu','power.draw','clocks.sm','clocks.mem','fan.speed','memory.used','pcie.link.gen.current','pcie.link.width.current'
  $tr=$null; foreach($pre in 'clocks_event_reasons','clocks_throttle_reasons'){ & $smi -i $GI --query-gpu="$pre.active" --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $tr=$pre; break } }
  $ok=@(); foreach($f in $fields){ & $smi -i $GI --query-gpu=$f --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $ok+=$f } }
  if($tr){ foreach($s in 'hw_slowdown','sw_thermal_slowdown','hw_thermal_slowdown','hw_power_brake_slowdown'){ & $smi -i $GI --query-gpu="$tr.$s" --format=csv,noheader 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $ok+="$tr.$s" } } }
  $script:cols=$ok; Remove-Item $csv -ErrorAction SilentlyContinue
  $script:TestStart=Get-Date
  $script:mon=Start-Process $smi -ArgumentList '-i',$GI,"--query-gpu=$($ok -join ',')",'--format=csv,noheader,nounits','-l','2' -RedirectStandardOutput $csv -PassThru -WindowStyle Hidden
  try {
    if($mtv){
      "  VRAM test: memtest_vulkan writes and checks nearly all 24 GB repeatedly (standard 5-minute run)..."
      $script:MemRes='INCOMPLETE'
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
      # memtest lists Vulkan devices by PCI DevId; if some are listed but none is a 3090, the 3090 was not the one tested
      $other=($mt -match 'DevId=0x[0-9A-Fa-f]{4}') -and ($mt -notmatch 'DevId=0x220[34]|RTX 3090')
      ($mt -split "`n" | ? { $_ -match 'written:|Error found|Errors address|Standard 5-minute' } | Select -Last 4) | % { "    $($_.Trim())" }
      if($mt -match 'ERRORS FOUND|Error found'){ $script:MemRes='FAIL'; V 'FAIL' 'VRAM errors found by memtest_vulkan (faulty memory or overheating VRAM)' }
      elseif($mt -match 'Standard 5-minute test PASSed'){
        if($other){ $script:MemRes='PARTIAL'; V 'WARN' 'memtest_vulkan passed, but on a different GPU - the 3090 VRAM was NOT tested' }
        elseif($gb -and $gb -lt 20){ $script:MemRes='PARTIAL'; V 'WARN' "VRAM test passed but covered only $gb GB" }
        else { $script:MemRes='PASS'; if($gb){ V 'PASS' "VRAM test passed ($gb GB written and verified, no errors)" } else { V 'PASS' 'VRAM test passed (no errors)' } } }
      else { [void]$Failures.Add("VRAM test: did not complete. Output tail: $((($mt -split "`n") | Select -Last 5) -join ' | ')"); V 'WARN' 'VRAM test did not complete (see output above) - NOT a pass' }
    }
    if(-not $bench -or -not $model){ throw 'SKIP: compute load skipped, llama.cpp tools unavailable' }
    $script:LoadRes='INCOMPLETE'
    "  Warm-up benchmark:"; $wt=RunBench @('-m',"`"$model`"",'-ngl','99','-p','512','-n','128','-r','3') 300; $wt | Write-Host
    if("$wt $LastBenchErr" -notmatch 'Vulkan'){ throw 'llama-bench did not report the Vulkan backend (it probably ran on the CPU, not the GPU)' }
    $end=(Get-Date).AddMinutes(2)
    while((Get-Date) -lt $end){
      [void](RunBench @('-m',"`"$model`"",'-ngl','99','-p','4096','-n','0','-ub','2048','-r','30') 240)
      $last=Get-Content $csv -Tail 1 -ErrorAction SilentlyContinue
      if($last){ $v=$last -split ','; $h=@{}; for($i=0;$i -lt $ok.Count -and $i -lt $v.Count;$i++){ $h[$ok[$i]]=$v[$i].Trim() }
        "  temp $($h['temperature.gpu'])C  util $($h['utilization.gpu'])%  power $($h['power.draw'])W  sm $($h['clocks.sm'])MHz  mem $($h['clocks.mem'])MHz  fan $($h['fan.speed'])%" }
    }
    "  Hot benchmark:"; RunBench @('-m',"`"$model`"",'-ngl','99','-p','512','-n','128','-r','3') 300 | Write-Host
    $script:LoadRes='DONE'
  } finally { if($script:mon){ try{ Stop-Process $script:mon -Force }catch{} }; Start-Sleep 1 }
}

Step 'GPU load summary' {
  if(-not (Test-Path $csv)){ throw 'SKIP: no GPU monitor log (load test did not run)' }
  $rows=@(Get-Content $csv | ? { $_ -match '\d' } | % { $v=$_ -split ','; $h=@{}; for($i=0;$i -lt $cols.Count -and $i -lt $v.Count;$i++){ $h[$cols[$i]]=$v[$i].Trim() }; $h })
  $busy=@($rows | ? { (Num $_['utilization.gpu']) -ge 80 })
  "  Samples: $($rows.Count), under load: $($busy.Count)"
  if($busy.Count -lt 20){ V 'FAIL' "GPU barely loaded ($($busy.Count) busy samples) - test inconclusive"; return }
  $temps=@($rows|%{ Num $_['temperature.gpu'] }|?{ $_ -ne $null }); $pw=@($rows|%{ Num $_['power.draw'] }|?{ $_ -ne $null })
  $mt=($temps|Measure-Object -Maximum).Maximum; $mp=($pw|Measure-Object -Maximum).Maximum
  $sm=($busy|%{ Num $_['clocks.sm'] }|?{ $_ -ne $null }|Measure-Object -Average).Average
  "  Max core temp: $mt C   Max power: $mp W   Avg SM clock under load: $([int]$sm) MHz"
  if($null -eq $mt){ V 'WARN' 'No temperature data' } elseif($mt -ge 87){ V 'FAIL' "Hot: $mt C core (repaste/pads likely)" } elseif($mt -ge 83){ V 'WARN' "Warm: $mt C core (normal-ish for OEM blower)" } else { V 'PASS' "Core temp OK ($mt C)" }
  if($null -ne $mp -and $mp -lt 250){ V 'WARN' "Peak power only $mp W - may be power-limited" }
  # No GDDR6X temp in nvidia-smi; an overheating GDDR6X shows up as the memory clock dropping under load
  $mc=@($busy|%{ Num $_['clocks.mem'] }|?{ $_ -ne $null })
  if($mc.Count){ $mx=($mc|Measure-Object -Maximum).Maximum; $low=@($mc|?{ $_ -lt 0.85*$mx }).Count
    if($low -ge 3){ V 'WARN' "Memory clock fell below 85% of $mx MHz in $low loaded samples (possible hot GDDR6X throttling)" } else { V 'PASS' "Memory clock steady under load ($mx MHz)" } }
  $w=$busy|%{ Num $_['pcie.link.width.current'] }|?{ $_ -ne $null }|Select -First 1
  $gn=$busy|%{ $_['pcie.link.gen.current'] }|Select -First 1
  if($null -eq $w){ V 'WARN' 'PCIe width unknown' } elseif($w -lt 16){ V 'FAIL' "PCIe link x$w (should be x16)" } else { V 'PASS' "PCIe gen $gn x$w" }
  $thr=@($cols|?{ $_ -match 'slowdown' })
  if(-not $thr.Count){ V 'WARN' 'Throttle reasons not supported by this driver' }
  foreach($c in $thr){ $hits=@($rows|?{ $_[$c] -eq 'Active' }).Count; if($hits){ $lvl=if($c -match 'hw_'){'FAIL'}else{'WARN'}; V $lvl "$c active in $hits samples" } }
  if($thr.Count -and -not ($thr|?{ $c=$_; @($rows|?{ $_[$c] -eq 'Active' }).Count })){ V 'PASS' 'No throttling or power-brake events' }
  $nv2=Events @{LogName='System';ProviderName='nvlddmkm';Level=1,2,3;StartTime=$TestStart}
  if($null -eq $nv2){ V 'WARN' 'Could not read NVIDIA log after test' } elseif($nv2.Count){ V 'FAIL' "NVIDIA driver errors during test: $($nv2.Count)" } else { V 'PASS' 'No driver errors during test' }
  $td2=Events @{LogName='System';ProviderName='Display';Id=4101;StartTime=$TestStart}
  if($td2){ $td2=@($td2|?{ "$($_.Message)" -match 'nvlddmkm' }); if($td2.Count){ V 'FAIL' "NVIDIA driver timed out and recovered during test (TDR) $($td2.Count)x" } }
  $script:SummaryDone=$true
}

Hdr 'VERDICT'
foreach($l in 'FAIL','WARN','PASS'){ $Verdicts | ? { $_.L -eq $l } | % { Write-Host "  [$l] $($_.M)" -ForegroundColor (@{PASS='Green';WARN='Yellow';FAIL='Red'}[$l]) } }
"  Note: GPU-only check (RAM, disks and CPU not tested). Full VRAM write/verify (memtest_vulkan) plus sustained compute load; core temp does not show GDDR6X memory temperature (memory-clock drops are flagged instead)."
if($Failures.Count){ "`n  Checks that crashed:"; $Failures | % { "   - $_" } }
# Overall: PASS only if nothing failed AND the VRAM test passed AND the compute load and its summary both finished
$nF=@($Verdicts|?{ $_.L -eq 'FAIL' }).Count; $nW=@($Verdicts|?{ $_.L -eq 'WARN' }).Count
if($NeedReboot){ $o='NOT TESTED YET - restart Windows, then paste the same line again'; $oc='Yellow' }
elseif($nF){ $o='FAIL'; $oc='Red' }
elseif($Halt -or $MemRes -ne 'PASS' -or $LoadRes -ne 'DONE' -or -not $SummaryDone){ $o='INCOMPLETE - NOT a pass (a GPU test did not run or did not finish)'; $oc='Yellow' }
elseif($nW){ $o='PASS WITH WARNINGS - read the warnings above'; $oc='Yellow' }
else { $o='PASS'; $oc='Green' }
Write-Host "`n  OVERALL: $o" -ForegroundColor $oc
Write-Host "  (VRAM test: $MemRes; compute load: $LoadRes)"
try { Stop-Transcript | Out-Null } catch {}
Write-Host "`nReport: $Log" -ForegroundColor Cyan

if($Failures.Count -and -not $NeedReboot){
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
      $src=if($SelfUrl){ "$W\z.ps1 (source: $SelfUrl)" }else{ "from $($SelfUrls -join ' or ') (a local copy could not be saved)" }
      $prompt="I'm testing the RTX 3090 in a used PC before buying it (GPU-only check). The check script $src ran and some checks crashed; failures are in $fl and the full report is $Log. Diagnose why those checks failed, fix the test code (not drivers, BIOS or hardware settings), and re-run only the failed checks. Never restart Windows yourself and never report a check as passed unless it actually ran to completion. Summarize the hardware results plainly at the end."
      Push-Location $W; & $claude $prompt; Pop-Location
      Write-Host "`nWhen done: type /logout inside Claude before quitting (or delete $env:USERPROFILE\.claude and $env:USERPROFILE\.claude.json) so your login isn't left on this PC." -ForegroundColor Yellow
    }
  }
}
if($NeedReboot){ Write-Host "Downloads are kept in '$W' so the run after the restart is faster." -ForegroundColor Cyan }
else { Write-Host "Cleanup when finished: Remove-Item -Recurse -Force '$W'" -ForegroundColor Cyan }
