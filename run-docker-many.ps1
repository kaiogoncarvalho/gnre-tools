# run-docker-many.ps1
# Executa o run-docker.ps1 N vezes, com opções para nome/portas e opcionalmente em paralelo.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateRange(1, 10000)]
  [int]$Count,

  # Caminho do script base
  [string]$ScriptPath = ".\\run-docker.ps1",

  # Parâmetros comuns repassados
  [string]$ImageName,
  [string]$Tag,
  [string]$EnvFile = ".env",
  [string[]]$Ports = @(),
  [string[]]$Volumes = @(),
  [string[]]$ExtraArgs = @(),
  [switch]$Detached,
  [switch]$Keep,
  [switch]$NoEnvFile,
  [switch]$Interactive,
  [string]$Workdir = "",
  [string[]]$Command = @(),

  # Debug (repassa)
  [switch]$EnableDebugPy,
  [int]$DebugPyPort = 5678,
  [int]$HostDebugPort = 0,
  [switch]$DebugPyWait,
  [switch]$AutoDebugPort,

  [switch]$EnablePyCharmDebug,
  [int]$PyCharmDebugPort = 5678,
  [string]$PyCharmDebugHost = "host.docker.internal",
  [switch]$PyCharmSuspend,

  # Opções do "many"
  [string]$NamePrefix = "",
  [int]$StartIndex = 1,

  # Se informado, adiciona UM mapeamento de porta por container: (BaseHostPort + offset) : ContainerPort
  [int]$BaseHostPort = 0,
  [int]$ContainerPort = 0,

  # Paralelismo (PowerShell 5.1): usa Start-Job com limite de concorrência.
  [switch]$Parallel,
  [ValidateRange(1, 256)]
  [int]$MaxParallel = 5,

  # Pequeno delay entre starts (ms)
  [ValidateRange(0, 600000)]
  [int]$DelayMs = 0,

  [switch]$KillAfterEach,
  [ValidateRange(1, 86400)]
  [int]$KillTimeoutSec = 30,

  [switch]$DryRun,
  [switch]$ShowContainerLogs,
  [switch]$WaitEach,

  # Em vez de criar log do many, habilita log no run-docker.ps1 para cada execução.
  [switch]$LogToFile,
  [string]$LogDir = "",
  [string]$LogFilePrefix = ""
)

$ErrorActionPreference = "Stop"

function Import-DotEnvFile {
  param([string]$Path)

  if (-not (Test-Path -Path $Path)) { return }

  Get-Content -Path $Path | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line.StartsWith("#")) { return }

    $parts = $line -split "=", 2
    if ($parts.Count -ne 2) { return }

    $key = $parts[0].Trim()
    $value = $parts[1].Trim()

    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    [Environment]::SetEnvironmentVariable($key, $value, "Process")
  }
}

function Get-EnvBool {
  param(
    [string]$Name,
    [bool]$Default = $false
  )

  $raw = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

  switch ($raw.Trim().ToLowerInvariant()) {
    { $_ -in @("1","true","yes","y","on") } { return $true }
    { $_ -in @("0","false","no","n","off") } { return $false }
    default { return $Default }
  }
}

function Get-EnvInt {
  param(
    [string]$Name,
    [int]$Default = 0
  )

  $raw = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

  $i = 0
  if ([int]::TryParse($raw.Trim(), [ref]$i)) { return $i }
  return $Default
}

# Carrega .env (se existir e se permitido)
if (-not $NoEnvFile) {
  Import-DotEnvFile -Path $EnvFile
}

# Defaults via .env (parâmetro CLI sempre vence)
# Variáveis suportadas:
#   MANY_COUNT=30
#   MANY_NAME_PREFIX=ms-gnre-debitos-
if (-not $PSBoundParameters.ContainsKey('Count')) {
  $Count = Get-EnvInt -Name "MANY_COUNT" -Default 0
}
if ($Count -le 0) {
  throw "Count é obrigatório. Passe -Count ou defina MANY_COUNT no .env."
}

if (-not $PSBoundParameters.ContainsKey('NamePrefix')) {
  $envPrefix = $env:MANY_NAME_PREFIX
  if (-not [string]::IsNullOrWhiteSpace($envPrefix)) {
    $NamePrefix = $envPrefix
  }
}

# OBS: Não lemos mais MANY_DETACHED / MANY_LOG_TO_FILE pelo .env.
# Isso deve ser controlado explicitamente via parâmetros (-Detached / -LogToFile).

function Wait-WhileTooManyJobs {
  param(
    [System.Collections.ArrayList]$Jobs,
    [int]$MaxParallel
  )

  while ($true) {
    # Limpa jobs já finalizados
    for ($i = $Jobs.Count - 1; $i -ge 0; $i--) {
      if ($Jobs[$i].State -in @('Completed','Failed','Stopped')) {
        $null = Receive-Job -Job $Jobs[$i] -ErrorAction SilentlyContinue
        Remove-Job -Job $Jobs[$i] -Force -ErrorAction SilentlyContinue
        $Jobs.RemoveAt($i)
      }
    }

    if ($Jobs.Count -lt $MaxParallel) { break }
    Start-Sleep -Milliseconds 200
  }
}

function Stop-And-RemoveContainer {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [int]$TimeoutSec = 30
  )

  if ([string]::IsNullOrWhiteSpace($Name)) { return }

  try { docker stop -t $TimeoutSec $Name *>$null } catch {}
  try { docker rm -f $Name *>$null } catch {}
}

$resolvedScriptPath = (Resolve-Path -Path $ScriptPath).ProviderPath
$scriptDir = Split-Path -Parent $resolvedScriptPath

# Monta os parâmetros base para repassar para o run-docker.ps1 (via splatting)
$baseParams = @{
  EnvFile = $EnvFile
}

# Só repassa ImageName/Tag se vierem informados. Caso contrário, o run-docker.ps1 resolve via .env.
if (-not [string]::IsNullOrWhiteSpace($ImageName)) { $baseParams.ImageName = $ImageName }
if (-not [string]::IsNullOrWhiteSpace($Tag)) { $baseParams.Tag = $Tag }

if ($Ports.Count -gt 0)     { $baseParams.Ports = $Ports }
if ($Volumes.Count -gt 0)   { $baseParams.Volumes = $Volumes }
if ($ExtraArgs.Count -gt 0) { $baseParams.ExtraArgs = $ExtraArgs }

if ($Detached)    { $baseParams.Detached = $true }
if ($Keep)        { $baseParams.Keep = $true }
if ($NoEnvFile)   { $baseParams.NoEnvFile = $true }
if ($Interactive) { $baseParams.Interactive = $true }
if (-not [string]::IsNullOrWhiteSpace($Workdir)) { $baseParams.Workdir = $Workdir }

# Compat: repassa -Command (array) para o run-docker.ps1 se usado.
if ($Command.Count -gt 0) { $baseParams.Command = $Command }

if ($EnableDebugPy) {
  $baseParams.EnableDebugPy = $true
  $baseParams.DebugPyPort = $DebugPyPort
  if ($HostDebugPort -gt 0) { $baseParams.HostDebugPort = $HostDebugPort }
  if ($DebugPyWait) { $baseParams.DebugPyWait = $true }
  if ($AutoDebugPort) { $baseParams.AutoDebugPort = $true }
}

if ($EnablePyCharmDebug) {
  $baseParams.EnablePyCharmDebug = $true
  $baseParams.PyCharmDebugPort = $PyCharmDebugPort
  $baseParams.PyCharmDebugHost = $PyCharmDebugHost
  if ($PyCharmSuspend) { $baseParams.PyCharmSuspend = $true }
}

if ($DryRun) { $baseParams.DryRun = $true }

# Se for para mostrar logs/aguardar, repassa para o run-docker.ps1.
if ($ShowContainerLogs) {
  $baseParams.Attach = $true
  $baseParams.Quiet = $true
}
if ($WaitEach) {
  $baseParams.Wait = $true
}

# Se o usuário pediu log, repassa para o run-docker.ps1.
# Não força LogDir/LogFilePrefix, deixa o run-docker.ps1 usar defaults.
if ($LogToFile) {
  $baseParams.LogToFile = $true
  $baseParams.LogContainerText = $true
  if (-not [string]::IsNullOrWhiteSpace($LogDir)) {
    $baseParams.LogDir = $LogDir
  }
}

# Regras: se vamos usar Detached + (Attach/Wait/LogToFile), precisamos de nome.
if ($Detached -and (($ShowContainerLogs) -or ($WaitEach) -or ($LogToFile)) -and [string]::IsNullOrWhiteSpace($NamePrefix)) {
  throw "Para usar -Detached com logs/attach/wait, informe -NamePrefix (ou defina MANY_NAME_PREFIX no .env)."
}

try {
  Write-Host "Script: $resolvedScriptPath"
  Write-Host "Count: $Count" + $(if ($Parallel) { " (parallel, max=$MaxParallel)" } else { " (sequential)" })

  $jobs = New-Object System.Collections.ArrayList

  for ($n = 0; $n -lt $Count; $n++) {
    $idx = $StartIndex + $n

    # Parâmetros por execução
    $runParams = @{} + $baseParams

    # Nome único (opcional)
    $containerNameThisRun = ""
    if (-not [string]::IsNullOrWhiteSpace($NamePrefix)) {
      $containerNameThisRun = "${NamePrefix}${idx}"
      $runParams.ContainerName = $containerNameThisRun
    }

    # Permite personalizar prefixo dos logs apenas se o usuário informar.
    if ($LogToFile -and -not [string]::IsNullOrWhiteSpace($LogFilePrefix)) {
      $runParams.LogFilePrefix = $LogFilePrefix
      $runParams.ContainerJsonPrefix = $LogFilePrefix
    }

    # Porta única (opcional) - adiciona à lista Ports SEM mexer na lista original
    if ($BaseHostPort -gt 0 -and $ContainerPort -gt 0) {
      $hostPort = $BaseHostPort + $idx
      $runParams.Ports = @("${hostPort}:$ContainerPort") + $Ports
    }

    $logName = if ([string]::IsNullOrWhiteSpace($containerNameThisRun)) { "(no-name)" } else { $containerNameThisRun }
    Write-Host ("[{0}/{1}] {2}" -f ($n + 1), $Count, $logName)

    if ($Parallel) {
      if ($KillAfterEach) {
        throw "-KillAfterEach não é compatível com -Parallel. Rode sem -Parallel."
      }

      Wait-WhileTooManyJobs -Jobs $jobs -MaxParallel $MaxParallel

      $job = Start-Job -ScriptBlock {
        param($scriptDir, $scriptPath, $params)
        Set-Location $scriptDir
        & $scriptPath @params
      } -ArgumentList $scriptDir, $resolvedScriptPath, $runParams

      [void]$jobs.Add($job)

    } else {
      Push-Location $scriptDir
      try {
        & $resolvedScriptPath @runParams

        if ($KillAfterEach -and $Detached -and -not $DryRun) {
          if (-not $WaitEach) {
            Stop-And-RemoveContainer -Name $containerNameThisRun -TimeoutSec $KillTimeoutSec
          }
        }

      } finally {
        Pop-Location
      }
    }

    if ($DelayMs -gt 0) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }

  if ($Parallel) {
    while ($jobs.Count -gt 0) {
      Wait-WhileTooManyJobs -Jobs $jobs -MaxParallel 1
    }
  }

} finally {
  # nada para fechar (o run-docker.ps1 finaliza seus próprios logs)
}
