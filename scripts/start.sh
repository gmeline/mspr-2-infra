#!/usr/bin/env bash
# COFRAP - Script de demarrage (macOS / bash)
# Usage : ./start.sh

NAMESPACE_OF="openfaas"
NAMESPACE_FN="openfaas-fn"
NAMESPACE_DB="data"
BACKEND_PATH="$HOME/EPSI/MSPR2/cofrap-poc/mspr-2-backend/functions"
INFRA_PATH="$HOME/EPSI/MSPR2/cofrap-poc/mspr-2-infra"
GATEWAY_URL="http://127.0.0.1:8888"
DB_HOST="postgres.data.svc.cluster.local"
DB_NAME="cofrap"
DB_USER="cofrap_app"
DB_PASSWORD="ChangeMe_S3cret!"

echo ""
echo "=== COFRAP : demarrage de la plateforme ==="

# 1. Verifier Docker
echo ""
echo "[1/8] Verification de Docker..."
if ! docker ps &>/dev/null; then
    echo "  Docker n'est pas demarre. Lance Docker Desktop et relance ce script."
    exit 1
fi
echo "  Docker : OK"

# 2. Fixer le kubeconfig
echo ""
echo "[2/8] Correction du kubeconfig..."
KUBECONFIG_PATH="$HOME/.kube/config"
if [ -f "$KUBECONFIG_PATH" ]; then
    sed -i '' 's/host\.docker\.internal/127.0.0.1/g' "$KUBECONFIG_PATH"
    echo "  kubeconfig : OK"
else
    mkdir -p "$HOME/.kube"
    k3d kubeconfig get cofrap > "$KUBECONFIG_PATH"
    sed -i '' 's/host\.docker\.internal/127.0.0.1/g' "$KUBECONFIG_PATH"
    echo "  kubeconfig regenere : OK"
fi

# 3. Verifier le cluster
echo ""
echo "[3/8] Verification du cluster Kubernetes..."
kubectl get nodes
echo "  Cluster : OK"

# 4. Port-forward gateway
echo ""
echo "[4/8] Lancement du port-forward gateway..."
# Tuer l'eventuel process existant sur le port 8888
PID=$(lsof -ti tcp:8888 2>/dev/null)
if [ -n "$PID" ]; then
    kill -9 "$PID" 2>/dev/null
    sleep 1
fi
kubectl port-forward -n "$NAMESPACE_OF" svc/gateway 8888:8080 &>/dev/null &
sleep 3
echo "  Gateway accessible sur $GATEWAY_URL"

# 5. Deployer PostgreSQL si absent
echo ""
echo "[5/8] Verification de PostgreSQL..."
PG_POD=$(kubectl get pods -n "$NAMESPACE_DB" --no-headers 2>&1)
if echo "$PG_POD" | grep -qE "No resources found|not found" || [ -z "$(echo "$PG_POD" | tr -d '[:space:]')" ]; then
    echo "  PostgreSQL absent, deploiement en cours..."
    kubectl create namespace "$NAMESPACE_DB" 2>/dev/null || true
    kubectl apply -f "$INFRA_PATH/k8s/postgres/postgres.yaml"
    echo "  Attente demarrage PostgreSQL (30s)..."
    sleep 30
    echo "  PostgreSQL deploye : OK"
else
    echo "  PostgreSQL : deja en place"
fi

# Init schema SQL
echo "  Initialisation du schema SQL..."
kubectl exec -n "$NAMESPACE_DB" postgres-0 -- psql -U "$DB_USER" -d "$DB_NAME" -c \
    "CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, username VARCHAR(64) UNIQUE NOT NULL, password TEXT, mfa TEXT, gendate BIGINT, expired INTEGER DEFAULT 0);" &>/dev/null
echo "  Schema SQL : OK"

# 6. Creer les secrets si absents
echo ""
echo "[6/8] Verification des secrets..."

# Secret Fernet
if ! kubectl get secret fernet-key -n "$NAMESPACE_FN" &>/dev/null; then
    echo "  Creation du secret fernet-key..."
    FERNET_KEY=$(docker run --rm python:3.11-alpine sh -c \
        "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'")
    kubectl create secret generic fernet-key \
        --from-literal=fernet-key="$FERNET_KEY" \
        --namespace "$NAMESPACE_FN"
    echo "  fernet-key cree : OK"
else
    echo "  fernet-key : deja present"
fi

# Secrets DB individuels
if ! kubectl get secret db-host -n "$NAMESPACE_FN" &>/dev/null; then
    echo "  Creation des secrets DB..."
    kubectl create secret generic db-host \
        --from-literal=db-host="$DB_HOST" \
        --namespace "$NAMESPACE_FN"
    kubectl create secret generic db-name \
        --from-literal=db-name="$DB_NAME" \
        --namespace "$NAMESPACE_FN"
    kubectl create secret generic db-user \
        --from-literal=db-user="$DB_USER" \
        --namespace "$NAMESPACE_FN"
    kubectl create secret generic db-password \
        --from-literal=db-password="$DB_PASSWORD" \
        --namespace "$NAMESPACE_FN"
    echo "  Secrets DB crees : OK"
else
    echo "  Secrets DB : deja presents"
fi

# 7. Importer les images dans k3d si necessaire
echo ""
echo "[7/8] Verification des images Docker..."
IMAGES=(
    "dockerazariel/generate-password:latest"
    "dockerazariel/generate-2fa:latest"
    "dockerazariel/authenticate:latest"
    "dockerazariel/create-account:latest"
)
for IMAGE in "${IMAGES[@]}"; do
    LOCAL=$(docker images "$IMAGE" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null)
    if [ -z "$LOCAL" ]; then
        echo "  Pull de $IMAGE..."
        docker pull "$IMAGE"
    fi
    echo "  Import de $IMAGE dans k3d..."
    k3d image import "$IMAGE" -c cofrap &>/dev/null
done
echo "  Images : OK"

# 8. Login faas-cli + deploiement des fonctions
echo ""
echo "[8/8] Login faas-cli et verification des fonctions..."
PASSWORD_B64=$(kubectl get secret -n "$NAMESPACE_OF" basic-auth -o jsonpath="{.data.basic-auth-password}")
PASSWORD=$(echo "$PASSWORD_B64" | base64 --decode)
echo "$PASSWORD" | faas-cli login --username admin --password-stdin --gateway "$GATEWAY_URL"

FUNCTIONS=$(faas-cli list --gateway "$GATEWAY_URL" 2>&1)
if ! echo "$FUNCTIONS" | grep -q "generate-password"; then
    echo "  Fonctions absentes, deploiement en cours..."
    pushd "$BACKEND_PATH" > /dev/null
    faas-cli template store pull python3-http
    faas-cli deploy -f stack.yaml --gateway "$GATEWAY_URL"
    popd > /dev/null
    echo "  Fonctions deployees : OK"
else
    echo "  Fonctions : deja deployees"
fi

# Recap final
echo ""
echo "========================================"
echo "   COFRAP : plateforme prete !"
echo "========================================"
echo "  Interface OpenFaaS : $GATEWAY_URL/ui"
echo "  Utilisateur        : admin"
echo "  Mot de passe       : $PASSWORD"
echo ""
faas-cli list --gateway "$GATEWAY_URL"