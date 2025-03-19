#!/bin/bash

set -euo pipefail

# Configuration
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

# Utilities
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

# Ensure dependencies exist
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        command -v "$cmd" >/dev/null || error_exit "Missing $cmd, please install."
    done
    log_info "Dependencies verified."
}

# Verify OpenShift login
verify_oc_login() {
    log_info "Verifying OpenShift login..."
    oc whoami >/dev/null || error_exit "Not logged into OpenShift."
    log_info "OpenShift login verified."
}

# Verify ArgoCD
verify_argocd() {
    log_info "Verifying ArgoCD..."
    oc wait --for=condition=ready pod -l app.kubernetes.io/name=openshift-gitops-server -n "$ARGO_NAMESPACE" --timeout=600s
    log_info "ArgoCD verified."
}

# Login to ArgoCD
login_argocd() {
    log_info "Logging into ArgoCD CLI..."
    ADMIN_PASSWD=$(oc get secret openshift-gitops-cluster -n "$ARGO_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)
    ARGO_SERVER=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
    argocd login "$ARGO_SERVER" --username admin --password "$ADMIN_PASSWD" --grpc-web --insecure
    log_info "Logged into ArgoCD CLI."
}

# Ensure ArgoCD has Git credentials
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

# Ensure required namespaces exist
ensure_namespaces() {
    log_info "Ensuring required namespaces exist..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $TEKTON_NAMESPACE
EOF
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ANSIBLE_NAMESPACE
EOF
    log_info "Namespaces created/verified."
}

# Create required OperatorGroups
ensure_operator_groups() {
    log_info "Ensuring OperatorGroups exist..."
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: pipelines-operator-group
  namespace: $TEKTON_NAMESPACE
spec: {}
EOF

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: awx-operator-group
  namespace: $ANSIBLE_NAMESPACE
spec: {}
EOF
    log_info "OperatorGroups created/verified."
}

# Restart Operator Lifecycle Manager (OLM)
restart_olm() {
    log_info "Restarting Operator Lifecycle Manager..."
    oc delete pod -n openshift-operator-lifecycle-manager --all --ignore-not-found
    log_info "OLM restarted."
}

# Commit changes to Git (ONLY way ArgoCD should apply changes)
commit_git() {
    log_info "Committing and pushing YAML files..."
    cd "$LOCAL_GIT_DIR"
    git add .
    git commit -m "Automated deployment commit"
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
    log_info "Changes pushed."
}

# ArgoCD sync apps (NO YAML APPLY—ONLY TRIGGERS SYNC)
sync_argocd_app() {
    local app="$1"
    log_info "Syncing ArgoCD app: $app..."
    argocd app sync "$app" --force
    log_info "$app synced successfully."
}

# Main script execution
check_dependencies
verify_oc_login
verify_argocd
login_argocd
ensure_argocd_git_credentials
ensure_namespaces
ensure_operator_groups
restart_olm
commit_git
sync_argocd_app "tekton-app"
sync_argocd_app "awx-app"

log_info "✅ Deployment complete!"
ARGO_SERVER=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
log_info "📌 ArgoCD UI: https://$ARGO_SERVER"
log_info "🔑 ArgoCD Admin Password: (use oc CLI)"
log_info "  oc get secret openshift-gitops-cluster -n $ARGO_NAMESPACE -o jsonpath='{.data.admin\.password}' | base64 -d"
