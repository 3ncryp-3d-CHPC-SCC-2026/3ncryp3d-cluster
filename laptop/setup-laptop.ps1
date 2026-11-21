<#
.SYNOPSIS
  3ncryp+3d laptop setup for Windows: keys, SSH config, VPN config.

.DESCRIPTION
  Step 1, once per laptop (before the stick is built):
      .\setup-laptop.ps1 -Init -User ole
    Makes your SSH key (asks for a passphrase) and your WireGuard key, and
    puts the two PUBLIC files in a folder on your Desktop. Send that folder
    to the captain. Your private keys never leave this laptop.

  Step 2, after the captain has built the keys (keys\cluster-public.env):
      .\setup-laptop.ps1 -Configure -User ole
    Writes your SSH config (head, c1, c2), the cluster's identity keys and
    your WireGuard tunnel file.

  On the day, once you know the head node's venue address:
      .\setup-laptop.ps1 -Configure -User ole -HeadAddress 192.168.30.57

  Check you can get in:
      .\setup-laptop.ps1 -Check

  Nothing here needs admin rights, except turning on the Windows key store
  (ssh-agent) once and installing the VPN tunnel as a service (optional).
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
  [Parameter(ParameterSetName = 'Init', Mandatory = $true)][switch]$Init,
  [Parameter(ParameterSetName = 'Configure', Mandatory = $true)][switch]$Configure,
  [Parameter(ParameterSetName = 'Check', Mandatory = $true)][switch]$Check,
  [Parameter(ParameterSetName = 'Init', Mandatory = $true)]
  [Parameter(ParameterSetName = 'Configure', Mandatory = $true)]
  [ValidatePattern('^[a-z_][a-z0-9_-]*$')][string]$User,
  [Parameter(ParameterSetName = 'Configure')][string]$PublicEnv,
  [Parameter(ParameterSetName = 'Configure')][string]$HeadAddress
)

$ErrorActionPreference = 'Stop'
$SshDir   = Join-Path $HOME '.ssh'
$Key      = Join-Path $SshDir 'id_ed25519_3ncryp3d'
$KnownHosts = Join-Path $SshDir 'known_hosts_3ncryp3d'
$SshConfig  = Join-Path $SshDir 'config'
$StateDir = Join-Path $HOME '.3ncryp3d'
$WgKey    = Join-Path $StateDir 'wg.key'
$WgPub    = Join-Path $StateDir 'wg.pub'
$WgConf   = Join-Path $StateDir '3ncryp3d.conf'
$HeadFile = Join-Path $StateDir 'head-address.txt'
$WgExe    = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
$WgApp    = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# UTF-8 WITHOUT a byte-order mark: OpenSSH chokes on a BOM in its config.
function Write-NoBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

# Only this Windows user may read a private file.
function Lock-File($path) {
  & icacls $path /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
}

function Test-Admin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Require-OpenSSH {
  if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Fail "OpenSSH client not found. Settings > Apps > Optional features > Add 'OpenSSH Client', then re-run."
  }
}

# Turn on the Windows key store so the passphrase is typed once per login.
function Enable-Agent {
  $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
  if (-not $svc) { Warn "ssh-agent service not found; you will type the passphrase on every connection."; return }
  if ($svc.StartType -ne 'Automatic' -or $svc.Status -ne 'Running') {
    if (Test-Admin) {
      Set-Service ssh-agent -StartupType Automatic
      Start-Service ssh-agent
      Say "Windows key store (ssh-agent) turned on."
    } else {
      Warn "To type your passphrase only once per login, run this ONCE in an ADMIN PowerShell:"
      Write-Host "    Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent"
      Write-Host "  then:  ssh-add `"$Key`""
      return
    }
  }
  & ssh-add $Key
}

# Read keys\cluster-public.env: KEY="value" lines; values may span lines.
function Read-PublicEnv($path) {
  if (-not (Test-Path $path)) { Fail "$path not found. Get keys\cluster-public.env from the repo or the captain." }
  $vals = @{}
  $lines = Get-Content -LiteralPath $path
  $i = 0
  while ($i -lt $lines.Count) {
    $line = $lines[$i]
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)="(.*)$') {
      $name = $Matches[1]; $rest = $Matches[2]
      if ($rest.EndsWith('"')) {
        $vals[$name] = $rest.Substring(0, $rest.Length - 1)
      } else {
        $buf = @($rest)
        $i++
        while ($i -lt $lines.Count -and -not $lines[$i].EndsWith('"')) { $buf += $lines[$i]; $i++ }
        if ($i -lt $lines.Count) { $buf += $lines[$i].Substring(0, $lines[$i].Length - 1) }
        $vals[$name] = ($buf -join "`n")
      }
    }
    $i++
  }
  return $vals
}

# ----------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Help') { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }

if ($Init) {
  Require-OpenSSH
  New-Item -ItemType Directory -Force -Path $SshDir, $StateDir | Out-Null

  if (Test-Path $Key) {
    Say "SSH key already exists: $Key (kept)"
  } else {
    Say "Making your SSH key. Choose a passphrase you will remember (it protects the key if this laptop is lost)."
    & ssh-keygen -t ed25519 -C "$User@3ncryp3d" -f $Key
    if (-not (Test-Path $Key)) { Fail "ssh-keygen did not create $Key" }
  }

  if (Test-Path $WgExe) {
    if (-not (Test-Path $WgKey)) {
      $priv = (& $WgExe genkey).Trim()
      Write-NoBom $WgKey "$priv`n"
      Lock-File $WgKey
      Write-NoBom $WgPub ((($priv | & $WgExe pubkey)).Trim() + "`n")
    }
  } else {
    Warn "WireGuard is not installed. Install it from https://www.wireguard.com/install/ and run -Init again to make your VPN key."
  }

  $out = Join-Path ([Environment]::GetFolderPath('Desktop')) "3ncryp3d-keys-$User"
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  Copy-Item "$Key.pub" (Join-Path $out "$User.pub") -Force
  if (Test-Path $WgPub) { Copy-Item $WgPub (Join-Path $out "$User.wg.pub") -Force }

  Enable-Agent

  Write-Host ""
  Say "Send the folder $out to the captain. It holds PUBLIC keys only."
  Write-Host "  Read the last 6 characters of this fingerprint to the captain on a call:"
  & ssh-keygen -lf "$Key.pub"
  Write-Host "  NEVER send or copy: $Key   or   $WgKey"
  exit 0
}

if ($Configure) {
  Require-OpenSSH
  if (-not (Test-Path $Key)) { Fail "No SSH key yet. Run: .\setup-laptop.ps1 -Init -User $User" }
  if (-not $PublicEnv) { $PublicEnv = Join-Path $PSScriptRoot '..\keys\cluster-public.env' }
  $cp = Read-PublicEnv $PublicEnv
  $prefix = $cp['HOST_PREFIX']
  if (-not $prefix) { Fail "HOST_PREFIX missing in $PublicEnv" }

  New-Item -ItemType Directory -Force -Path $SshDir, $StateDir | Out-Null
  if ($HeadAddress) { Write-NoBom $HeadFile "$HeadAddress`n" }
  elseif (Test-Path $HeadFile) { $HeadAddress = (Get-Content $HeadFile -TotalCount 1).Trim() }
  else { $HeadAddress = "$prefix-head.local" }

  # my VPN address from TEAM_USERS ("user uid sudo vpn" per line)
  $myVpn = $null
  foreach ($l in ($cp['TEAM_USERS'] -split "`n")) {
    $f = $l.Trim() -split '\s+'
    if ($f.Count -ge 4 -and $f[0] -eq $User) { $myVpn = $f[3] }
  }
  if (-not $myVpn) { Fail "user '$User' is not in TEAM_USERS of $PublicEnv" }

  $useVpn = ($cp['WG_ENABLE'] -eq 'yes') -and (Test-Path $WgKey)
  if ($cp['WG_ENABLE'] -eq 'yes' -and -not $useVpn) {
    Warn "No VPN key on this laptop (install WireGuard, run -Init). Using the direct address for now."
  }
  $headVpnIp = ($cp['WG_HEAD_ADDR'] -split '/')[0]
  $headHost = if ($useVpn) { $headVpnIp } else { $HeadAddress }

  # 1. the cluster's identity keys: SSH refuses anything else that answers
  $kh = @()
  foreach ($a in @('head', 'c1', 'c2')) {
    $hk = $cp["HOSTKEY_$a"]
    if (-not $hk) { Fail "HOSTKEY_$a missing in $PublicEnv" }
    $kh += "$prefix-$a $hk"
  }
  Write-NoBom $KnownHosts (($kh -join "`n") + "`n")

  # 2. SSH config block (replaces an older 3ncryp3d block, keeps the rest)
  $block = @"
# BEGIN 3ncryp3d - written by setup-laptop.ps1
Host head $prefix
    HostName $headHost
    HostKeyAlias $prefix-head
Host head-direct
    HostName $HeadAddress
    HostKeyAlias $prefix-head
Host c1
    HostName c1
    HostKeyAlias $prefix-c1
    ProxyJump head
Host c2
    HostName c2
    HostKeyAlias $prefix-c2
    ProxyJump head
Host head $prefix head-direct c1 c2
    User $User
    IdentityFile ~/.ssh/id_ed25519_3ncryp3d
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/known_hosts_3ncryp3d
    StrictHostKeyChecking yes
    ForwardAgent no
    ServerAliveInterval 30
# END 3ncryp3d
"@
  $old = ''
  if (Test-Path $SshConfig) { $old = [IO.File]::ReadAllText($SshConfig) }
  $old = [regex]::Replace($old, '(?s)# BEGIN 3ncryp3d.*?# END 3ncryp3d\r?\n?', '')
  # our block goes first: in ssh_config the first value found wins
  Write-NoBom $SshConfig (($block -replace "`r", '') + "`n" + $old)
  Say "SSH config written: ssh head, ssh c1, ssh c2  (backup without VPN: ssh head-direct)"

  # 3. WireGuard tunnel: only the head's VPN address goes through it;
  #    your normal internet traffic is untouched.
  if ($useVpn) {
    $priv = (Get-Content $WgKey -TotalCount 1).Trim()
    $wg = @"
[Interface]
PrivateKey = $priv
Address = $myVpn/32

[Peer]
PublicKey = $($cp['WG_HEAD_PUBKEY'])
Endpoint = ${HeadAddress}:$($cp['WG_PORT'])
AllowedIPs = $headVpnIp/32
PersistentKeepalive = 25
"@
    Write-NoBom $WgConf (($wg -replace "`r", '') + "`n")
    Lock-File $WgConf
    Say "VPN tunnel file: $WgConf  (endpoint $HeadAddress)"
    if ((Test-Admin) -and (Test-Path $WgApp)) {
      & $WgApp /uninstalltunnelservice 3ncryp3d 2>$null | Out-Null
      & $WgApp /installtunnelservice $WgConf
      Say "VPN tunnel '3ncryp3d' installed and started."
    } else {
      Write-Host "  Open WireGuard > Import tunnel(s) from file > $WgConf > Activate"
    }
  }
  Write-Host ""
  Say "Head node address in use: $HeadAddress"
  Write-Host "  On the day, if '$prefix-head.local' does not work, run again with -HeadAddress <IP shown on the head's screen>."
  exit 0
}

if ($Check) {
  Require-OpenSSH
  foreach ($h in @('head', 'c1', 'c2')) {
    $r = & ssh -o BatchMode=yes -o ConnectTimeout=8 $h hostname 2>&1
    if ($LASTEXITCODE -eq 0) { Say "$h OK ($r)" } else { Warn "$h FAILED: $r" }
  }
  $s = & ssh -o BatchMode=yes -o ConnectTimeout=8 head 'cat /mnt/shared/status/summary.txt 2>/dev/null' 2>$null
  if ($s) { Write-Host $s }
  exit 0
}
