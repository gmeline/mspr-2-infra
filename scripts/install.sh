#!/bin/bash
set -e

echo "=== Installation de l'infrastructure COFRAP ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
RELEASES="$(dirname "$SCRIPT_DIR")/releases"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "  Fichier .env introuvable. Copie .env.example en .env et remplis les chemins."
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

# 1. Repos Helm
echo "[1/5] Ajout des repos Helm..."
helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# 2. OpenFaaS
echo "[2/5] Installation d'OpenFaaS..."
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  -f "$RELEASES/openfaas/values.yaml"

echo "Attente que la gateway soit prête..."
kubectl rollout status deploy/gateway -n openfaas --timeout=120s

# 3. PostgreSQL
echo "[3/5] Installation PostgreSQL..."
kubectl create namespace data 2>/dev/null || true
helm upgrade postgres --install bitnami/postgresql \
  --namespace data \
  -f "$RELEASES/postgres/values.yaml" \
  --set auth.password="$DB_PASSWORD" \
  --set-file primary.initdb.scripts."init\.sql"="$BACKEND_PATH/../sql/init.sql"

echo "Attente que PostgreSQL soit prêt..."
kubectl rollout status statefulset/postgres -n data --timeout=120s

# 4. Secrets OpenFaaS
echo "[4/5] Création des secrets..."

echo "  Génération de la clé Fernet..."
FERNET_KEY=$(docker run --rm python:3.11-alpine sh -c \
  "pip install cryptography -q && python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'")
kubectl create secret generic fernet-key \
  --from-literal=fernet-key="$FERNET_KEY" \
  -n openfaas-fn 2>/dev/null || \
kubectl patch secret fernet-key -n openfaas-fn \
  -p "{\"stringData\":{\"fernet-key\":\"$FERNET_KEY\"}}"
echo "  fernet-key créé."

kubectl create secret generic db-host --from-literal=db-host="$DB_HOST" -n openfaas-fn 2>/dev/null || true
kubectl create secret generic db-name --from-literal=db-name="$DB_NAME" -n openfaas-fn 2>/dev/null || true
kubectl create secret generic db-user --from-literal=db-user="$DB_USER" -n openfaas-fn 2>/dev/null || true
kubectl create secret generic db-password --from-literal=db-password="$DB_PASSWORD" -n openfaas-fn 2>/dev/null || true

echo "  Création des secrets SMTP..."
kubectl create secret generic smtp-host     --from-literal=smtp-host="$SMTP_HOST"         -n openfaas-fn 2>/dev/null || true
kubectl create secret generic smtp-port     --from-literal=smtp-port="$SMTP_PORT"         -n openfaas-fn 2>/dev/null || true
kubectl create secret generic smtp-user     --from-literal=smtp-user="$SMTP_USER"         -n openfaas-fn 2>/dev/null || true
kubectl create secret generic smtp-password --from-literal=smtp-password="$SMTP_PASSWORD" -n openfaas-fn 2>/dev/null || true
kubectl create secret generic smtp-from     --from-literal=smtp-from="$SMTP_FROM"         -n openfaas-fn 2>/dev/null || true
echo "  Secrets SMTP créés."

# 5. Fin
echo "[5/5] Installation terminée."
echo "Lance maintenant : ./start.sh"
