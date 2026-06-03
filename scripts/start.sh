#!/bin/bash
set -e

NAMESPACE_OF="openfaas"
NAMESPACE_FN="openfaas-fn"
NAMESPACE_DB="data"
GATEWAY_PORT=8888

echo "=== COFRAP : demarrage de la plateforme ==="

# 0. Vérifier si un cluster k3d existe, sinon le créer
echo ""
echo "[0/5] Vérification du cluster k3d..."

CLUSTERS=$(k3d cluster list | wc -l)

if [ "$CLUSTERS" -le 1 ]; then
    echo "Aucun cluster k3d détecté. Création du cluster 'cofrap'..."
    k3d cluster create cofrap \
        --servers 1 \
        --agents 2 \
        --port "8080:80@loadbalancer" \
        --k3s-arg "--disable=traefik@server:0"
    echo "Cluster k3d 'cofrap' créé."
else
    echo "Cluster k3d déjà existant."
fi

# Forcer kubectl à utiliser le contexte k3d
kubectl config use-context k3d-cofrap >/dev/null 2>&1 || true

# 1. Verifier que le cluster repond
echo ""
echo "[1/5] Verification du cluster Kubernetes..."
kubectl get nodes

# 2. Verifier les pods critiques
echo ""
echo "[2/5] Verification des pods OpenFaaS..."
kubectl get pods -n $NAMESPACE_OF || echo "Namespace OpenFaaS vide"

echo ""
echo "[3/5] Verification de PostgreSQL..."
kubectl get pods -n $NAMESPACE_DB || echo "Namespace data vide"

# 3. Tuer un eventuel port-forward existant
echo ""
echo "[4/5] Relance du port-forward gateway (port $GATEWAY_PORT)..."
pkill -f "port-forward.*$GATEWAY_PORT:$GATEWAY_PORT" 2>/dev/null || true
sleep 1
kubectl port-forward -n $NAMESPACE_OF --address 0.0.0.0 svc/gateway 8888:8080 > /tmp/openfaas-pf.log 2>&1 &
sleep 2

# 4. Login faas-cli
echo ""
echo "[5/5] Login faas-cli..."
PASSWORD=$(kubectl get secret -n $NAMESPACE_OF basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode)
echo -n "$PASSWORD" | faas-cli login --username admin --password-stdin --gateway http://127.0.0.1:8888


# 5. Verification finale
echo ""
echo "=== Fonctions deployees ==="
faas-cli list --gateway http://127.0.0.1:8888


echo ""
echo "=== Pret ==="
echo "Gateway accessible sur :"
echo "  - http://localhost:$GATEWAY_PORT"
echo "  - User      : admin"
echo "  - Password  : $PASSWORD"
