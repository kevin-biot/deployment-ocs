#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Deploys Tekton and AWX via GitOps (ArgoCD) with robust error checking

set -euo pipefail
trap cleanup_on_failure ERR

# ========== CONFIGURATION ==========
GIT_REPO="https://github.com/kevin-biot/deployment-ocs.git"
GIT_BRANCH="main"
ARGO_NAMESPACE="openshift-gitops"
TEKTON_NAMESPACE="openshift-pipelines"
AWX_NAMESPACE="awx"
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
        command -v "$cmd" &>/dev/null || error_exit "$cmd is not installed."
    done
    log_info "Dependencies OK."
}

# ========== CLEANUP FUNCTION ==========
cleanup_on_failure() {
    log_error "Cleanup triggered due to failure."
    read -t 30 -p "Proceed with forced namespace cleanup? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete ns "$TEKTON_NAMESPACE" "$AWX_NAMESPACE" --force --grace-period=0 --ignore-not-found
        log_info "Namespaces forcibly cleaned up."
    else
        log_info "Namespace cleanup skipped by user."
    fi
}

# ========== WAIT FUNCTION ==========
wait_for_pods() {
    local namespace="$1"
    local timeout=600
    log_info "Waiting for pods in $namespace to be ready (timeout: ${timeout}s)..."
    if ! oc wait --for=condition=Ready pods --all -n "$namespace" --timeout=${timeout}s; then
        error_exit "Pods in $namespace did not become ready within timeout."
    fi
    log_info "$namespace pods are running."
}

# ========== VERIFY ARGOCD ==========
verify_gitops() {
    log_info "Verifying ArgoCD is deployed..."
    oc get ns "$ARGO_NAMESPACE" >/dev/null || error_exit "ArgoCD namespace not found."
    wait_for_pods "$ARGO_NAMESPACE"
    log_info "ArgoCD verified."
}

# ========== LOGIN TO ARGOCD ==========
login_argocd() {
    log_info "Logging into ArgoCD..."
    local passwd=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    local route=$(oc get routes -n "$ARGO_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="openshift-gitops-server")].spec.host}')
    argocd login "$route" --username admin --password "$passwd" --insecure --grpc-web >/dev/null || error_exit "Failed ArgoCD login."
    log_info "Logged into ArgoCD."
}

# ========== SETUP GIT YAML ==========
setup_git_yamls() {
    log_info "Creating required YAML files..."
    mkdir -p "$LOCAL_GIT_DIR/{tekton,awx,argocd}"

    cat > "$LOCAL_GIT_DIR/tekton/catalogsource.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: community-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/operatorhubio/catalog:latest
  displayName: Community OperatorHub Catalog
  publisher: OperatorHub.io
EOF

    cat > "$LOCAL_GIT_DIR/tekton/tekton-pipelines.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tekton-operator
  namespace: $TEKTON_NAMESPACE
spec:
  channel: stable
  name: tekton-operator
  source: community-catalog
  sourceNamespace: openshift-marketplace
EOF

    cat > "$LOCAL_GIT_DIR/awx/awx-operator.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: awx-operator
  namespace: $AWX_NAMESPACE
spec:
  channel: stable
  name: awx-operator
  source: community-catalog
  sourceNamespace: openshift-marketplace
EOF

    log_info "YAML files created. Committing and pushing to Git."
    git add .
    git commit -m "Updated Tekton and AWX YAML configs" || log_info "Nothing to commit."
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH" --force || error_exit "Git push failed."
}

# ========== CREATE & SYNC ARGO APPS ==========
create_sync_app() {
    local app=$1
    argocd app create "$app" --repo "$GIT_REPO" --path "$app" --dest-namespace "${app%-app}" --dest-server https://kubernetes.default.svc --sync-policy automated --upsert || true

    for attempt in {1..3}; do
        if argocd app sync "$app" --prune --force; then
            log_info "$app synced successfully."
            return
        else
            log_error "$app sync failed on attempt $attempt. Retrying in 10s."
            sleep 10
        fi
    done
    error_exit "$app failed to sync after 3 attempts."
}

# ========== MAIN ==========
mkdir -p "$LOG_DIR"
:> "$DEPLOY_LOG"
[[ -z "$GIT_TOKEN" ]] && error_exit "GIT_TOKEN unset."
check_dependencies
verify_gitops
login_argocd
setup_git_yamls

oc create ns "$TEKTON_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc create ns "$AWX_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

log_info "Deploying Tekton and AWX apps..."
create_sync_app tekton-app
create_sync_app awx-app

wait_for_pods "$TEKTON_NAMESPACE"
wait_for_pods "$AWX_NAMESPACE"

log_info "✅ Deployment completed successfully!"

