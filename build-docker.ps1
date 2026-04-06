# build-docker.ps1
[CmdletBinding()]
param(
  [string]$ComposeFile = "../docker-compose.yml",
  [string]$EnvFile = ".env",
  [switch]$NoCache,
  [switch]$Pull,
  # Se quiser buildar só um serviço específico, passe o nome. Vazio = todos.
  [string]$Service = ""
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

Import-DotEnvFile -Path $EnvFile

$gitUser = $env:GIT_USERNAME
$gitPass = $env:GIT_PASSWORD

if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitPass)) {
  throw "Variáveis ausentes. Defina GIT_USERNAME e GIT_PASSWORD no ambiente ou no arquivo .env."
}

if (-not (Test-Path $ComposeFile)) {
  throw "docker-compose.yml não encontrado em: $ComposeFile"
}

$buildArgs = @("compose", "-f", $ComposeFile, "build")

if ($NoCache) {
  $buildArgs += "--no-cache"
}

if ($Pull) {
  $buildArgs += "--pull"
}

$buildArgs += @("--build-arg", "GIT_USERNAME=$gitUser")
$buildArgs += @("--build-arg", "GIT_PASSWORD=$gitPass")

if (-not [string]::IsNullOrWhiteSpace($Service)) {
  $buildArgs += $Service
  Write-Host "Buildando serviço: $Service"
} else {
  Write-Host "Buildando todos os serviços..."
}

Write-Host ("docker " + ($buildArgs -join " "))
docker @buildArgs
