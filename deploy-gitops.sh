#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script (Corrected)
# ============================
# Deploy Tekton and AWX using GitOps, ArgoCD, and shared community CatalogSource.

set -euo pipefail
trap cleanup_on_failure ERR

# ===== CONFIGURATION =====
GIT_REPO="https://github.com/kevin-biot/deployment-ocs.git"
GIT_BRANCH="main"
ARGO_NAMESPACE="openshift-gitops"
TEKTON_NAMESPACE="openshift-pipelines"
ANSIBLE_NAMESPACE="awx"
LOCAL_GIT_DIR=~/deployment-ocs
LOG_DIR="$LOCAL_GIT_DIR/logs"
DEPLOY_LOG="$LOG_DIR/deployment.log"

GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-}"

log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        command -v "$cmd" &>/dev/null || error_exit "$cmd not found"
    done
    log_info "All dependencies verified."
}

cleanup_old_catalogs() {
    log_info "Cleaning up old CatalogSources..."
    oc delete catalogsource community-catalog -n openshift-marketplace --ignore-not-found
}

cleanup_on_failure() {
    log_info "Cleaning namespaces due to failure..."
    oc delete ns "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --ignore-not-found --force --grace-period=0
}

wait_for_pods() {
    local namespace=$1 TIMEOUT=600 INTERVAL=10 elapsed=0
    log_info "Waiting for pods in $namespace..."
    until [[ $(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -c Running) -gt 0 ]]; do
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
        (( elapsed >= TIMEOUT )) && error_exit "Pods in $namespace did not start"
    done
    log_info "$namespace pods are running"
}

verify_gitops() {
    log_info "Verifying ArgoCD..."
    oc get ns "$ARGO_NAMESPACE" &>/dev/null || error_exit "ArgoCD namespace missing"
    wait_for_pods "$ARGO_NAMESPACE"
}

login_argocd() {
    log_info "Logging into ArgoCD..."
    local pass=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    local url=$(oc get routes -n "$ARGO_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="openshift-gitops-server")].spec.host}')
    argocd login "$url" --username admin --password "$pass" --insecure --grpc-web
}

setup_git() {
    mkdir -p "$LOCAL_GIT_DIR/argocd" "$LOCAL_GIT_DIR/tekton" "$LOCAL_GIT_DIR/awx"

    log_info "Creating ArgoCD App YAMLs..."
    cat <<EOF > "$LOCAL_GIT_DIR/argocd/tekton-app.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-app
  namespace: $ARGO_NAMESPACE
spec:
  source:
    repoURL: $GIT_REPO
    targetRevision: $GIT_BRANCH
    path: tekton
  destination:
    server: https://kubernetes.default.svc
    namespace: $TEKTON_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    cat <<EOF > "$LOCAL_GIT_DIR/argocd/awx-app.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: awx-app
  namespace: $ARGO_NAMESPACE
spec:
  source:
    repoURL: $GIT_REPO
    targetRevision: $GIT_BRANCH
    path: awx
  destination:
    server: https://kubernetes.default.svc
    namespace: $ANSIBLE_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    log_info "Creating shared CatalogSource..."
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/catalogsource.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: community-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/operatorhubio/catalog:latest
EOF

    git add .
    git commit -m "Updated deployment configs" || true
    git push https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git "$GIT_BRANCH"
}

validate_and_create_namespaces() {
    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        oc get ns "$ns" &>/dev/null || oc create ns "$ns"
    done
}

sync_argocd_app() {
    argocd app sync "$1" --prune --force || error_exit "Sync failed: $1"
}

create_argocd_apps() {
    argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || true
    for app in tekton-app awx-app; do
        argocd app create "$app" --repo "$GIT_REPO" --path "${app%-app}" --dest-server "https://kubernetes.default.svc" --dest-namespace "${app%-app}" --sync-policy automated --upsert
        sync_argocd_app "$app"
    done
    wait_for_pods "$TEKTON_NAMESPACE"
    wait_for_pods "$ANSIBLE_NAMESPACE"
}

# ===== MAIN EXECUTION =====
mkdir -p "$LOG_DIR" && > "$DEPLOY_LOG"
[[ -z "$GIT_TOKEN" ]] && error_exit "GIT_TOKEN not set"
oc whoami &>/dev/null || oc login -u kubeadmin

check_dependencies
cleanup_old_catalogs
verify_gitops
login_argocd
setup_git
validate_and_create_namespaces
create_argocd_apps

log_info "✅ Deployment succeeded."
log_info "ArgoCD URL: https://$(oc get route openshift-gitops-server -n $ARGO_NAMESPACE -o jsonpath='{.spec.host}')"

