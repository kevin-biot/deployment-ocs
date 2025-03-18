#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Deploys & manages:
# - ArgoCD (via OpenShift GitOps Operator)
# - Tekton Pipelines
# - AWX Operator
# Uses GitOps principles for state management via GitHub.

# ========== CONFIGURATION ==========
GIT_USERNAME="kevin-biot"
GIT_REPO="https://github.com/$GIT_USERNAME/deployment-ocs.git"
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

# ========== CLEANUP FUNCTION ==========
cleanup_on_failure() {
    log_info "Cleaning up due to failure..."
    oc delete ns "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --force --grace-period=0 --ignore-not-found
    log_info "Cleanup complete. Exiting..."
}

# ========== CHECK ENVIRONMENT ==========
check_oc_logged_in() {
    log_info "Checking OpenShift login status..."
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift! Please login and re-run the script."
        exit 1
    fi
    log_info "OpenShift login verified."
}

validate_argocd_operator() {
    log_info "Checking if ArgoCD Operator is installed..."
    if ! oc get deployment -n "$ARGO_NAMESPACE" -o name | grep -q "openshift-gitops"; then
        error_exit "ArgoCD Operator is not installed! Please install it via OpenShift Operator Hub."
    fi
    log_info "ArgoCD Operator is installed and running."
}

validate_local_directory() {
    log_info "Checking if script is running in correct directory..."
    if [[ "$(pwd)" != "$LOCAL_GIT_DIR" ]]; then
        error_exit "Script must be run from $LOCAL_GIT_DIR! Change directory and re-run."
    fi
    log_info "Correct directory detected."
}

# ========== SETUP GITOPS REPO ==========
setup_git_repo() {
    log_info "Setting up Git repository..."
    
    if [[ ! -d "$LOCAL_GIT_DIR/.git" ]]; then
        log_info "Initializing local Git repository..."
        git init
        git remote add origin "$GIT_REPO"
        git checkout -b "$GIT_BRANCH"
    fi

    log_info "Ensuring repo contains necessary files..."
    mkdir -p "$LOCAL_GIT_DIR/argocd/rbac" "$LOCAL_GIT_DIR/openshift/tekton" "$LOCAL_GIT_DIR/openshift/ansible"

    # Ensure RBAC, Tekton, AWX YAML files exist
    cat <<EOF > "$LOCAL_GIT_DIR/argocd/bootstrap-rbac.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-rbac-bootstrap
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: '$GIT_REPO'
    path: argocd/rbac
    targetRevision: $GIT_BRANCH
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: $ARGO_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    # Ensure files are committed
    git add .
    git commit -m "Initialize GitOps configuration"
    git push -u origin "$GIT_BRANCH" || error_exit "Failed to push to GitHub."
    log_info "Git repository successfully updated."
}

# ========== SETUP ARGOCD REPO ==========
setup_argocd_repo() {
    log_info "Configuring ArgoCD repository..."

    ADMIN_PASSWD=$(oc get secret -n "$ARGO_NAMESPACE" argocd-secret -o jsonpath='{.data.admin\.password}' | base64 -d)
    SERVER_URL=$(oc get routes openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.status.ingress[0].host}')

    argocd login "$SERVER_URL" --username admin --password "$ADMIN_PASSWD" --insecure --grpc-web || error_exit "Failed to login to ArgoCD."

    if argocd repo list | grep -q "$GIT_REPO"; then
        log_info "Git repository is already registered in ArgoCD."
    else
        argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GITHUB_TOKEN" || error_exit "Failed to add Git repo."
    fi
}

# ========== DEPLOY ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    log_info "Creating ArgoCD applications from GitHub..."

    argocd app create tekton-app --upsert \
      --repo "$GIT_REPO" --path "openshift/tekton" \
      --dest-server "https://kubernetes.default.svc" --dest-namespace "$TEKTON_NAMESPACE" \
      --sync-policy automated || error_exit "Failed to create Tekton application."

    argocd app create awx-app --upsert \
      --repo "$GIT_REPO" --path "openshift/ansible" \
      --dest-server "https://kubernetes.default.svc" --dest-namespace "$ANSIBLE_NAMESPACE" \
      --sync-policy automated || error_exit "Failed to create AWX application."

    log_info "ArgoCD applications created successfully."
}

# ========== SETUP ROUTES ==========
setup_routes() {
    log_info "Creating OpenShift routes for web interfaces..."
    oc expose svc/openshift-gitops-server -n "$ARGO_NAMESPACE" --hostname=argocd.apps-crc.testing
    oc expose svc/tekton-dashboard -n "$TEKTON_NAMESPACE" --hostname=tekton.apps-crc.testing
    oc expose svc/awx-service -n "$ANSIBLE_NAMESPACE" --hostname=ansible.apps-crc.testing
    log_info "Routes created successfully."
}

# ========== DISPLAY FINAL INFO ==========
final_summary() {
    echo -e "\n[INFO] Deployment complete! Access your services:"
    echo "ArgoCD:   https://argocd.apps-crc.testing"
    echo "Tekton:   https://tekton.apps-crc.testing"
    echo "AWX:      https://ansible.apps-crc.testing"
    echo "ArgoCD Login: admin / $(oc get secret -n $ARGO_NAMESPACE argocd-secret -o jsonpath='{.data.admin\.password}' | base64 -d)"
}

# ========== EXECUTION ==========
check_oc_logged_in
validate_local_directory
validate_argocd_operator
setup_git_repo
setup_argocd_repo
create_argocd_apps
setup_routes
final_summary

log_info "GitOps deployment completed successfully! 🚀"
