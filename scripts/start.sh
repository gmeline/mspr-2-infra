#!/usr/bin/env bash
set -e

echo ""
echo "======================================"
echo "  COFRAP — Démarrage de la plateforme"
echo "======================================"

# --- Vérification des prérequis ---
echo ""
echo "  Vérification des prérequis..."

# Détection OS
OS="$(uname -s)"

# Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "  Docker Desktop n'est pas installé."
  if [[ "$OS" == "Darwin" ]]; then
    echo "  Télécharge Docker Desktop depuis : https://www.docker.com/products/docker-desktop/"
  else
    echo "  Installe Docker : https://docs.docker.com/engine/install/"
  fi
  exit 1
fi
echo "  Docker : OK"

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  echo "  Installation de kubectl..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install kubectl
  else
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl && sudo mv kubectl /usr/local/bin/
  fi
fi
echo "  kubectl : OK"

# Minikube
if ! command -v minikube >/dev/null 2>&1; then
  echo "  Installation de Minikube..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install minikube
  else
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    chmod +x minikube-linux-amd64 && sudo mv minikube-linux-amd64 /usr/local/bin/minikube
  fi
fi
echo "  Minikube : OK"

# Helm
if ! command -v helm >/dev/null 2>&1; then
  echo "  Installation de Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "  Helm : OK"

# faas-cli
if ! command -v faas-cli >/dev/null 2>&1; then
  echo "  Installation de faas-cli..."
  curl -sSL https://cli.openfaas.com | sudo sh
fi
echo "  faas-cli : OK"

# --- Localisation du .env ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "  Fichier .env introuvable. Copie .env.example en .env et remplis les chemins."
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

if [[ -z "$BACKEND_PATH" || -z "$INFRA_PATH" ]]; then
  echo "  BACKEND_PATH et INFRA_PATH doivent être définis dans le .env"
  exit 1
fi

RELEASES="$INFRA_PATH/releases"

# --- 1. Docker ---
echo ""
echo "[1/9] Vérification de Docker..."
if ! docker ps >/dev/null 2>&1; then
  echo "  Docker n'est pas démarré, tentative de lancement..."
  open -a Docker 2>/dev/null || true
  for i in {1..30}; do
    if docker ps >/dev/null 2>&1; then break; fi
    if [[ $i -eq 30 ]]; then
      echo "  Docker n'a pas démarré à temps. Relance le script une fois Docker prêt."
      exit 1
    fi
    sleep 2
  done
fi
echo "  Docker : OK"

# --- 2. Minikube ---
echo ""
echo "[2/9] Vérification de Minikube..."
MINIKUBE_STATUS=$(minikube status 2>/dev/null || true)

if ! echo "$MINIKUBE_STATUS" | grep -q "host: Running"; then
  echo "  Démarrage de Minikube..."
  minikube start --cpus=2 --memory=4096
elif ! echo "$MINIKUBE_STATUS" | grep -q "apiserver: Running"; then
  echo "  Apiserver arrêté, redémarrage de Minikube..."
  minikube stop 2>/dev/null || true
  minikube start --cpus=2 --memory=4096
fi
minikube update-context 2>/dev/null || true
echo "  Minikube : OK"

# --- 3. Cluster Kubernetes ---
echo ""
echo "[3/9] Vérification du cluster Kubernetes..."
clusterReady=false
for i in $(seq 1 36); do
  if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
    clusterReady=true
    break
  fi
  echo "  → Cluster pas encore prêt, nouvelle tentative ($i/36)..."
  if [[ $i -eq 18 ]]; then
    echo "  → Redémarrage de Minikube..."
    minikube stop 2>/dev/null || true
    minikube start --cpus=2 --memory=4096 2>/dev/null || true
  fi
  sleep 5
done
if [[ "$clusterReady" != "true" ]]; then
  echo "  Cluster non disponible après 3 minutes. Vérifie minikube status."
  exit 1
fi
echo "  Cluster : OK"

# --- 4. Helm repos ---
echo ""
echo "[4/9] Mise à jour des repos Helm..."
helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update
echo "  Repos Helm : OK"

# --- 5. OpenFaaS ---
echo ""
echo "[5/9] Vérification d'OpenFaaS..."
if ! helm list -n "$NAMESPACE_OF" 2>/dev/null | grep -q openfaas; then
  echo "  OpenFaaS absent, nettoyage des résidus éventuels..."
  helm uninstall openfaas -n openfaas 2>/dev/null || true
  helm uninstall openfaas -n openfaas-2 2>/dev/null || true

  if kubectl get crd 2>/dev/null | grep -q openfaas; then
    echo "  Suppression des CRDs openfaas en conflit..."
    kubectl get crd | grep openfaas | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true
  fi

  kubectl delete namespace openfaas openfaas-fn openfaas-2 2>/dev/null || true
  sleep 5

  echo "  Déploiement d'OpenFaaS..."
  kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
  helm upgrade openfaas --install openfaas/openfaas \
    --namespace "$NAMESPACE_OF" \
    -f "$RELEASES/openfaas/values.yaml"
  echo "  Attente que OpenFaaS soit prêt..."
  kubectl rollout status deployment/gateway -n "$NAMESPACE_OF" --timeout=180s
  echo "  OpenFaaS déployé : OK"
else
  echo "  OpenFaaS : déjà déployé"
fi

# --- 6. PostgreSQL ---
echo ""
echo "[6/9] Vérification de PostgreSQL..."
if ! helm list -n "$NAMESPACE_DB" 2>/dev/null | grep -q postgres; then
  echo "  PostgreSQL absent, déploiement..."
  kubectl create namespace "$NAMESPACE_DB" 2>/dev/null || true
  helm upgrade postgres --install bitnami/postgresql \
    --namespace "$NAMESPACE_DB" \
    -f "$RELEASES/postgres/values.yaml" \
    --set auth.password="$DB_PASSWORD" \
    --set-file primary.initdb.scripts."init\.sql"="$BACKEND_PATH/../sql/init.sql"
  echo "  Attente que PostgreSQL soit prêt..."
  kubectl rollout status statefulset/postgres -n "$NAMESPACE_DB" --timeout=120s
  echo "  PostgreSQL déployé : OK"
else
  echo "  PostgreSQL : déjà en place"
fi

# --- 7. Secrets ---
echo ""
echo "[7/9] Vérification des secrets..."

if ! kubectl get secret fernet-key -n "$NAMESPACE_FN" >/dev/null 2>&1; then
  echo "  Génération de la clé Fernet..."
  FERNET_KEY=$(docker run --rm python:3.11-alpine sh -c \
    "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'")
  kubectl create secret generic fernet-key \
    --from-literal=fernet-key="$FERNET_KEY" \
    -n "$NAMESPACE_FN"
  echo "  fernet-key créé : OK"
else
  echo "  fernet-key : déjà présent"
fi

if ! kubectl get secret db-host -n "$NAMESPACE_FN" >/dev/null 2>&1; then
  echo "  Création des secrets DB..."
  kubectl create secret generic db-host --from-literal=db-host="$DB_HOST" -n "$NAMESPACE_FN"
  kubectl create secret generic db-name --from-literal=db-name="$DB_NAME" -n "$NAMESPACE_FN"
  kubectl create secret generic db-user --from-literal=db-user="$DB_USER" -n "$NAMESPACE_FN"
  kubectl create secret generic db-password --from-literal=db-password="$DB_PASSWORD" -n "$NAMESPACE_FN"
  echo "  Secrets DB créés : OK"
else
  echo "  Secrets DB : déjà présents"
fi

if ! kubectl get secret smtp-host -n "$NAMESPACE_FN" >/dev/null 2>&1; then
  echo "  Création des secrets SMTP..."
  kubectl create secret generic smtp-host     --from-literal=smtp-host="$SMTP_HOST"         -n "$NAMESPACE_FN"
  kubectl create secret generic smtp-port     --from-literal=smtp-port="$SMTP_PORT"         -n "$NAMESPACE_FN"
  kubectl create secret generic smtp-user     --from-literal=smtp-user="$SMTP_USER"         -n "$NAMESPACE_FN"
  kubectl create secret generic smtp-password --from-literal=smtp-password="$SMTP_PASSWORD" -n "$NAMESPACE_FN"
  kubectl create secret generic smtp-from     --from-literal=smtp-from="$SMTP_FROM"         -n "$NAMESPACE_FN"
  echo "  Secrets SMTP créés : OK"
else
  echo "  Secrets SMTP : déjà présents"
fi

# --- 8. Images Docker ---
echo ""
echo "[8/9] Vérification des images Docker..."
IMAGES=(
  "dockerazariel/generate-password:latest"
  "dockerazariel/generate-2fa:latest"
  "dockerazariel/authenticate:latest"
  "dockerazariel/create-account:latest"
)
for image in "${IMAGES[@]}"; do
  if ! docker images "$image" --format "{{.Repository}}:{{.Tag}}" | grep -q .; then
    echo "  Pull de $image..."
    docker pull "$image"
  fi
  echo "  Chargement de $image dans minikube..."
  minikube image load "$image"
done
echo "  Images : OK"

# --- 9. Port-forward + faas-cli ---
echo ""
echo "[9/9] Port-forward gateway + login faas-cli..."

PID=$(lsof -ti tcp:8888 || true)
if [[ -n "$PID" ]]; then
  kill -9 "$PID" || true
  sleep 1
fi

kubectl port-forward -n "$NAMESPACE_OF" svc/gateway 8888:8080 >/dev/null 2>&1 &

echo "  Attente stabilisation du port-forward..."
for i in {1..10}; do
  if curl -s http://127.0.0.1:8888 >/dev/null 2>&1; then break; fi
  sleep 1
done
echo "  Gateway accessible sur $GATEWAY_URL"

PASSWORD_B64=$(kubectl get secret -n "$NAMESPACE_OF" basic-auth -o jsonpath="{.data.basic-auth-password}")
PASSWORD=$(echo "$PASSWORD_B64" | base64 --decode)
echo "$PASSWORD" | faas-cli login --username admin --password-stdin --gateway "$GATEWAY_URL"

if ! faas-cli list --gateway "$GATEWAY_URL" 2>/dev/null | grep -q generate-password; then
  echo "  Fonctions absentes, déploiement..."
  pushd "$BACKEND_PATH" > /dev/null
  faas-cli template store pull python3-http
  faas-cli deploy -f stack.yaml --gateway "$GATEWAY_URL"
  popd > /dev/null
  echo "  Fonctions déployées : OK"
else
  echo "  Fonctions : déjà déployées"
fi

# --- Recap ---
echo ""
echo "======================================"
echo "   COFRAP : plateforme prête !"
echo "======================================"
echo "  Interface OpenFaaS : $GATEWAY_URL/ui/"
echo "  Utilisateur        : admin"
echo "  Mot de passe       : $PASSWORD"
echo ""
faas-cli list --gateway "$GATEWAY_URL"

echo ""
echo "  Port-forward actif — ce terminal doit rester ouvert."
echo "  Appuie sur Ctrl+C pour arrêter."
wait
