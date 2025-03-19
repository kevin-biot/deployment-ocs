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

# ========== LOGIN TO ARGOCD ==========
login_argocd() {
    log_info "Logging into ArgoCD CLI..."
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    ARGO_SERVER=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
    argocd login "$ARGO_SERVER" --username admin --password "$ADMIN_PASSWD" --grpc-web --insecure
    log_info "Logged into ArgoCD CLI."
}

# ========== ENSURE ARGOCD GIT CREDENTIALS ==========
ensure_argocd_git_credentials() {
    log_info "Ensuring ArgoCD has Git credentials..."
    if ! argocd repo list | grep -q "$GIT_REPO"; then
        [[ -z "$GIT_TOKEN" ]] && error_exit "GIT_TOKEN not set. Set it and re-run."
        argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN"
        log_info "ArgoCD Git credentials configured."
    else
        log_info "ArgoCD Git credentials already configured."
    fi
}

# ========== ENSURE REQUIRED NAMESPACES ==========
ensure_namespaces() {
    log_info "Ensuring required namespaces exist..."
    oc create ns "$TEKTON_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
    oc create ns "$ANSIBLE_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
    log_info "Namespaces created/verified."
}

# ========== CREATE OPERATORGROUPS ==========
create_operatorgroups() {
    log_info "Ensuring OperatorGroups exist..."
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: pipelines-operator-group
  namespace: openshift-pipelines
spec:
  targetNamespaces:
    - openshift-pipelines
EOF

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: awx-operator-group
  namespace: awx
spec:
  targetNamespaces:
    - awx
EOF

    log_info "OperatorGroups created/verified."
}

# ========== SETUP RBAC ==========
setup_rbac() {
    log_info "Setting up RBAC for ArgoCD service account..."
    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        oc create rolebinding "argocd-admin-${ns}" \
            --clusterrole=admin \
            --serviceaccount="$ARGO_NAMESPACE:openshift-gitops-argocd-application-controller" \
            -n "$ns" --dry-run=client -o yaml | oc apply -f -
    done
    log_info "RBAC RoleBindings configured."
}

# ========== GIT COMMIT ==========
commit_git() {
    log_info "Committing and pushing YAML files..."
    cd "$LOCAL_GIT_DIR"
    git add .
    git commit -m "Automated deployment commit"
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
    log_info "Changes pushed."
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
login_argocd
ensure_argocd_git_credentials
ensure_namespaces
create_operatorgroups
setup_rbac
commit_git

# Sync ArgoCD Apps
sync_argocd_app "tekton-app"
sync_argocd_app "awx-app"

log_info "✅ Deployment complete!"
ARGO_SERVER=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
log_info "📌 ArgoCD UI: https://$ARGO_SERVER"
log_info "🔑 ArgoCD Admin Password: (get using oc CLI:)"
log_info "  oc get secret openshift-gitops-cluster -n $ARGO_NAMESPACE -o jsonpath='{.data.admin\.password}' | base64 -d"
