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

# ========== CLEAN GIT REPO ==========
clean_git_repo() {
    log_info "Cleaning Git repository state..."
    git reset --hard HEAD
    git clean -fd tekton awx argocd || true
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

# ========== CREATE DIRECTORIES ==========
create_directories() {
    log_info "Creating required directories..."
    mkdir -p "$LOCAL_GIT_DIR"/{argocd,tekton,awx,logs}
    log_info "Directories created."
}

# ========== CREATE YAML FILES (INCLUDING WORKLOADS) ==========
create_yaml_files() {
    log_info "Creating required YAML files..."

    # Tekton Application
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

    # AWX Application
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

    # TektonPipeline Custom Resource
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/tekton-pipeline.yaml"
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonPipeline
metadata:
  name: pipeline
  namespace: $TEKTON_NAMESPACE
EOF

    # AWX Instance Custom Resource
    cat <<EOF > "$LOCAL_GIT_DIR/awx/awx-instance.yaml"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-instance
  namespace: $ANSIBLE_NAMESPACE
EOF

    log_info "YAML files created."
}

# ========== SETUP RBAC (RESTORED TO WORKING STATE) ==========
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
    log_info "Syncing ArgoCD app: $app..."
    argocd app sync "$app" --force || error_exit "$app sync failed."
}

# ========== MAIN EXECUTION FLOW ==========
check_dependencies
verify_argocd
create_directories
create_yaml_files
commit_git
setup_rbac
sync_argocd_app "tekton-app"
sync_argocd_app "awx-app"

log_info "✅ Deployment complete!"
