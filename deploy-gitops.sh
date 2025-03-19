#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Deploys Tekton and AWX operators via GitOps principles using ArgoCD

set -euo pipefail
trap cleanup_on_failure ERR

# ========== CONFIGURATION ==========
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

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        if ! command -v "$cmd" &>/dev/null; then
            error_exit "Missing required command: $cmd. Please install it."
        fi
    done
    log_info "All dependencies verified."
}

# ========== CLEANUP FUNCTION ==========
cleanup_on_failure() {
    log_info "Cleaning up due to failure..."
    read -t 30 -p "Proceed with forced cleanup of namespaces? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete ns "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --force --grace-period=0 --ignore-not-found
        log_info "Cleanup complete."
    else
        log_info "Cleanup skipped by user request."
    fi
}

# ========== WAIT FUNCTION ==========
wait_for_pods() {
    local namespace="$1"
    log_info "Waiting for pods in $namespace to be ready..."
    oc wait pods -n "$namespace" --all --for=condition=Ready --timeout=600s || error_exit "Pods in $namespace did not become ready in time."
}

# ========== VERIFY OPENSHIFT LOGIN ==========
oc whoami &>/dev/null || error_exit "Not logged into OpenShift!"

# ========== VERIFY OPENSHIFT GITOPS ==========
verify_gitops() {
    log_info "Verifying OpenShift GitOps (ArgoCD) is running..."
    oc get ns "$ARGO_NAMESPACE" &>/dev/null || error_exit "ArgoCD namespace missing. Install OpenShift GitOps first."
    wait_for_pods "$ARGO_NAMESPACE"
    log_info "OpenShift GitOps verified."
}

# ========== LOGIN ARGOCD ==========
login_argocd() {
    SERVER_URL=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    argocd login "$SERVER_URL" --username admin --password "$ADMIN_PASSWD" --insecure --grpc-web
}

# ========== SETUP GIT ==========
setup_git() {
    cd "$LOCAL_GIT_DIR"
    git pull origin "$GIT_BRANCH"
    git add .
    git commit -m "Updated Tekton and AWX deployment configuration" || true
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
}

# ========== CREATE NAMESPACES ==========
for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
    oc get ns "$ns" &>/dev/null || oc create ns "$ns"
done

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" --upsert

    for app in tekton awx; do
        argocd app create "${app}-app" --upsert \
          --repo "$GIT_REPO" --path "$app" \
          --dest-server "https://kubernetes.default.svc" --dest-namespace "${app%-app}" \
          --sync-policy automated

        argocd app sync "${app}-app" --prune --force
    done

    wait_for_pods "$TEKTON_NAMESPACE"
    wait_for_pods "$ANSIBLE_NAMESPACE"
}

# ========== MAIN DEPLOYMENT ==========
check_dependencies
verify_gitops
login_argocd
setup_git
create_argocd_apps

TEKTON_URL=$(oc get routes -n "$TEKTON_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")
AWX_URL=$(oc get routes -n "$ANSIBLE_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")

log_info "✅ GitOps deployment completed successfully!"
log_info "📌 ArgoCD UI: https://$SERVER_URL"
log_info "📌 Tekton UI: ${TEKTON_URL:+https://$TEKTON_URL}"
log_info "📌 AWX UI: ${AWX_URL:+https://$AWX_URL}"

