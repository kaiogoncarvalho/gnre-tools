param(
    [string]$EnvFilePath = ".env",
    [string]$VenvPath = "../.venv"
)

Write-Host "Ativando venv em '$VenvPath'..."

$venvActivate = Join-Path $VenvPath "Scripts\Activate.ps1"
if (!(Test-Path $venvActivate)) {
    Write-Error "Venv nao encontrado em '$venvActivate'. Ajuste o caminho do venv no script."
    exit 1
}

# Ativa o venv
. $venvActivate

Write-Host "Carregando variaveis do arquivo '$EnvFilePath'..."

if (!(Test-Path $EnvFilePath)) {
    Write-Error "Arquivo .env nao encontrado em '$EnvFilePath'. Crie o arquivo ou ajuste o caminho."
    exit 1
}

Get-Content $EnvFilePath | ForEach-Object {
    if ($_ -match '^\s*#') { return }   # ignora comentarios
    if ($_ -match '^\s*$') { return }   # ignora linhas em branco
    $name, $value = $_ -split '=', 2
    if ($name -and $value) {
        $trimmedName = $name.Trim()
        $trimmedValue = $value.Trim()

        # remove aspas simples/duplas nas bordas, se houver
        if (($trimmedValue.StartsWith('"') -and $trimmedValue.EndsWith('"')) -or ($trimmedValue.StartsWith("'") -and $trimmedValue.EndsWith("'"))) {
            $trimmedValue = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
        }

        Write-Host "Exportando $trimmedName"
        # Define variavel de ambiente no escopo do processo do PowerShell
        [System.Environment]::SetEnvironmentVariable($trimmedName, $trimmedValue, 'Process')
    }
}

# Se o usuario nao passou -RequirementsPath, tenta pegar do ambiente/.env
if (-not $PSBoundParameters.ContainsKey('RequirementsPath')) {
    if (-not [string]::IsNullOrWhiteSpace($env:REQUIREMENTS_PATH)) {
        $RequirementsPath = $env:REQUIREMENTS_PATH
    }
}

# Normaliza caminho relativo ao diretorio do script (pra rodar de qualquer cwd)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($RequirementsPath)) {
    $RequirementsPath = Join-Path $scriptRoot $RequirementsPath
}

if (-not (Test-Path -Path $RequirementsPath)) {
    Write-Error "Requirements nao encontrado em '$RequirementsPath'. Defina REQUIREMENTS_PATH no .env ou passe -RequirementsPath."
    exit 1
}

Write-Host "Instalando dependencias de '$RequirementsPath'..."
pip install --force-reinstall --no-cache-dir -r $RequirementsPath

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao instalar dependencias."
    exit $LASTEXITCODE
}

Write-Host "Instalacao concluida com sucesso."