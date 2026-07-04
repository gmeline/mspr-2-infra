# COFRAP - Script de demarrage (Windows PowerShell)
# Usage : .\start.ps1

# --- Verification des prerequis ---
Write-Host ""
Write-Host "  Verification des prerequis..." -ForegroundColor Cyan

# winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  winget non disponible. Installe App Installer depuis le Microsoft Store." -ForegroundColor Red
    exit 1
}

# kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "  Installation de kubectl..." -ForegroundColor Yellow
    winget install -e --id Kubernetes.kubectl --silent --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Write-Host "  kubectl : OK" -ForegroundColor Green

# Minikube
if (-not (Get-Command minikube -ErrorAction SilentlyContinue)) {
    Write-Host "  Installation de Minikube..." -ForegroundColor Yellow
    winget install -e --id Kubernetes.minikube --silent --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Write-Host "  Minikube : OK" -ForegroundColor Green

# Helm
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Host "  Installation de Helm..." -ForegroundColor Yellow
    winget install -e --id Helm.Helm --silent --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Write-Host "  Helm : OK" -ForegroundColor Green

# faas-cli
if (-not (Get-Command faas-cli -ErrorAction SilentlyContinue)) {
    Write-Host "  Installation de faas-cli..." -ForegroundColor Yellow
    winget install -e --id OpenFaaS.faas-cli --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    if (-not (Get-Command faas-cli -ErrorAction SilentlyContinue)) {
        # Fallback : installation manuelle
        $faasUrl = "https://github.com/openfaas/faas-cli/releases/latest/download/faas-cli.exe"
        $faasPath = "$env:ProgramFiles\faas-cli\faas-cli.exe"
        New-Item -ItemType Directory -Force -Path "$env:ProgramFiles\faas-cli" | Out-Null
        Invoke-WebRequest -Uri $faasUrl -OutFile $faasPath
        [System.Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";$env:ProgramFiles\faas-cli", "Machine")
        $env:PATH = $env:PATH + ";$env:ProgramFiles\faas-cli"
    }
}
Write-Host "  faas-cli : OK" -ForegroundColor Green

# Docker Desktop
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  Docker Desktop n'est pas installe." -ForegroundColor Red
    Write-Host "  Telecharge et installe Docker Desktop (AMD64) depuis : https://www.docker.com/products/docker-desktop/" -ForegroundColor Red
    Write-Host "  Puis relance ce script." -ForegroundColor Red
    exit 1
}
Write-Host "  Docker Desktop : OK" -ForegroundColor Green

# Chargement du fichier .env
$EnvFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Host "  Fichier .env introuvable. Copie .env.example en .env et remplis les chemins." -ForegroundColor Red
    return
}

Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#]\S+=.+' } | ForEach-Object {
    $parts = $_ -split '=', 2
    Set-Variable -Name $parts[0].Trim() -Value $parts[1].Trim() -Scope Script
}

if ([string]::IsNullOrWhiteSpace($BACKEND_PATH) -or [string]::IsNullOrWhiteSpace($INFRA_PATH)) {
    Write-Host "  BACKEND_PATH et INFRA_PATH doivent etre definis dans le .env" -ForegroundColor Red
    return
}

$Releases = "$INFRA_PATH\releases"

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  COFRAP - Demarrage de la plateforme" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# 1. Docker
Write-Host ""
Write-Host "[1/9] Verification de Docker..." -ForegroundColor Yellow
$dockerStatus = & docker ps 2>&1 | Out-String
if ($dockerStatus -match "error" -or $dockerStatus -match "cannot") {
    Write-Host "  Docker non demarre, tentative de lancement..." -ForegroundColor Yellow
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
    $dockerReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $status = & docker ps 2>&1 | Out-String
        if ($status -notmatch "error" -and $status -notmatch "cannot") {
            $dockerReady = $true
            break
        }
    }
    if (-not $dockerReady) {
        Write-Host "  Docker n'a pas demarre a temps. Relance le script une fois Docker pret." -ForegroundColor Red
        return
    }
}
Write-Host "  Docker : OK" -ForegroundColor Green

# 2. Minikube
Write-Host ""
Write-Host "[2/9] Verification de Minikube..." -ForegroundColor Yellow
$minikubeStatus = & minikube status 2>&1 | Out-String
if ($minikubeStatus -notmatch "host: Running") {
    Write-Host "  Demarrage de Minikube..." -ForegroundColor Yellow
    & minikube start --cpus=2 --memory=4096
} elseif ($minikubeStatus -notmatch "apiserver: Running") {
    Write-Host "  Apiserver arrete, redemarrage de Minikube..." -ForegroundColor Yellow
    & minikube stop 2>&1 | Out-Null
    & minikube start --cpus=2 --memory=4096
}
& minikube update-context 2>&1 | Out-Null
Write-Host "  Minikube : OK" -ForegroundColor Green

# 3. Cluster Kubernetes
Write-Host ""
Write-Host "[3/9] Verification du cluster Kubernetes..." -ForegroundColor Yellow
$clusterReady = $false
for ($i = 0; $i -lt 36; $i++) {
    $result = & kubectl get nodes --no-headers 2>&1 | Out-String
    if ($result -match "Ready") {
        $clusterReady = $true
        break
    }
    Write-Host "  Cluster pas encore pret, nouvelle tentative ($($i+1)/36)..." -ForegroundColor Yellow
    if ($i -eq 17) {
        Write-Host "  Redemarrage de Minikube..." -ForegroundColor Yellow
        & minikube stop 2>&1 | Out-Null
        & minikube start --cpus=2 --memory=4096 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 5
}
if (-not $clusterReady) {
    Write-Host "  Cluster non disponible apres 3 minutes. Verifie minikube status." -ForegroundColor Red
    return
}
Write-Host "  Cluster : OK" -ForegroundColor Green

# 4. Helm repos
Write-Host ""
Write-Host "[4/9] Mise a jour des repos Helm..." -ForegroundColor Yellow
helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>&1 | Out-Null
helm repo add bitnami https://charts.bitnami.com/bitnami 2>&1 | Out-Null
helm repo update
Write-Host "  Repos Helm : OK" -ForegroundColor Green

# 5. OpenFaaS
Write-Host ""
Write-Host "[5/9] Verification d'OpenFaaS..." -ForegroundColor Yellow
$helmList = & helm list -n $NAMESPACE_OF 2>&1 | Out-String
if ($helmList -notmatch "openfaas") {
    Write-Host "  OpenFaaS absent, nettoyage des residus eventuels..." -ForegroundColor Yellow

    $allReleases = & helm list -A 2>&1 | Out-String
    if ($allReleases -match "openfaas") {
        helm uninstall openfaas -n openfaas 2>$null | Out-Null
        helm uninstall openfaas -n openfaas-2 2>$null | Out-Null
    }

    $crds = & kubectl get crd 2>&1 | Out-String
    if ($crds -match "openfaas") {
        Write-Host "  Suppression des CRDs openfaas en conflit..." -ForegroundColor Yellow
        kubectl get crd | Select-String "openfaas" | ForEach-Object {
            $crd = ($_.ToString().Trim() -split '\s+')[0]
            kubectl delete crd $crd 2>$null | Out-Null
        }
    }

    kubectl delete namespace openfaas openfaas-fn openfaas-2 2>$null | Out-Null
    Start-Sleep -Seconds 5

    Write-Host "  Deploiement d'OpenFaaS..." -ForegroundColor Yellow
    kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
    helm upgrade openfaas --install openfaas/openfaas `
        --namespace $NAMESPACE_OF `
        -f "$Releases\openfaas\values.yaml"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Echec du deploiement OpenFaaS. Verifie les logs ci-dessus." -ForegroundColor Red
        return
    }
    Write-Host "  Attente qu'OpenFaaS soit pret..." -ForegroundColor Yellow
    kubectl rollout status deployment/gateway -n $NAMESPACE_OF --timeout=180s
    Write-Host "  OpenFaaS deploye : OK" -ForegroundColor Green
} else {
    Write-Host "  OpenFaaS : deja deploye" -ForegroundColor Green
}

# 6. PostgreSQL
Write-Host ""
Write-Host "[6/9] Verification de PostgreSQL..." -ForegroundColor Yellow
$pgHelm = & helm list -n $NAMESPACE_DB 2>&1 | Out-String
if ($pgHelm -notmatch "postgres") {
    Write-Host "  PostgreSQL absent, deploiement..." -ForegroundColor Yellow
    & kubectl create namespace $NAMESPACE_DB 2>&1 | Out-Null
    $SqlContent = Get-Content "$BACKEND_PATH\..\sql\init.sql" -Raw
    $TmpValues = "$env:TEMP\postgres-values-tmp.yaml"
    Get-Content "$Releases\postgres\values.yaml" | Out-File $TmpValues -Encoding utf8
    Add-Content $TmpValues "`nprimary:`n  initdb:`n    scripts:`n      init.sql: |"
    $SqlContent -split "`n" | ForEach-Object { Add-Content $TmpValues "        $_" }
    helm upgrade postgres --install bitnami/postgresql `
        --namespace $NAMESPACE_DB `
        -f $TmpValues `
        --set auth.password="$DB_PASSWORD"
    Write-Host "  Attente que PostgreSQL soit pret..." -ForegroundColor Yellow
    kubectl rollout status statefulset/postgres -n $NAMESPACE_DB --timeout=120s
    Write-Host "  PostgreSQL deploye : OK" -ForegroundColor Green
} else {
    Write-Host "  PostgreSQL : deja en place" -ForegroundColor Green
}

# 7. Secrets
Write-Host ""
Write-Host "[7/9] Verification des secrets..." -ForegroundColor Yellow

$fernetExists = & kubectl get secret fernet-key -n $NAMESPACE_FN 2>&1 | Out-String
if ($fernetExists -match "not found" -or $fernetExists -match "No resources") {
    Write-Host "  Creation du secret fernet-key..." -ForegroundColor Yellow
    $FERNET_KEY = docker run --rm python:3.11-alpine sh -c "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'"
    & kubectl create secret generic fernet-key --from-literal=fernet-key="$FERNET_KEY" --namespace $NAMESPACE_FN
    Write-Host "  fernet-key cree : OK" -ForegroundColor Green
} else {
    Write-Host "  fernet-key : deja present" -ForegroundColor Green
}

$dbHostExists = & kubectl get secret db-host -n $NAMESPACE_FN 2>&1 | Out-String
if ($dbHostExists -match "not found" -or $dbHostExists -match "No resources") {
    Write-Host "  Creation des secrets DB..." -ForegroundColor Yellow
    & kubectl create secret generic db-host --from-literal=db-host="$DB_HOST" --namespace $NAMESPACE_FN
    & kubectl create secret generic db-name --from-literal=db-name="$DB_NAME" --namespace $NAMESPACE_FN
    & kubectl create secret generic db-user --from-literal=db-user="$DB_USER" --namespace $NAMESPACE_FN
    & kubectl create secret generic db-password --from-literal=db-password="$DB_PASSWORD" --namespace $NAMESPACE_FN
    Write-Host "  Secrets DB crees : OK" -ForegroundColor Green
} else {
    Write-Host "  Secrets DB : deja presents" -ForegroundColor Green
}

$smtpExists = & kubectl get secret smtp-host -n $NAMESPACE_FN 2>&1 | Out-String
if ($smtpExists -match "not found" -or $smtpExists -match "No resources") {
    Write-Host "  Creation des secrets SMTP..." -ForegroundColor Yellow
    & kubectl create secret generic smtp-host     --from-literal=smtp-host="$SMTP_HOST"         --namespace $NAMESPACE_FN
    & kubectl create secret generic smtp-port     --from-literal=smtp-port="$SMTP_PORT"         --namespace $NAMESPACE_FN
    & kubectl create secret generic smtp-user     --from-literal=smtp-user="$SMTP_USER"         --namespace $NAMESPACE_FN
    & kubectl create secret generic smtp-password --from-literal=smtp-password="$SMTP_PASSWORD" --namespace $NAMESPACE_FN
    & kubectl create secret generic smtp-from     --from-literal=smtp-from="$SMTP_FROM"         --namespace $NAMESPACE_FN
    Write-Host "  Secrets SMTP crees : OK" -ForegroundColor Green
} else {
    Write-Host "  Secrets SMTP : deja presents" -ForegroundColor Green
}

# 7b. MailHog (serveur SMTP local)
Write-Host ""
Write-Host "  MailHog..." -ForegroundColor Yellow
$mhPod = & kubectl get pods -n mailhog --no-headers 2>&1 | Out-String
if ($mhPod -match "No resources found" -or $mhPod -match "not found" -or [string]::IsNullOrWhiteSpace($mhPod.Trim())) {
    & kubectl apply -f "$Releases\mailhog\mailhog.yaml" 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    Write-Host "  MailHog deploye : OK" -ForegroundColor Green
} else {
    Write-Host "  MailHog : deja en place" -ForegroundColor Green
}
$mhExisting = Get-NetTCPConnection -LocalPort 8025 -ErrorAction SilentlyContinue
if ($mhExisting) {
    Stop-Process -Id $mhExisting.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
Start-Process -NoNewWindow -FilePath "kubectl" -ArgumentList "port-forward -n mailhog svc/mailhog 8025:8025"
Write-Host "  Boite mail disponible sur http://localhost:8025" -ForegroundColor Green

# 8. Images Docker
Write-Host ""
Write-Host "[8/9] Verification des images Docker..." -ForegroundColor Yellow
$images = @(
    "dockerazariel/generate-password:latest",
    "dockerazariel/generate-2fa:latest",
    "dockerazariel/authenticate:latest",
    "dockerazariel/create-account:latest"
)
foreach ($image in $images) {
    $localImage = & docker images $image --format "{{.Repository}}:{{.Tag}}" 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($localImage.Trim())) {
        Write-Host "  Pull de $image..." -ForegroundColor Yellow
        docker pull $image
    }
    Write-Host "  Chargement de $image dans minikube..." -ForegroundColor Yellow
    minikube image load $image
}
Write-Host "  Images : OK" -ForegroundColor Green

# 9. Port-forward + faas-cli
Write-Host ""
Write-Host "[9/9] Port-forward gateway + login faas-cli..." -ForegroundColor Yellow

$existing = Get-NetTCPConnection -LocalPort 8888 -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Process -Id $existing.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
Start-Process -NoNewWindow -FilePath "kubectl" -ArgumentList "port-forward -n $NAMESPACE_OF svc/gateway 8888:8080"
Start-Sleep -Seconds 5
Write-Host "  Gateway accessible sur $GATEWAY_URL" -ForegroundColor Green

$PASSWORD_B64 = $null
for ($i = 0; $i -lt 15; $i++) {
    $PASSWORD_B64 = & kubectl get secret -n $NAMESPACE_OF basic-auth -o jsonpath="{.data.basic-auth-password}" 2>&1
    if (-not [string]::IsNullOrWhiteSpace($PASSWORD_B64) -and $PASSWORD_B64 -notmatch "Error") { break }
    Write-Host "  Attente du secret basic-auth ($($i+1)/15)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 4
}
if ([string]::IsNullOrWhiteSpace($PASSWORD_B64) -or $PASSWORD_B64 -match "Error") {
    Write-Host "  Secret basic-auth introuvable - OpenFaaS pas encore pret. Relance le script." -ForegroundColor Red
    return
}
$PASSWORD = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PASSWORD_B64.Trim()))
Write-Output $PASSWORD | faas-cli login --username admin --password-stdin --gateway $GATEWAY_URL

$functions = & faas-cli list --gateway $GATEWAY_URL 2>&1 | Out-String
if ($functions -notmatch "generate-password") {
    Write-Host "  Fonctions absentes, deploiement..." -ForegroundColor Yellow
    Push-Location $BACKEND_PATH
    faas-cli template store pull python3-http
    faas-cli deploy -f stack.yaml --gateway $GATEWAY_URL
    Pop-Location
    Write-Host "  Fonctions deployees : OK" -ForegroundColor Green
} else {
    Write-Host "  Fonctions : deja deployees" -ForegroundColor Green
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   COFRAP : plateforme prete !" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Interface OpenFaaS : $GATEWAY_URL/ui" -ForegroundColor White
Write-Host "  Utilisateur        : admin" -ForegroundColor White
Write-Host "  Mot de passe       : $PASSWORD" -ForegroundColor White
Write-Host ""
faas-cli list --gateway $GATEWAY_URL
