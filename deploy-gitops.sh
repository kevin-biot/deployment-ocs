#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Installs & configures:
# - ArgoCD (OpenShift GitOps)
# - Tekton Pipelines
# - AWX Operator
# Ensures proper logging, error handling, and cleanup on failure.

# ========== CONFIGURATION ==========
GIT_REPO="https://github.com/kevin-biot/deployment-ocs.git"
GIT_BRANCH="main"
ARGO_NAMESPACE="openshift-gitops"
TEKTON_NAMESPACE="openshift-pipelines"
ANSIBLE_NAMESPACE="awx"
LOCAL_GIT_DIR=~/deployment-ocs
LOG_DIR="$LOCAL_GIT_DIR/logs"
DEPLOY_LOG="$LOG_DIR/deployment.log"

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; cleanup_on_failure; exit 1; }

# ========== SETUP ==========
mkdir -p "$LOG_DIR"
> "$DEPLOY_LOG"

# Ensure OpenShift Login
log_info "Checking OpenShift login status..."
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift. Please login using 'oc login' and retry."
    exit 1
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
    oc delete ns "$ARGO_NAMESPACE" "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --force --grace-period=0 --ignore-not-found
    log_info "Cleanup complete. Exiting..."
}

# ========== CHECK OPENSHIFT GITOPS OPERATOR ==========
validate_gitops_operator() {
    log_info "Checking if OpenShift GitOps Operator is installed..."
    if ! oc get csv -n openshift-operators | grep -q "openshift-gitops-operator"; then
        log_error "OpenShift GitOps Operator (ArgoCD) is not installed!"
        log_error "Please install the OpenShift GitOps Operator via the OpenShift web console before running this script."
        error_exit "Exiting due to missing required operator."
    fi
    log_info "OpenShift GitOps Operator is installed."
}

# ========== INSTALL ARGOCD ==========
install_argocd() {
    validate_gitops_operator
    log_info "Ensuring ArgoCD namespace exists..."
    oc create ns "$ARGO_NAMESPACE" --dry-run=client -o yaml | oc apply -f - || error_exit "Failed to create namespace: $ARGO_NAMESPACE"
    wait_for_pods "$ARGO_NAMESPACE"
}

# ========== CHECK ARGOCD LOGIN ==========
login_argocd() {
    log_info "Checking if already logged into ArgoCD..."
    if argocd account get-user-info --server "$ARGOCD_SERVER" --grpc-web --insecure &>/dev/null; then
        log_info "Already logged into ArgoCD. Skipping login."
        return
    fi

    log_info "Logging into ArgoCD..."
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    ARGOCD_SERVER=$(oc get routes -n "$ARGO_NAMESPACE" -o jsonpath="{.items[?(@.metadata.name=='openshift-gitops-server')].spec.host}")

    if [[ -z "$ADMIN_PASSWD" || -z "$ARGOCD_SERVER" ]]; then
        error_exit "ArgoCD credentials or route not found. Check installation."
    fi

    if ! argocd login "$ARGOCD_SERVER" --username admin --password "$ADMIN_PASSWD" --insecure --grpc-web; then
        error_exit "Failed to login to ArgoCD."
    fi

    log_info "Successfully logged into ArgoCD."
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
    touch argocd/bootstrap-rbac.yaml
    git add .
    git commit -m "Initialize GitOps configuration"
    git push origin "$GIT_BRANCH" || error_exit "Failed to push changes to GitHub."

    log_info "Git repository successfully updated."
}

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
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

# ========== WAIT FUNCTION ==========
wait_for_pods() {
    local namespace="$1"
    local TIMEOUT=300
    local INTERVAL=10
    local elapsed=0

    while true; do
        RUNNING_COUNT=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Running")
        TOTAL_COUNT=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | wc -l)

        if [[ "$RUNNING_COUNT" -gt 0 && "$RUNNING_COUNT" -eq "$TOTAL_COUNT" ]]; then
            log_info "All pods in $namespace are running."
            break
        fi

        if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
            log_error "Pods in $namespace did not start in time!"
            oc get pods -n "$namespace" | tee -a "$DEPLOY_LOG"
            oc logs --tail=20 -n "$namespace" | tee -a "$DEPLOY_LOG"
            error_exit "Namespace $namespace failed to start."
        fi

        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
        log_info "Waiting for pods in $namespace... ($elapsed/$TIMEOUT seconds elapsed)"
    done
}

# ========== MAIN DEPLOYMENT ==========
validate_gitops_operator
install_argocd
login_argocd
setup_git
create_argocd_apps

log_info "GitOps deployment completed successfully! 🎉"
log_info "Access ArgoCD at: https://$ARGOCD_SERVER"

exit 0
