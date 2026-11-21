<#
.SYNOPSIS
  Push the 3ncryp+3d BIOS settings (config\bios-profile.conf) to the servers
  through iLO (Redfish), check them, and record them.

.DESCRIPTION
  Sunday night, after the iLO passwords are changed:

    .\bios-profile.ps1 -Discover            what each server offers (saved to results\bios\)
    .\bios-profile.ps1 -Plan -Pass 1        what pass 1 would change (changes nothing)
    .\bios-profile.ps1 -Apply -Pass 1 -Reboot
    .\bios-profile.ps1 -Apply -Pass 2 -Reboot   (after the servers are back up)
    .\bios-profile.ps1 -Verify -Pass 2      every setting in place? (exit 1 if not)

  Every name and value is checked against the server's own BIOS attribute
  registry first. Anything that server doesn't offer is SKIPPED with a
  warning, never sent. Before/after values are saved under results\bios\ so
  the settings are reproducible.

  iLO addresses come from tools\ilo.env (same file as tools/power-monitor.sh).
  You are asked for the iLO user and password once; nothing is stored.
  -Reboot restarts the server at once: only use it before Ubuntu is in use
  (or when nothing is running).
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
  [Parameter(ParameterSetName = 'Discover', Mandatory = $true)][switch]$Discover,
  [Parameter(ParameterSetName = 'Plan', Mandatory = $true)][switch]$Plan,
  [Parameter(ParameterSetName = 'Apply', Mandatory = $true)][switch]$Apply,
  [Parameter(ParameterSetName = 'Verify', Mandatory = $true)][switch]$Verify,
  [Parameter(ParameterSetName = 'Plan')]
  [Parameter(ParameterSetName = 'Apply', Mandatory = $true)]
  [Parameter(ParameterSetName = 'Verify')]
  [ValidateSet('1', '2')][string]$Pass = '2',
  [Parameter(ParameterSetName = 'Apply')][switch]$Reboot,
  [string[]]$Nodes,
  [string]$IloEnv = (Join-Path $PSScriptRoot '..\tools\ilo.env'),
  [string]$ProfileFile = (Join-Path $PSScriptRoot '..\config\bios-profile.conf'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\results\bios'),
  [System.Management.Automation.PSCredential]$Credential,
  [ValidateSet('https', 'http')][string]$Scheme = 'https'   # http only for the offline test
)

$ErrorActionPreference = 'Stop'
function Say($m)  { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "WARN: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if ($PSCmdlet.ParameterSetName -eq 'Help') { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }

# iLO uses a self-signed certificate. Windows PowerShell 5.1 needs this to accept it.
$Ps7 = $PSVersionTable.PSVersion.Major -ge 6
if (-not $Ps7) {
  if (-not ('TrustAllCerts' -as [type])) {
    Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
  }
  [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# inputs
# ---------------------------------------------------------------------------
function Read-IloEnv($path) {
  if (-not (Test-Path $path)) { Fail "$path not found. Copy tools\ilo.env.example to tools\ilo.env and fill in the iLO IPs." }
  $map = [ordered]@{}
  foreach ($l in Get-Content -LiteralPath $path) {
    if ($l -match '^\s*\[(\w+)\]\s*=\s*"([^"]+)"') { $map[$Matches[1]] = $Matches[2] }
  }
  if ($map.Count -eq 0) { Fail "no [nodeN]=""ip"" lines found in $path" }
  return $map
}

function Read-Profile($path, $pass) {
  if (-not (Test-Path $path)) { Fail "$path not found" }
  $want = [ordered]@{}; $section = ''
  foreach ($l in Get-Content -LiteralPath $path) {
    $line = ($l -replace '#.*$', '').Trim()
    if (-not $line) { continue }
    if ($line -match '^\[(\w+)\]$') { $section = $Matches[1]; continue }
    if ($section -ne "pass$pass") { continue }
    if ($line -match '^([A-Za-z0-9_]+)\s*=\s*(.+)$') { $want[$Matches[1]] = $Matches[2].Trim() }
    else { Warn "bios-profile.conf: can't read line '$l'" }
  }
  if ($want.Count -eq 0) { Fail "no settings in [pass$pass] of $path" }
  return $want
}

# ---------------------------------------------------------------------------
# Redfish
# ---------------------------------------------------------------------------
$script:Auth = $null
function Invoke-Ilo($ip, $method, $path, $body) {
  $req = @{
    Uri = "${Scheme}://$ip$path"; Method = $method
    Headers = @{ Authorization = $script:Auth; 'OData-Version' = '4.0' }
    ContentType = 'application/json'; TimeoutSec = 60
  }
  if ($null -ne $body) { $req.Body = ($body | ConvertTo-Json -Depth 10 -Compress) }
  if ($Ps7) { $req.SkipCertificateCheck = $true }
  try { return Invoke-RestMethod @req }
  catch {
    $detail = $_.ErrorDetails.Message
    if (-not $detail) { $detail = $_.Exception.Message }
    throw "iLO $ip $method $path failed: $detail"
  }
}

function Get-Registry($ip, $name) {
  $cache = Join-Path $OutDir "registry-$name.json"
  if (Test-Path $cache) { return (Get-Content $cache -Raw | ConvertFrom-Json) }
  $reg = $null
  try { $reg = Invoke-Ilo $ip GET "/redfish/v1/Registries/$name/" $null } catch { $reg = $null }
  if (-not $reg) {
    $all = Invoke-Ilo $ip GET '/redfish/v1/Registries/' $null
    $m = $all.Members | Where-Object { $_.'@odata.id' -match [regex]::Escape($name) } | Select-Object -First 1
    if (-not $m) { throw "BIOS registry $name not found on $ip" }
    $reg = Invoke-Ilo $ip GET $m.'@odata.id' $null
  }
  $loc = $reg.Location | Where-Object { $_.Language -eq 'en' } | Select-Object -First 1
  if (-not $loc) { $loc = $reg.Location | Select-Object -First 1 }
  $full = Invoke-Ilo $ip GET $loc.Uri $null
  $attrs = $full.RegistryEntries.Attributes
  $attrs | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cache -Encoding UTF8
  return $attrs
}

function Get-Bios($ip) {
  $bios = Invoke-Ilo $ip GET '/redfish/v1/Systems/1/Bios/' $null
  $settings = '/redfish/v1/Systems/1/Bios/Settings/'
  if ($bios.'@Redfish.Settings' -and $bios.'@Redfish.Settings'.SettingsObject) {
    $settings = $bios.'@Redfish.Settings'.SettingsObject.'@odata.id'
  }
  $pending = $null
  try { $pending = (Invoke-Ilo $ip GET $settings $null).Attributes } catch { $pending = $null }
  return @{ Current = $bios.Attributes; Registry = $bios.AttributeRegistry; SettingsUri = $settings; Pending = $pending }
}

# check one wanted setting against the registry -> typed value, or a reason to skip
function Test-Setting($registry, $name, $value) {
  $a = $registry | Where-Object { $_.AttributeName -eq $name } | Select-Object -First 1
  if (-not $a) { return @{ Ok = $false; Why = "not offered by this server" } }
  if ($a.ReadOnly) { return @{ Ok = $false; Why = "read-only on this server" } }
  switch ($a.Type) {
    'Enumeration' {
      $allowed = @($a.Value | ForEach-Object { $_.ValueName })
      if ($allowed -ccontains $value) { return @{ Ok = $true; Value = $value } }
      return @{ Ok = $false; Why = "value '$value' not allowed (allowed: $($allowed -join ', '))" }
    }
    'Integer' {
      $n = 0
      if (-not [int]::TryParse($value, [ref]$n)) { return @{ Ok = $false; Why = "'$value' is not a number" } }
      if (($null -ne $a.LowerBound -and $n -lt $a.LowerBound) -or ($null -ne $a.UpperBound -and $n -gt $a.UpperBound)) {
        return @{ Ok = $false; Why = "$n outside $($a.LowerBound)..$($a.UpperBound)" }
      }
      return @{ Ok = $true; Value = $n }
    }
    'Boolean' { return @{ Ok = $true; Value = ($value -match '^(true|yes|1|enabled)$') } }
    default { return @{ Ok = $true; Value = $value } }
  }
}

function Save-Json($obj, $name) {
  $f = Join-Path $OutDir $name
  $obj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f -Encoding UTF8
  return $f
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ilos = Read-IloEnv $IloEnv
if ($Nodes) {
  foreach ($n in $Nodes) { if (-not $ilos.Contains($n)) { Fail "$n is not in $IloEnv" } }
  $targets = $Nodes
} else { $targets = @($ilos.Keys) }

if (-not $Credential) { $Credential = Get-Credential -Message 'iLO user and password (the same on all servers)' }
$pair = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
$script:Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))

$want = $null
if (-not $Discover) { $want = Read-Profile $ProfileFile $Pass }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bad = 0

foreach ($node in $targets) {
  $ip = $ilos[$node]
  Write-Host ""
  Say "$node (iLO $ip)"
  try { $b = Get-Bios $ip } catch { Warn "$_"; $bad++; continue }
  $reg = Get-Registry $ip $b.Registry

  if ($Discover) {
    $rows = foreach ($a in $reg) {
      [pscustomobject]@{
        Name = $a.AttributeName; Type = $a.Type; ReadOnly = [bool]$a.ReadOnly
        Current = $b.Current.($a.AttributeName)
        Allowed = if ($a.Type -eq 'Integer') { "$($a.LowerBound)..$($a.UpperBound)" } else { (@($a.Value | ForEach-Object { $_.ValueName }) -join ' | ') }
      }
    }
    $csv = Join-Path $OutDir "$node-attributes-$stamp.csv"
    $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $f = Save-Json $b.Current "$node-current-$stamp.json"
    Write-Host "  registry $($b.Registry): $(@($reg).Count) settings -> $csv"
    Write-Host "  current values -> $f"
    $names = @()
    foreach ($p in '1', '2') { $names += @((Read-Profile $ProfileFile $p).Keys) }
    foreach ($n in ($names | Select-Object -Unique)) {
      $r = $rows | Where-Object { $_.Name -eq $n } | Select-Object -First 1
      if ($r) { Write-Host ("  {0,-30} now {1,-28} allowed: {2}" -f $n, $r.Current, $r.Allowed) }
      else { Warn "  $n is not offered by this server (it will be skipped)" }
    }
    continue
  }

  # Plan / Apply / Verify share the same check
  $changes = [ordered]@{}
  Write-Host ("  {0,-30} {1,-28} {2,-28} {3}" -f 'SETTING', 'NOW', 'WANTED', 'ACTION')
  foreach ($name in $want.Keys) {
    $t = Test-Setting $reg $name $want[$name]
    $now = $b.Current.$name
    if (-not $t.Ok) {
      Write-Host ("  {0,-30} {1,-28} {2,-28} SKIP: {3}" -f $name, $now, $want[$name], $t.Why) -ForegroundColor Yellow
      continue
    }
    $pend = $null
    if ($b.Pending) { $pend = $b.Pending.$name }
    if ("$now" -ceq "$($t.Value)") { $act = 'ok' }
    else {
      $act = 'change'
      if ($null -ne $pend -and "$pend" -ceq "$($t.Value)") { $act = 'change (already pending, needs reboot)' }
      $changes[$name] = $t.Value
    }
    Write-Host ("  {0,-30} {1,-28} {2,-28} {3}" -f $name, $now, $t.Value, $act)
  }

  if ($Plan) { Write-Host "  $($changes.Count) change(s) in pass $Pass. Nothing was sent."; continue }

  if ($Verify) {
    $f = Save-Json $b.Current "$node-verify-pass$Pass-$stamp.json"
    if ($changes.Count -eq 0) { Say "${node} pass ${Pass}: every setting in place ($f)" }
    else { Warn "${node} pass ${Pass}: $($changes.Count) setting(s) not in place yet (a reboot pending?)"; $bad++ }
    continue
  }

  # Apply
  if ($changes.Count -eq 0) { Say "${node}: nothing to change in pass $Pass"; continue }
  $before = Save-Json $b.Current "$node-before-pass$Pass-$stamp.json"
  $sent = Save-Json $changes "$node-sent-pass$Pass-$stamp.json"
  try {
    Invoke-Ilo $ip PATCH $b.SettingsUri @{ Attributes = $changes } | Out-Null
  } catch { Warn "$_"; $bad++; continue }
  Say "${node}: $($changes.Count) setting(s) sent. The BIOS applies them at the next boot."
  Write-Host "  before: $before"
  Write-Host "  sent:   $sent"
  if ($Reboot) {
    $sys = Invoke-Ilo $ip GET '/redfish/v1/Systems/1/' $null
    $type = 'ForceRestart'
    if ($sys.PowerState -eq 'Off') { $type = 'On' }
    Invoke-Ilo $ip POST '/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/' @{ ResetType = $type } | Out-Null
    Say "${node}: $type sent. Wait for it to come back (about 5 minutes), then -Verify -Pass $Pass."
  } else {
    Write-Host "  Restart the server for them to take effect (or re-run with -Reboot)."
  }
}

if ($bad -gt 0) { exit 1 }
exit 0
