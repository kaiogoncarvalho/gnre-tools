# run-docker.ps1
[CmdletBinding()]
param(
  [string]$ImageName,
  [string]$Tag,
  [string]$ContainerName = "",           # vazio por padrão: Docker gera nome automaticamente
  [string]$EnvFile = ".env",
  [string[]]$Ports = @(),
  [string[]]$Volumes = @(),              # ex: @("${PWD}:/app")
  [string[]]$ExtraArgs = @(),
  [switch]$Detached,
  [switch]$Keep,                         # se usado, NAO aplica --rm
  [switch]$NoEnvFile,
  [switch]$Interactive,                  # adiciona -it
  [string]$Workdir = "",                 # ex: /app

  # Substitui Command array por uma string de comando (mais estável no PyCharm/PowerShell CLI).
  # Exemplos:
  #   -CommandLine "python main.py"
  #   -CommandLine "sh -c 'echo hello'"
  [string]$CommandLine = "",

  # Mantém compatibilidade: se ainda passar -Command (array), o PowerShell vai preencher este.
  # Preferir -CommandLine.
  [Obsolete("Use -CommandLine")]
  [string[]]$Command = @(),

  # Se habilitado, apenas imprime o comando docker e sai (NÃO executa).
  [switch]$DryRun,

  # --- Debug (opt-in) ---
  [switch]$EnableDebugPy,
  [int]$DebugPyPort = 5678,
  [int]$HostDebugPort = 0,
  [switch]$DebugPyWait,
  [switch]$AutoDebugPort,

  # --- Plano B: PyCharm Python Debug Server (pydevd) ---
  [switch]$EnablePyCharmDebug,
  [int]$PyCharmDebugPort = 5678,
  [string]$PyCharmDebugHost = "host.docker.internal",
  [switch]$PyCharmSuspend,

  # Captura logs no console:
  # -Attach: após subir em -Detached, segue os logs (docker logs -f)
  # -Wait: depois de seguir logs, aguarda finalizar e retorna o exit code
  [switch]$Attach,
  [switch]$Wait,

  # Se ligado, não imprime a linha 'docker ...' (útil quando você quer ver só os logs do app).
  [switch]$Quiet,

  # Grava toda a saída do script (incluindo logs do container) em arquivo.
  [switch]$LogToFile,

  # Pasta onde salvar o arquivo de log.
  # OBS: mantido por compatibilidade, mas agora por padrão usamos "log" na raiz do projeto.
  [string]$LogDir = "log",

  # Prefixo do nome do arquivo de log
  [string]$LogFilePrefix = "log",

  # Grava a saída do container em arquivo texto (RAW) em log/container.
  [switch]$LogContainerText,

  # Salva a saída do container em formato JSON (array) em log/container.
  # OBS: isso é mais pesado (converte e escreve JSON). Use só se for consumir depois.
  [switch]$LogContainerJson,

  # Nome/prefixo do arquivo JSON
  [string]$ContainerJsonPrefix = "log"
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

function Get-FreeTcpPort {
  # Pega uma porta livre no host abrindo um listener em porta 0 e lendo a porta atribuída
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = $listener.LocalEndpoint.Port
  $listener.Stop()
  return $port
}

if (-not $NoEnvFile) {
  Import-DotEnvFile -Path $EnvFile
}

# Resolve ImageName/Tag a partir do .env quando o usuário não passar explicitamente.
# Precedência: parâmetro CLI > ambiente/.env.
if (-not $PSBoundParameters.ContainsKey('ImageName')) {
  if (-not [string]::IsNullOrWhiteSpace($env:IMAGE_NAME)) {
    $ImageName = $env:IMAGE_NAME
  }
}
if (-not $PSBoundParameters.ContainsKey('Tag')) {
  if (-not [string]::IsNullOrWhiteSpace($env:IMAGE_TAG)) {
    $Tag = $env:IMAGE_TAG
  } elseif (-not [string]::IsNullOrWhiteSpace($env:TAG)) {
    $Tag = $env:TAG
  }
}

if ([string]::IsNullOrWhiteSpace($ImageName)) {
  throw "ImageName vazio. Defina IMAGE_NAME no .env (ou passe -ImageName)."
}
if ([string]::IsNullOrWhiteSpace($Tag)) {
  throw "Tag vazia. Defina IMAGE_TAG (ou TAG) no .env (ou passe -Tag)."
}

$fullTag = "${ImageName}:${Tag}"

$args = @("run")

if ($Interactive) { $args += @("-it") }
if ($Detached) { $args += "-d" }

# Quando vamos anexar logs/esperar em modo detached, NÃO podemos usar --rm,
# senão o container pode desaparecer antes do docker logs/wait.
$shouldAutoRemove = (-not $Keep)
if ($Detached -and ($Attach -or $Wait)) {
  $shouldAutoRemove = $false
}

if ($shouldAutoRemove) { $args += "--rm" }

if (-not [string]::IsNullOrWhiteSpace($Workdir)) {
  $args += @("--workdir", $Workdir)
}

# só define nome se o usuário passar um nome explicitamente
if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
  $args += @("--name", $ContainerName)
}

# --- Plano B (pydevd_pycharm): container conecta no PyCharm, então NÃO deve publicar a porta do host via docker -p.
if ($EnablePyCharmDebug) {
  $ExtraArgs += @("-e", "PYCHARM_DEBUG=1")
  $ExtraArgs += @("-e", "PYCHARM_DEBUG_HOST=$PyCharmDebugHost")
  $ExtraArgs += @("-e", "PYCHARM_DEBUG_PORT=$PyCharmDebugPort")

  if ($PyCharmSuspend) {
    $ExtraArgs += @("-e", "PYCHARM_DEBUG_SUSPEND=1")
  } else {
    $ExtraArgs += @("-e", "PYCHARM_DEBUG_SUSPEND=0")
  }
}

# --- DebugPy (opt-in) ---
$hostDebugPort = $null
if ($EnableDebugPy) {
  if ($EnablePyCharmDebug) {
    throw "Escolha apenas um modo de debug: -EnableDebugPy OU -EnablePyCharmDebug."
  }
  # Container sempre escuta em $DebugPyPort.
  # No host: se HostDebugPort vier definido, prioriza. Senão, se AutoDebugPort estiver ligado, pega uma porta livre.
  $hostDebugPort = $DebugPyPort

  if ($HostDebugPort -gt 0) {
    $hostDebugPort = $HostDebugPort
  } elseif ($AutoDebugPort) {
    $hostDebugPort = Get-FreeTcpPort
  }

  # Remove qualquer mapeamento prévio para a porta do container (evita duplicar -p)
  $Ports = $Ports | Where-Object { $_ -notmatch (":$DebugPyPort$") }

  # Publica a porta (host -> container)
  $debugPortMapping = "${hostDebugPort}:${DebugPyPort}"
  $Ports = @($debugPortMapping) + $Ports

  # Injeta as envs do debugpy (porta do CONTAINER)
  $ExtraArgs += @("-e", "DEBUGPY=1")
  $ExtraArgs += @("-e", "DEBUGPY_PORT=$DebugPyPort")
  if ($DebugPyWait) {
    $ExtraArgs += @("-e", "DEBUGPY_WAIT=1")
  }

  # Evita warning do pydevd no Python 3.12
  $ExtraArgs += @("-e", "PYDEVD_DISABLE_FILE_VALIDATION=1")
}

# Só adiciona -p para entradas não vazias
foreach ($p in $Ports) {
  if (-not [string]::IsNullOrWhiteSpace($p)) {
    $args += @("-p", $p)
  }
}

# Sempre monta o PWD em /app
# (você disse que aqui está certo retroceder uma pasta)
$args += @("-v", "${PWD}\..:/app")

foreach ($v in $Volumes) { $args += @("-v", $v) }

if ($ExtraArgs.Count -gt 0) { $args += $ExtraArgs }

$args += $fullTag

# Remover o antigo bloco de Command:
# if ($Command.Count -gt 0) { $args += $Command }

# Novo: anexa comando ao final do docker run.
if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
  # Passa via sh -c para manter comportamento consistente entre shells.
  $args += @("sh", "-c", $CommandLine)
} elseif ($Command.Count -gt 0) {
  # Fallback para chamadas antigas
  $args += $Command
}

if (-not $Quiet) {
  if ($EnablePyCharmDebug) {
    Write-Host ("PyCharm Debug Server: inicie a config 'Python Debug Server' no PyCharm em localhost:$PyCharmDebugPort e depois suba o container.")
  }
  if ($EnableDebugPy) {
    Write-Host ("Debugpy: anexe no PyCharm em localhost:$hostDebugPort (container porta $DebugPyPort)")
  }
  Write-Host ("docker " + ($args -join " "))
}

if ($DryRun) {
  return
}

# Sempre gravar logs (independente de passar parâmetros).
# - Por padrão grava log geral (transcript) e log do container em texto.
# - Se você quiser JSON, use -LogContainerJson.
if (-not $PSBoundParameters.ContainsKey('LogToFile')) { $LogToFile = $true }
if (-not $PSBoundParameters.ContainsKey('LogContainerText') -and -not $PSBoundParameters.ContainsKey('LogContainerJson')) {
  $LogContainerText = $true
}

# Inicia logging em arquivo ANTES de rodar docker/logs para capturar tudo.
$transcriptPath = $null
$jsonPath = $null
$jsonWriter = $null
$containerLogPath = $null
$containerLogWriter = $null

if ($LogToFile -or $LogContainerJson -or $LogContainerText) {
  # Logs sempre na pasta do script (tools\log\geral e tools\log\container)
  $logRoot = Join-Path -Path $PSScriptRoot -ChildPath "log"

  if (-not (Test-Path -Path $logRoot)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
  }

  $runLogDir = Join-Path -Path $logRoot -ChildPath "geral"
  $containerLogDir = Join-Path -Path $logRoot -ChildPath "container"

  if (-not (Test-Path -Path $runLogDir)) {
    New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null
  }
  if (-not (Test-Path -Path $containerLogDir)) {
    New-Item -ItemType Directory -Path $containerLogDir -Force | Out-Null
  }

  # Timestamp no padrão desejado (Windows-safe).
  # O usuário pediu: yyyy-MM-dd|HH_mm_ss, mas '|' é inválido em nomes de arquivo no Windows.
  # Então usamos '_' no lugar do '|', mantendo a mesma legibilidade e ordenação.
  $ts = Get-Date -Format "yyyy-MM-dd_HH_mm_ss"
  $tsMs = Get-Date -Format "fff"
  $ts = "${ts}.${tsMs}"

  if ($LogToFile) {
    $transcriptPath = Join-Path -Path $runLogDir -ChildPath ("{0}-{1}.log" -f $LogFilePrefix, $ts)
    Start-Transcript -Path $transcriptPath -Append | Out-Null
    if (-not $Quiet) { Write-Host ("Logging to: " + $transcriptPath) }
  }

  if ($LogContainerText -or $LogContainerJson) {
    $containerLogPath = Join-Path -Path $containerLogDir -ChildPath ("{0}-{1}.container.log" -f $ContainerJsonPrefix, $ts)
    $containerLogWriter = New-Object System.IO.StreamWriter($containerLogPath, $false, [System.Text.Encoding]::UTF8)
    if (-not $Quiet) {
      Write-Host ("Container log: " + $containerLogPath)
    }
  }

  if ($LogContainerJson) {
    $jsonPath = Join-Path -Path $containerLogDir -ChildPath ("{0}-{1}.json" -f $ContainerJsonPrefix, $ts)

    $jsonWriter = New-Object System.IO.StreamWriter($jsonPath, $false, [System.Text.Encoding]::UTF8)
    $jsonWriter.Write("[")
    $jsonWriter.Flush()

    if (-not $Quiet) {
      Write-Host ("Container JSON: " + $jsonPath)
    }
  }
}

# Força o encoding do console/pipeline para UTF-8 (evita 'Execu├º├úo' etc.)
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
  # ignore
}

# Se NÃO for detached, docker deve rodar em foreground e imprimir os logs.
# Aqui também capturamos a saída para os arquivos (container.log / json) quando habilitados.
if (-not $Detached) {
  try {
    if ($LogContainerJson -and $jsonWriter -and $containerLogWriter) {
      $first = $true
      $linesSinceFlush = 0
      $flushEvery = 100

      docker @args | ForEach-Object {
        $line = $_
        if ($null -ne $line) {
          $lineStr = [string]$line
          $containerLogWriter.WriteLine($lineStr)
          Write-Output $lineStr

          $entry = [ordered]@{
            timestamp = (Get-Date).ToString("o")
            raw       = $lineStr
          }
          $jsonLine = ([pscustomobject]$entry | ConvertTo-Json -Depth 10 -Compress)

          if (-not $first) { $jsonWriter.Write(",") }
          $first = $false
          $jsonWriter.Write($jsonLine)

          $linesSinceFlush++
          if ($linesSinceFlush -ge $flushEvery) {
            $linesSinceFlush = 0
            $containerLogWriter.Flush()
            $jsonWriter.Flush()
          }
        }
      }

      $containerLogWriter.Flush()
      $jsonWriter.Flush()

    } elseif ($containerLogWriter) {
      docker @args | ForEach-Object {
        $line = $_
        if ($null -ne $line) {
          $lineStr = [string]$line
          $containerLogWriter.WriteLine($lineStr)
          Write-Output $lineStr
        }
      }
      $containerLogWriter.Flush()

    } else {
      docker @args
    }
  } finally {
    if ($jsonWriter) {
      try {
        $jsonWriter.Write("]")
        $jsonWriter.Flush()
        $jsonWriter.Dispose()
      } catch {}
    }

    if ($containerLogWriter) {
      try { $containerLogWriter.Flush(); $containerLogWriter.Dispose() } catch {}
    }

    if ($transcriptPath) {
      try { Stop-Transcript | Out-Null } catch {}
    }
  }

  return
}

# --- A partir daqui, é SOMENTE fluxo detached ---

# Importante: para seguir logs precisamos de um nome de container.
if ([string]::IsNullOrWhiteSpace($ContainerName) -and ($Attach -or $Wait)) {
  throw "Para usar -Attach/-Wait com -Detached, informe -ContainerName (ou use o wrapper com -NamePrefix)."
}

# Remove parse: o log do container NÃO é JSON válido (é dict Python). Então não tentamos converter.
function Convert-ContainerLineToParsedObject {
  param([string]$Line)
  return $null
}

try {
  # Em detached, subimos o container (não mostramos output aqui)
  docker @args | Out-Null

  # Se vamos aguardar, precisamos evitar corrida: docker logs -f pode terminar antes/depois.
  $waitJob = $null
  if ($Wait) {
    $waitJob = Start-Job -ScriptBlock {
      param($name)
      docker wait $name
    } -ArgumentList $ContainerName
  }

  if ($Attach -or $Wait) {
    try {
      if ($LogContainerJson -and $jsonWriter -and $containerLogWriter) {
        $first = $true
        $linesSinceFlush = 0
        $flushEvery = 100

        $maxTries = 5
        for ($try = 1; $try -le $maxTries; $try++) {
          $hadAny = $false

          docker logs -f --since 0s $ContainerName | ForEach-Object {
            $hadAny = $true
            $line = $_

            $containerLogWriter.WriteLine($line)
            Write-Output $line

            $entry = [ordered]@{
              timestamp = (Get-Date).ToString("o")
              raw       = $line
            }

            $jsonLine = ([pscustomobject]$entry | ConvertTo-Json -Depth 10 -Compress)

            if (-not $first) { $jsonWriter.Write(",") }
            $first = $false
            $jsonWriter.Write($jsonLine)

            $linesSinceFlush++
            if ($linesSinceFlush -ge $flushEvery) {
              $linesSinceFlush = 0
              $containerLogWriter.Flush()
              $jsonWriter.Flush()
            }
          }

          if ($hadAny -or -not $Wait) { break }
          Start-Sleep -Milliseconds 200
        }

        $containerLogWriter.Flush()
        $jsonWriter.Flush()

      } elseif ($containerLogWriter) {
        docker logs -f --since 0s $ContainerName | ForEach-Object {
          $line = $_
          $containerLogWriter.WriteLine($line)
          Write-Output $line
        }
        $containerLogWriter.Flush()

      } else {
        docker logs -f $ContainerName
      }
    } catch {
      # ignore
    }
  }

  if ($Wait -and $waitJob) {
    $exitCodeStr = Receive-Job -Job (Wait-Job -Job $waitJob) -ErrorAction SilentlyContinue
    Remove-Job -Job $waitJob -Force -ErrorAction SilentlyContinue

    $exitCode = 0
    if ($exitCodeStr -and ($exitCodeStr -is [string])) {
      [int]::TryParse($exitCodeStr.Trim(), [ref]$exitCode) | Out-Null
    }

    exit [int]$exitCode
  }

} finally {
  if ($Detached -and $Wait -and -not $Keep -and -not [string]::IsNullOrWhiteSpace($ContainerName)) {
    try { docker rm -f $ContainerName | Out-Null } catch {}
  }

  if ($jsonWriter) {
    try {
      $jsonWriter.Write("]")
      $jsonWriter.Flush()
      $jsonWriter.Dispose()
    } catch {}
  }

  if ($containerLogWriter) {
    try { $containerLogWriter.Flush(); $containerLogWriter.Dispose() } catch {}
  }

  if ($transcriptPath) {
    try { Stop-Transcript | Out-Null } catch {}
  }
}
