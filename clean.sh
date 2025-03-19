#!/bin/bash

set -euo pipefail

ARGO_NAMESPACE="openshift-gitops"

echo "[INFO] Deleting ArgoCD applications..."
for app in $(argocd app list -o name); do
    argocd app delete "$app" --cascade || echo "[WARN] Failed to delete app: $app"
done

echo "[INFO] Deleting ArgoCD Git Repository..."
argocd repo rm https://github.com/kevin-biot/deployment-ocs.git || echo "[WARN] Repo already removed."

echo "[INFO] Deleting RoleBindings..."
oc delete rolebinding -n "$ARGO_NAMESPACE" --all --ignore-not-found || true

echo "[INFO] Deleting Namespaces..."
oc delete namespace openshift-pipelines --ignore-not-found || true
oc delete namespace awx --ignore-not-found || true

echo "[INFO] Reset Complete. Ready for fresh deployment."
