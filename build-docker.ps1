# build-docker.ps1
[CmdletBinding()]
param(
  [string]$Tag = "latest",
  [string]$Dockerfile = "../Dockerfile",
  [string]$Context = "../.",
  [string]$EnvFile = ".env"
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

    # remove aspas simples/duplas nas bordas, se houver
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    [Environment]::SetEnvironmentVariable($key, $value, "Process")
  }
}

Import-DotEnvFile -Path $EnvFile

# Precedência de configuração:
# 1) parâmetro explicitamente passado
# 2) variável de ambiente (carregada do .env ou já existente)
# 3) default do próprio script
if (-not $PSBoundParameters.ContainsKey('ImageName')) {
  if (-not [string]::IsNullOrWhiteSpace($env:IMAGE_NAME)) {
    $ImageName = $env:IMAGE_NAME
  }
}

if (-not $PSBoundParameters.ContainsKey('Tag')) {
  if (-not [string]::IsNullOrWhiteSpace($env:IMAGE_TAG)) {
    $Tag = $env:IMAGE_TAG
  } elseif (-not [string]::IsNullOrWhiteSpace($env:TAG)) {
    # alias opcional
    $Tag = $env:TAG
  }
}

if ([string]::IsNullOrWhiteSpace($ImageName)) {
  throw "ImageName vazio. Defina -ImageName ou IMAGE_NAME no ambiente/.env."
}

# Evita ambiguidade do tipo IMAGE_NAME=repo:tag + -Tag
if ($ImageName -match ":") {
  throw "IMAGE_NAME/-ImageName não deve conter ':' (tag). Use apenas o repositório (ex: gnre-debitos/ms) e defina a tag em -Tag ou IMAGE_TAG."
}

$gitUser = $env:GIT_USERNAME
$gitPass = $env:GIT_PASSWORD

if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitPass)) {
  throw "Variáveis ausentes. Defina GIT_USERNAME e GIT_PASSWORD no ambiente ou no arquivo .env."
}

$fullTag = "${ImageName}:${Tag}"

docker build `
  -f $Dockerfile `
  --build-arg GIT_USERNAME=$gitUser `
  --build-arg GIT_PASSWORD=$gitPass `
  -t $fullTag `
  $Context