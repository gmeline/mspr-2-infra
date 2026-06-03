#!/usr/bin/env bash

echo ""
echo "======================================"
echo "  COFRAP — Démarrage de la plateforme"
echo "======================================"

# --- Localisation du .env ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Si pas trouvé dans scripts/, chercher à la racine du projet
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "  Fichier .env introuvable dans $SCRIPT_DIR"
  echo "  Copie .env.example en .env et remplis les chemins."
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

if [[ -z "$BACKEND_PATH" || -z "$INFRA_PATH" ]]; then
  echo "  BACKEND_PATH et INFRA_PATH doivent être définis dans le .env"
  exit 1
fi

# --- 1. Docker ---
echo ""
echo "[1/9] Vérification de Docker..."
if ! docker ps >/dev/null 2>&1; then
  echo "  Docker n'est pas démarré, tentative de lancement..."
  open -a Docker 2>/dev/null || true
  echo "  Attente du démarrage de Docker (jusqu'à 60s)..."
  for i in {1..30}; do
    if docker ps >/dev/null 2>&1; then
      break
    fi
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
if ! command -v minikube >/dev/null 2>&1; then
  echo "  Minikube non installé, installation..."
  brew install minikube
fi

if minikube status 2>/dev/null | grep -q "Running"; then
  echo "  Minikube : déjà en cours d'exécution"
else
  echo "  Démarrage de Minikube..."
  minikube start --cpus=2 --memory=4096
fi
minikube update-context 2>/dev/null || true
echo "  Minikube : OK"

# --- 3. Cluster Kubernetes ---
echo ""
echo "[3/9] Vérification du cluster Kubernetes..."
kubectl get nodes
until kubectl get --raw=/healthz >/dev/null 2>&1; do
  echo "  → API pas encore prête, nouvelle tentative..."
  sleep 2
done
echo "  Cluster : OK"

# --- 4. Helm ---
echo ""
echo "[4/9] Vérification de Helm..."
if ! command -v helm >/dev/null 2>&1; then
  echo "  Helm non installé, installation..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "  Helm : OK"

# --- 5. OpenFaaS ---
echo ""
echo "[5/9] Vérification d'OpenFaaS..."
if ! helm list -n "$NAMESPACE_OF" 2>/dev/null | grep -q openfaas; then
  echo "  OpenFaaS absent, nettoyage des résidus éventuels..."

  # Supprimer les anciennes releases Helm en conflit
  helm uninstall openfaas -n openfaas 2>/dev/null || true
  helm uninstall openfaas -n openfaas-2 2>/dev/null || true

  # Supprimer les CRDs openfaas en conflit
  if kubectl get crd 2>/dev/null | grep -q openfaas; then
    echo "  Suppression des CRDs openfaas en conflit..."
    kubectl get crd | grep openfaas | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true
  fi

  # Supprimer les namespaces résiduels
  kubectl delete namespace openfaas openfaas-fn openfaas-2 2>/dev/null || true
  sleep 5

  echo "  Déploiement d'OpenFaaS..."
  kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
  helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>/dev/null || true
  helm repo update
  helm upgrade openfaas --install openfaas/openfaas \
    --namespace "$NAMESPACE_OF" \
    --set functionNamespace="$NAMESPACE_FN" \
    --set generateBasicAuth=true \
    --set openfaasImagePullPolicy=IfNotPresent \
    --set serviceType=NodePort
  if [[ $? -ne 0 ]]; then
    echo "  Echec du déploiement OpenFaaS. Vérifie les logs ci-dessus."
    exit 1
  fi
  echo "  Attente que OpenFaaS soit prêt..."
  kubectl rollout status deployment/gateway -n "$NAMESPACE_OF" --timeout=180s
  echo "  OpenFaaS déployé : OK"
else
  echo "  OpenFaaS : déjà déployé"
fi

# --- 6. PostgreSQL ---
echo ""
echo "[6/9] Vérification de PostgreSQL..."
if ! kubectl get pods -n "$NAMESPACE_DB" --no-headers 2>/dev/null | grep -q postgres; then
  echo "  PostgreSQL absent, déploiement..."
  kubectl create namespace "$NAMESPACE_DB" 2>/dev/null || true
  kubectl apply --validate=false -f "$INFRA_PATH/k8s/postgres/postgres.yaml"
  echo "  Attente que PostgreSQL soit prêt..."
  kubectl rollout status statefulset/postgres -n "$NAMESPACE_DB" --timeout=120s
  sleep 5
  echo "  PostgreSQL déployé : OK"
else
  echo "  PostgreSQL : déjà en place"
fi

echo "  Initialisation du schema SQL..."
kubectl exec -i -n "$NAMESPACE_DB" postgres-0 -- psql -U "$DB_USER" -d "$DB_NAME" << 'SQL'
CREATE TABLE IF NOT EXISTS users (
    id        SERIAL PRIMARY KEY,
    username  VARCHAR(64)  UNIQUE NOT NULL,
    password  TEXT         NOT NULL,
    mfa       TEXT         NOT NULL,
    gendate   BIGINT       NOT NULL,
    expired   SMALLINT     DEFAULT 0
);
SQL
echo "  Schema SQL : OK"

# --- 7. Secrets ---
echo ""
echo "[7/9] Vérification des secrets..."

if ! kubectl get secret fernet-key -n "$NAMESPACE_FN" >/dev/null 2>&1; then
  echo "  Génération de la clé Fernet..."
  FERNET_KEY=$(docker run --rm python:3.11-alpine sh -c \
    "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'")
  echo "  Clé Fernet : $FERNET_KEY"
  echo "  IMPORTANT : notez cette clé, elle ne sera plus affichée."
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
  if ! docker images "$image" --format "{{.Repository}}:{{.Tag}}" | grep -q "$image"; then
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
  if curl -s http://127.0.0.1:8888 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
echo "  Gateway accessible sur $GATEWAY_URL"

PASSWORD_B64=$(kubectl get secret -n "$NAMESPACE_OF" basic-auth -o jsonpath="{.data.basic-auth-password}")
PASSWORD=$(echo "$PASSWORD_B64" | base64 --decode)
echo "$PASSWORD" | faas-cli login --username admin --password-stdin --gateway "$GATEWAY_URL"

if ! faas-cli list --gateway "$GATEWAY_URL"

echo ""
echo "  Port-forward actif — ce terminal doit rester ouvert."
echo "  Appuie sur Ctrl+C pour arrêter."
wait | grep -q generate-password; then
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
echo "  Interface OpenFaaS : $GATEWAY_URL/ui"
echo "  Utilisateur        : admin"
echo "  Mot de passe       : $PASSWORD"
echo ""
faas-cli list --gateway "$GATEWAY_URL"

echo ""
echo "  Port-forward actif — ce terminal doit rester ouvert."
echo "  Appuie sur Ctrl+C pour arrêter."
wait