#!/bin/bash
# COFRAP - Script de demarrage de la plateforme
# Relance le port-forward de la gateway OpenFaaS + login faas-cli + checks
set -e

NAMESPACE_OF="openfaas"
NAMESPACE_FN="openfaas-fn"
NAMESPACE_DB="data"
GATEWAY_PORT=8080

echo "=== COFRAP : demarrage de la plateforme ==="

# 1. Verifier que le cluster repond
echo ""
echo "[1/5] Verification du cluster Kubernetes..."
kubectl get nodes

# 2. Verifier les pods critiques
echo ""
echo "[2/5] Verification des pods OpenFaaS..."
kubectl get pods -n $NAMESPACE_OF

echo ""
echo "[3/5] Verification de PostgreSQL..."
kubectl get pods -n $NAMESPACE_DB

# 3. Tuer un eventuel port-forward existant
echo ""
echo "[4/5] Relance du port-forward gateway (port $GATEWAY_PORT)..."
pkill -f "port-forward.*$GATEWAY_PORT:$GATEWAY_PORT" 2>/dev/null || true
sleep 1
kubectl port-forward -n $NAMESPACE_OF --address 0.0.0.0 svc/gateway $GATEWAY_PORT:$GATEWAY_PORT > /tmp/openfaas-pf.log 2>&1 &
sleep 2

# 4. Login faas-cli
echo ""
echo "[5/5] Login faas-cli..."
PASSWORD=$(kubectl get secret -n $NAMESPACE_OF basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode)
echo -n "$PASSWORD" | faas-cli login --username admin --password-stdin

# 5. Verification finale
echo ""
echo "=== Fonctions deployees ==="
faas-cli list

echo ""
echo "=== Pret ==="
echo "Gateway accessible sur :"
echo "  - Depuis la VM    : http://localhost:$GATEWAY_PORT"
echo "  - Depuis Windows  : http://192.168.56.101:$GATEWAY_PORT"
echo "  - User            : admin"
echo "  - Password        : $PASSWORD"