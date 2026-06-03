#!/bin/bash
set -e

echo "=== Installation de l'infrastructure COFRAP ==="

# 1. Namespaces
echo "[1/5] Création des namespaces..."
kubectl create namespace openfaas || true
kubectl create namespace openfaas-fn || true
kubectl create namespace data || true

# 2. Installation OpenFaaS
echo "[2/5] Installation d'OpenFaaS..."
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

helm repo add openfaas https://openfaas.github.io/faas-netes/ || true
helm repo update

helm upgrade openfaas --install openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=true

echo "Attente que la gateway soit prête..."
kubectl rollout status deploy/gateway -n openfaas --timeout=120s

# 3. Installation PostgreSQL
echo "[3/5] Installation PostgreSQL..."
kubectl apply -f ../k8s/postgres/postgres.yaml

echo "Attente que PostgreSQL soit prêt..."
kubectl rollout status statefulset/postgres -n data --timeout=120s

# 4. Création des secrets OpenFaaS
echo "[4/5] Création des secrets OpenFaaS..."
PASSWORD=$(kubectl -n openfaas get secret basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode)

kubectl create secret generic db-host \
  --from-literal=db-host=postgres.data.svc.cluster.local \
  -n openfaas-fn || true

kubectl create secret generic db-name \
  --from-literal=db-name=cofrap \
  -n openfaas-fn || true

kubectl create secret generic db-user \
  --from-literal=db-user=cofrap_app \
  -n openfaas-fn || true

kubectl create secret generic db-password \
  --from-literal=db-password=cofrap_pass \
  -n openfaas-fn || true

kubectl create secret generic fernet-key \
  --from-literal=fernet-key="dummy-fernet-key" \
  -n openfaas-fn || true

# 5. Fin
echo "[5/5] Installation terminée."
echo "Vous pouvez maintenant lancer ./start.sh"
