# COFRAP - Script de demarrage (Windows PowerShell 5.1)
# Usage : .\start.ps1

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
if ($minikubeStatus -notmatch "Running") {
    Write-Host "  Demarrage de Minikube..." -ForegroundColor Yellow
    & minikube start --cpus=2 --memory=4096
}
& minikube update-context 2>&1 | Out-Null
Write-Host "  Minikube : OK" -ForegroundColor Green

# 3. Cluster Kubernetes
Write-Host ""
Write-Host "[3/9] Verification du cluster Kubernetes..." -ForegroundColor Yellow
kubectl get nodes
Write-Host "  Cluster : OK" -ForegroundColor Green

# 4. Helm
Write-Host ""
Write-Host "[4/9] Verification de Helm..." -ForegroundColor Yellow
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Host "  Helm non installe. Installe-le via : winget install Helm.Helm" -ForegroundColor Red
    return
}
Write-Host "  Helm : OK" -ForegroundColor Green

# 5. OpenFaaS
Write-Host ""
Write-Host "[5/9] Verification d'OpenFaaS..." -ForegroundColor Yellow
$helmList = & helm list -n $NAMESPACE_OF 2>&1 | Out-String
if ($helmList -notmatch "openfaas") {
    Write-Host "  OpenFaaS absent, nettoyage des residus eventuels..." -ForegroundColor Yellow

    # Supprimer les anciennes releases Helm (openfaas-2 ou autre namespace)
    $allReleases = & helm list -A 2>&1 | Out-String
    if ($allReleases -match "openfaas") {
        helm uninstall openfaas -n openfaas 2>$null | Out-Null
        helm uninstall openfaas -n openfaas-2 2>$null | Out-Null
    }

    # Supprimer les CRDs openfaas en conflit
    $crds = & kubectl get crd 2>&1 | Out-String
    if ($crds -match "openfaas") {
        Write-Host "  Suppression des CRDs openfaas en conflit..." -ForegroundColor Yellow
        kubectl get crd | Select-String "openfaas" | ForEach-Object {
            $crd = ($_.ToString().Trim() -split '\s+')[0]
            kubectl delete crd $crd 2>$null | Out-Null
        }
    }

    # Supprimer les namespaces residuels
    kubectl delete namespace openfaas openfaas-fn openfaas-2 2>$null | Out-Null
    Start-Sleep -Seconds 5

    Write-Host "  Deploiement d'OpenFaaS..." -ForegroundColor Yellow
    kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
    helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>&1 | Out-Null
    helm repo update
    helm upgrade openfaas --install openfaas/openfaas `
        --namespace $NAMESPACE_OF `
        --set functionNamespace=$NAMESPACE_FN `
        --set generateBasicAuth=true
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
$pgPod = & kubectl get pods -n $NAMESPACE_DB --no-headers 2>&1 | Out-String
if ($pgPod -match "No resources found" -or $pgPod -match "not found" -or [string]::IsNullOrWhiteSpace($pgPod.Trim())) {
    Write-Host "  PostgreSQL absent, deploiement..." -ForegroundColor Yellow
    & kubectl create namespace $NAMESPACE_DB 2>&1 | Out-Null
    & kubectl apply --validate=false -f "$INFRA_PATH\k8s\postgres\postgres.yaml"
    Write-Host "  Attente que PostgreSQL soit pret..." -ForegroundColor Yellow
    kubectl rollout status statefulset/postgres -n $NAMESPACE_DB --timeout=120s
    Start-Sleep -Seconds 5
    Write-Host "  PostgreSQL deploye : OK" -ForegroundColor Green
} else {
    Write-Host "  PostgreSQL : deja en place" -ForegroundColor Green
}

Write-Host "  Initialisation du schema SQL..." -ForegroundColor Yellow
& kubectl exec -n $NAMESPACE_DB postgres-0 -- psql -U $DB_USER -d $DB_NAME -c "CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, username VARCHAR(64) UNIQUE NOT NULL, password TEXT, mfa TEXT, gendate BIGINT, expired INTEGER DEFAULT 0);" 2>&1 | Out-Null
Write-Host "  Schema SQL : OK" -ForegroundColor Green

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

$PASSWORD_B64 = & kubectl get secret -n $NAMESPACE_OF basic-auth -o jsonpath="{.data.basic-auth-password}"
$PASSWORD = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PASSWORD_B64))
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