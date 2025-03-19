#!/bin/bash

set -euo pipefail

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
        command -v "$cmd" >/dev/null || error_exit "Missing $cmd, please install."
    done
    log_info "Dependencies verified."
}

# ========== VERIFY OPENSHIFT LOGIN ==========
verify_oc_login() {
    log_info "Verifying OpenShift login..."
    oc whoami >/dev/null || error_exit "Not logged into OpenShift."
    log_info "OpenShift login verified."
}

# ========== VERIFY ARGOCD ==========
verify_argocd() {
    log_info "Verifying ArgoCD..."
    oc wait --for=condition=ready pod -l app.kubernetes.io/name=openshift-gitops-server -n "$ARGO_NAMESPACE" --timeout=600s
    log_info "ArgoCD verified."
}

# ========== ENSURE REQUIRED NAMESPACES EXIST ==========
ensure_namespaces() {
    log_info "Ensuring required namespaces exist..."
    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        if ! oc get ns "$ns" >/dev/null 2>&1; then
            log_info "Creating namespace: $ns"
            oc create ns "$ns"
        else
            log_info "Namespace $ns already exists."
        fi
    done
    log_info "All required namespaces verified."
}

# ========== CREATE REQUIRED YAML FILES ==========
create_yaml_files() {
    log_info "Creating required YAML files..."

    # Define Tekton ArgoCD app
    cat <<EOF > "$LOCAL_GIT_DIR/argocd/tekton-app.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-app
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    path: tekton
    targetRevision: $GIT_BRANCH
  destination:
    server: https://kubernetes.default.svc
    namespace: $TEKTON_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    # Define AWX ArgoCD app
    cat <<EOF > "$LOCAL_GIT_DIR/argocd/awx-app.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: awx-app
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    path: awx
    targetRevision: $GIT_BRANCH
  destination:
    server: https://kubernetes.default.svc
    namespace: $ANSIBLE_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    log_info "YAML files created."
}

# ========== COMMIT TO GIT ==========
commit_git() {
    log_info "Committing and pushing YAML files to Git..."
    cd "$LOCAL_GIT_DIR"
    git add .
    git commit -m "Automated deployment commit"
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
    log_info "Changes pushed."
}

# ========== SETUP RBAC ROLEBINDING ==========
setup_rbac() {
    log_info "Setting up RBAC for ArgoCD service account..."
    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        oc create rolebinding "argocd-admin-${ns}" \
            --clusterrole=admin \
            --serviceaccount="$ARGO_NAMESPACE:openshift-gitops-argocd-application-controller" \
            -n "$ns" --dry-run=client -o yaml | oc apply -f - || error_exit "Failed to bind role in namespace: $ns."
    done
    log_info "RBAC RoleBindings configured."
}

# ========== SYNC ARGOCD APP ==========
sync_argocd_app() {
    local app="$1"
    local attempt=1
    while [ $attempt -le 3 ]; do
        log_info "Syncing ArgoCD app: $app (Attempt $attempt)..."
        if argocd app sync "$app" --force; then
            log_info "$app synced successfully."
            return
        else
            log_error "$app sync failed on attempt $attempt."
        fi
        sleep 10
        attempt=$((attempt+1))
    done
    error_exit "$app failed to sync after 3 attempts."
}

# ========== MAIN EXECUTION FLOW ==========
check_dependencies
verify_oc_login
verify_argocd
ensure_namespaces
create_yaml_files
commit_git     # Ensure changes are pushed before ArgoCD syncs
setup_rbac     # Ensures ArgoCD has correct admin permissions

sync_argocd_app "tekton-app"
sync_argocd_app "awx-app"

log_info "✅ Deployment complete!"
