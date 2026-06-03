# COFRAP - Script de demarrage (Windows PowerShell 5.1)
# Usage : .\start.ps1

$NAMESPACE_OF = "openfaas"
$NAMESPACE_FN = "openfaas-fn"
$NAMESPACE_DB = "data"
$BACKEND_PATH = "D:\EPSI\MSPR2\cofrap-poc\mspr-2-backend\functions"
$INFRA_PATH   = "D:\EPSI\MSPR2\cofrap-poc\mspr-2-infra"
$GATEWAY_URL  = "http://127.0.0.1:8888"
$DB_HOST      = "postgres.data.svc.cluster.local"
$DB_NAME      = "cofrap"
$DB_USER      = "cofrap_app"
$DB_PASSWORD  = "ChangeMe_S3cret!"

Write-Host ""
Write-Host "=== COFRAP : demarrage de la plateforme ===" -ForegroundColor Cyan

# 1. Verifier Docker
Write-Host ""
Write-Host "[1/8] Verification de Docker..." -ForegroundColor Yellow
$dockerStatus = & docker ps 2>&1 | Out-String
if ($dockerStatus -match "error" -or $dockerStatus -match "cannot") {
    Write-Host "  Docker n'est pas demarre. Lance Docker Desktop et relance ce script." -ForegroundColor Red
    return
}
Write-Host "  Docker : OK" -ForegroundColor Green

# 2. Fixer le kubeconfig
Write-Host ""
Write-Host "[2/8] Correction du kubeconfig..." -ForegroundColor Yellow
$kubeconfigPath = "$env:USERPROFILE\.kube\config"
if (Test-Path $kubeconfigPath) {
    (Get-Content $kubeconfigPath) -replace 'host\.docker\.internal', '127.0.0.1' | Set-Content $kubeconfigPath
    Write-Host "  kubeconfig : OK" -ForegroundColor Green
} else {
    New-Item -ItemType Directory -Path "$env:USERPROFILE\.kube" -Force | Out-Null
    k3d kubeconfig get cofrap | Out-File -FilePath $kubeconfigPath -Encoding utf8
    (Get-Content $kubeconfigPath) -replace 'host\.docker\.internal', '127.0.0.1' | Set-Content $kubeconfigPath
    Write-Host "  kubeconfig regenere : OK" -ForegroundColor Green
}

# 3. Verifier le cluster
Write-Host ""
Write-Host "[3/8] Verification du cluster Kubernetes..." -ForegroundColor Yellow
kubectl get nodes
Write-Host "  Cluster : OK" -ForegroundColor Green

# 4. Port-forward gateway
Write-Host ""
Write-Host "[4/8] Lancement du port-forward gateway..." -ForegroundColor Yellow
$existing = Get-NetTCPConnection -LocalPort 8888 -ErrorAction SilentlyContinue
if ($existing) {
    $procId = $existing.OwningProcess
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
Start-Process -NoNewWindow -FilePath "kubectl" -ArgumentList "port-forward -n openfaas svc/gateway 8888:8080"
Start-Sleep -Seconds 3
Write-Host "  Gateway accessible sur $GATEWAY_URL" -ForegroundColor Green

# 5. Deployer PostgreSQL si absent
Write-Host ""
Write-Host "[5/8] Verification de PostgreSQL..." -ForegroundColor Yellow
$pgPod = & kubectl get pods -n $NAMESPACE_DB --no-headers 2>&1 | Out-String
if ($pgPod -match "No resources found" -or $pgPod -match "not found" -or [string]::IsNullOrWhiteSpace($pgPod.Trim())) {
    Write-Host "  PostgreSQL absent, deploiement en cours..." -ForegroundColor Yellow
    & kubectl create namespace $NAMESPACE_DB 2>&1 | Out-Null
    & kubectl apply -f "$INFRA_PATH\k8s\postgres\postgres.yaml"
    Write-Host "  Attente demarrage PostgreSQL (30s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    Write-Host "  PostgreSQL deploye : OK" -ForegroundColor Green
} else {
    Write-Host "  PostgreSQL : deja en place" -ForegroundColor Green
}

# Init schema SQL
Write-Host "  Initialisation du schema SQL..." -ForegroundColor Yellow
& kubectl exec -n $NAMESPACE_DB postgres-0 -- psql -U $DB_USER -d $DB_NAME -c "CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, username VARCHAR(64) UNIQUE NOT NULL, password TEXT, mfa TEXT, gendate BIGINT, expired INTEGER DEFAULT 0);" 2>&1 | Out-Null
Write-Host "  Schema SQL : OK" -ForegroundColor Green

# 6. Creer les secrets si absents
Write-Host ""
Write-Host "[6/8] Verification des secrets..." -ForegroundColor Yellow

# Secret Fernet
$fernetExists = & kubectl get secret fernet-key -n $NAMESPACE_FN 2>&1 | Out-String
if ($fernetExists -match "not found" -or $fernetExists -match "No resources") {
    Write-Host "  Creation du secret fernet-key..." -ForegroundColor Yellow
    $FERNET_KEY = docker run --rm python:3.11-alpine sh -c "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'"
    & kubectl create secret generic fernet-key `
        --from-literal=fernet-key="$FERNET_KEY" `
        --namespace $NAMESPACE_FN
    Write-Host "  fernet-key cree : OK" -ForegroundColor Green
} else {
    Write-Host "  fernet-key : deja present" -ForegroundColor Green
}

# Secrets DB individuels
$dbHostExists = & kubectl get secret db-host -n $NAMESPACE_FN 2>&1 | Out-String
if ($dbHostExists -match "not found" -or $dbHostExists -match "No resources") {
    Write-Host "  Creation des secrets DB..." -ForegroundColor Yellow
    & kubectl create secret generic db-host `
        --from-literal=db-host="$DB_HOST" `
        --namespace $NAMESPACE_FN
    & kubectl create secret generic db-name `
        --from-literal=db-name="$DB_NAME" `
        --namespace $NAMESPACE_FN
    & kubectl create secret generic db-user `
        --from-literal=db-user="$DB_USER" `
        --namespace $NAMESPACE_FN
    & kubectl create secret generic db-password `
        --from-literal=db-password="$DB_PASSWORD" `
        --namespace $NAMESPACE_FN
    Write-Host "  Secrets DB crees : OK" -ForegroundColor Green
} else {
    Write-Host "  Secrets DB : deja presents" -ForegroundColor Green
}

# 7. Importer les images dans k3d si necessaire
Write-Host ""
Write-Host "[7/8] Verification des images Docker..." -ForegroundColor Yellow
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
    Write-Host "  Import de $image dans k3d..." -ForegroundColor Yellow
    k3d image import $image -c cofrap 2>&1 | Out-Null
}
Write-Host "  Images : OK" -ForegroundColor Green

# 8. Login faas-cli + deploiement des fonctions
Write-Host ""
Write-Host "[8/8] Login faas-cli et verification des fonctions..." -ForegroundColor Yellow
$PASSWORD_B64 = & kubectl get secret -n $NAMESPACE_OF basic-auth -o jsonpath="{.data.basic-auth-password}"
$PASSWORD = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PASSWORD_B64))
echo $PASSWORD | faas-cli login --username admin --password-stdin --gateway $GATEWAY_URL

$functions = & faas-cli list --gateway $GATEWAY_URL 2>&1 | Out-String
if ($functions -notmatch "generate-password") {
    Write-Host "  Fonctions absentes, deploiement en cours..." -ForegroundColor Yellow
    Push-Location $BACKEND_PATH
    faas-cli template store pull python3-http
    faas-cli deploy -f stack.yaml --gateway $GATEWAY_URL
    Pop-Location
    Write-Host "  Fonctions deployees : OK" -ForegroundColor Green
} else {
    Write-Host "  Fonctions : deja deployees" -ForegroundColor Green
}

# Recap final
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   COFRAP : plateforme prete !" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Interface OpenFaaS : $GATEWAY_URL/ui" -ForegroundColor White
Write-Host "  Utilisateur        : admin" -ForegroundColor White
Write-Host "  Mot de passe       : $PASSWORD" -ForegroundColor White
Write-Host ""
faas-cli list --gateway $GATEWAY_URL