#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Installs & configures:
# - ArgoCD (OpenShift GitOps)
# - Tekton Pipelines
# - AWX Operator
# Ensures proper logging, error handling, and cleanup on failure.

set -euo pipefail
trap cleanup_on_failure EXIT

# ========== CONFIGURATION ==========
GIT_REPO="https://github.com/kevin-biot/deployment-ocs.git"
GIT_BRANCH="main"
ARGO_NAMESPACE="openshift-gitops"
TEKTON_NAMESPACE="openshift-pipelines"
ANSIBLE_NAMESPACE="awx"
LOCAL_GIT_DIR=~/deployment-ocs
LOG_DIR="$LOCAL_GIT_DIR/logs"
DEPLOY_LOG="$LOG_DIR/deployment.log"

# Detect GitHub username automatically
GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-}" # Expect token to be set as environment variable

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git gh yamllint; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Missing required command: $cmd"
            error_exit "Please install $cmd before running the script."
        fi
    done
    log_info "All dependencies verified."
}

# ========== SETUP ==========
mkdir -p "$LOG_DIR"
> "$DEPLOY_LOG"

# Validate Git token
if [[ -z "$GIT_TOKEN" ]]; then
    error_exit "GIT_TOKEN environment variable not set. Please set it before running the script."
fi

# Ensure OpenShift Login
log_info "Checking OpenShift login status..."
if ! oc whoami &>/dev/null; then
    log_info "Logging in to OpenShift..."
    oc login -u kubeadmin || error_exit "OpenShift login failed!"
fi
log_info "OpenShift login verified."

# Check if script is running in the correct directory
if [[ ! -d "$LOCAL_GIT_DIR" ]]; then
    error_exit "Expected script to be run in $LOCAL_GIT_DIR, but it is missing!"
fi
log_info "Correct directory detected."

# ========== CLEANUP FUNCTION ==========
cleanup_on_failure() {
    log_info "Cleaning up due to failure..."
    read -p "Proceed with forced cleanup of namespaces? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete ns "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --force --grace-period=0 --ignore-not-found
        log_info "Cleanup complete."
    else
        log_info "Cleanup skipped by user request."
    fi
}

# ========== VERIFY OPENSHIFT GITOPS ==========
verify_gitops() {
    log_info "Verifying OpenShift GitOps (ArgoCD) is running..."
    
    if ! oc get ns "$ARGO_NAMESPACE" &>/dev/null; then
        error_exit "ArgoCD namespace $ARGO_NAMESPACE not found. Please ensure OpenShift GitOps operator is installed."
    fi
    
    if ! oc get csv -n openshift-operators | grep -q "openshift-gitops-operator"; then
        error_exit "OpenShift GitOps Operator not found in openshift-operators namespace."
    fi
    
    wait_for_pods "$ARGO_NAMESPACE"
    log_info "OpenShift GitOps (ArgoCD) verified as running in $ARGO_NAMESPACE."
}

# ========== CHECK ARGOCD LOGIN ==========
login_argocd() {
    log_info "Checking if already logged into ArgoCD..."
    if argocd account get-user &>/dev/null; then
        log_info "Already logged into ArgoCD. Skipping login."
        return
    fi

    log_info "Logging into ArgoCD..."
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    SERVER_URL=$(oc get routes -n "$ARGO_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="openshift-gitops-server")].spec.host}')

    if [[ -z "$ADMIN_PASSWD" || -z "$SERVER_URL" ]]; then
        error_exit "ArgoCD credentials or route not found. Check ArgoCD installation in $ARGO_NAMESPACE."
    fi

    argocd login "$SERVER_URL" --username admin --password "$ADMIN_PASSWD" --insecure --grpc-web || error_exit "Failed to login to ArgoCD."
}

# ========== CONFIGURE GIT REPO ==========
setup_git() {
    log_info "Setting up Git repository..."
    if [[ ! -d .git ]]; then
        log_info "Initializing new Git repository..."
        git init
        git remote add origin "$GIT_REPO"
        git branch -M "$GIT_BRANCH"
    fi

    log_info "Ensuring repo contains necessary files..."
    mkdir -p argocd
    touch argocd/bootstrap-rbac.yaml argocd/tekton-app.yaml argocd/awx-app.yaml

    yamllint -d "{extends: default, rules: {line-length: disable}}" argocd/*.yaml || error_exit "YAML validation failed!"

    git add .
    git commit -m "Initialize GitOps configuration" || error_exit "Failed to commit changes"
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH" || error_exit "Failed to push changes to GitHub."

    log_info "Git repository successfully updated."
}

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    log_info "Registering Git repository in ArgoCD..."
    argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || error_exit "Failed to add Git repo."

    log_info "Checking if ArgoCD has access to Git repository..."
    if ! argocd repo list | grep -q "$GIT_REPO"; then
        error_exit "ArgoCD does not have access to the Git repository!"
    fi

    log_info "Creating ArgoCD applications from GitHub..."
    argocd app create tekton-app --upsert \
      --repo "$GIT_REPO" --path "argocd/tekton-app.yaml" \
      --dest-server "https://kubernetes.default.svc" --dest-namespace "$TEKTON_NAMESPACE" \
      --sync-policy automated || error_exit "Failed to create Tekton application."

    argocd app create awx-app --upsert \
      --repo "$GIT_REPO" --path "argocd/awx-app.yaml" \
      --dest-server "https://kubernetes.default.svc" --dest-namespace "$ANSIBLE_NAMESPACE" \
      --sync-policy automated || error_exit "Failed to create AWX application."

    log_info "ArgoCD applications created successfully."
}

# ========== MAIN DEPLOYMENT ==========
check_dependencies
verify_gitops
login_argocd
setup_git
create_argocd_apps

log_info "✅ GitOps deployment completed successfully!"
log_info "📌 ArgoCD UI: https://$SERVER_URL"
log_info "📌 Tekton UI: https://$(oc get routes -n $TEKTON_NAMESPACE -o jsonpath='{.items[0].spec.host}')"
log_info "📌 AWX UI: https://$(oc get routes -n $ANSIBLE_NAMESPACE -o jsonpath='{.items[0].spec.host}')"
