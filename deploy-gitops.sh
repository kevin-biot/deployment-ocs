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

# User credentials (Prompt if not set)
GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-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}"

if [[ -z "$GIT_TOKEN" || -z "$GIT_USERNAME" ]]; then
    read -p "Enter GitHub Username: " GIT_USERNAME
    read -s -p "Enter GitHub Personal Access Token (PAT): " GIT_TOKEN
    echo ""
fi

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
    if argocd account get-user &>/dev/null; then
        log_info "Already logged into ArgoCD. Skipping login."
        return
    fi

    log_info "Logging into ArgoCD..."
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    SERVER_URL=$(oc get routes openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.status.ingress[0].host}')

    if [[ -z "$ADMIN_PASSWD" || -z "$SERVER_URL" ]]; then
        error_exit "ArgoCD credentials or route not found. Check installation."
    fi

    argocd login "$SERVER_URL" --username admin --password "$ADMIN_PASSWD" --insecure --grpc-web || error_exit "Failed to login to ArgoCD."
}

# ========== CONFIGURE GIT REPO & REGISTER IN ARGOCD ==========
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
    git push https://"$GIT_USERNAME":"$GIT_TOKEN"@github.com/kevin-biot/deployment-ocs.git "$GIT_BRANCH" || error_exit "Failed to push changes to GitHub."

    log_info "Git repository successfully updated."

    # Add repository to ArgoCD
    log_info "Registering Git repository in ArgoCD..."
    if argocd repo list | grep -q "$GIT_REPO"; then
        log_info "Git repository is already registered in ArgoCD."
    else
        argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || error_exit "Failed to add Git repository to ArgoCD."
    fi
}

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    log_info "Checking if ArgoCD has access to Git repository..."
    
    if ! argocd repo list | grep -q "$GIT_REPO"; then
        log_error "ArgoCD does not have access to the Git repository!"
        log_error "Please add the repository using a personal access token or SSH key."
        error_exit "Repository authentication required."
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

# ========== DISPLAY ACCESS URLS ==========
display_urls() {
    log_info "ArgoCD Web UI: https://$(oc get route -n openshift-gitops openshift-gitops-server -o jsonpath='{.spec.host}')"
    log_info "Tekton Dashboard: https://$(oc get route -n $TEKTON_NAMESPACE tekton-dashboard -o jsonpath='{.spec.host}')"
    log_info "AWX Web UI: https://$(oc get route -n $ANSIBLE_NAMESPACE awx-service -o jsonpath='{.spec.host}')"
}

# ========== MAIN DEPLOYMENT ==========
validate_gitops_operator
install_argocd
login_argocd
setup_git
create_argocd_apps
display_urls

log_info "GitOps deployment completed successfully! 🎉"
