#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Fully automated Tekton and AWX deployment using GitOps and ArgoCD

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

# ========== DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        command -v "$cmd" &>/dev/null || error_exit "$cmd is missing. Please install it."
    done
    log_info "All dependencies verified."
}

# ========== CLEANUP ==========
cleanup_old_catalogs() {
    log_info "Cleaning old CatalogSources and Subscriptions..."
    oc delete catalogsource awx-catalog tektoncd-catalog -n openshift-marketplace --ignore-not-found
    oc delete subscription tektoncd-operator -n $TEKTON_NAMESPACE --ignore-not-found
    oc delete subscription awx-operator -n $ANSIBLE_NAMESPACE --ignore-not-found
}

cleanup_on_failure() {
    log_error "Deployment failed, performing cleanup..."
    oc delete subscription tektoncd-operator -n $TEKTON_NAMESPACE --ignore-not-found
    oc delete subscription awx-operator -n $ANSIBLE_NAMESPACE --ignore-not-found
    log_info "Cleanup completed."
}

# ========== SETUP ==========
mkdir -p "$LOG_DIR"
> "$DEPLOY_LOG"

[[ -z "$GIT_TOKEN" ]] && error_exit "GIT_TOKEN not set."

log_info "Checking OpenShift login..."
oc whoami &>/dev/null || error_exit "OpenShift login required."
log_info "OpenShift login verified."

cd "$LOCAL_GIT_DIR" || error_exit "Directory $LOCAL_GIT_DIR not found!"

# ========== YAML CREATION ==========
log_info "Creating Tekton Subscription YAML..."
mkdir -p tekton
cat <<EOF > tekton/tekton-pipelines.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tektoncd-operator
  namespace: $TEKTON_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: tektoncd-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

log_info "Creating AWX Subscription YAML..."
mkdir -p awx
cat <<EOF > awx/awx-operator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: awx-operator
  namespace: $ANSIBLE_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: awx-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

# ========== ARGOCD APPS YAML ==========
mkdir -p argocd
log_info "Creating Tekton ArgoCD Application YAML..."
cat <<EOF > argocd/tekton-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-app
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: $GIT_BRANCH
    path: tekton
  destination:
    server: https://kubernetes.default.svc
    namespace: $TEKTON_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

log_info "Creating AWX ArgoCD Application YAML..."
cat <<EOF > argocd/awx-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: awx-app
  namespace: $ARGO_NAMESPACE
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: $GIT_BRANCH
    path: awx
  destination:
    server: https://kubernetes.default.svc
    namespace: $ANSIBLE_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ========== GIT ==========
git add .
git commit -m "Automated Tekton and AWX deployment"
git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"

# ========== NAMESPACE ==========
for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
    oc get ns "$ns" &>/dev/null || oc create ns "$ns"
done

# ========== ARGOCD ==========
argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || true

for app in tekton-app awx-app; do
  argocd app create "$app" \
    --repo "$GIT_REPO" --path "${app%-app}" \
    --dest-server "https://kubernetes.default.svc" \
    --dest-namespace "${app%-app}" \
    --sync-policy automated --upsert

  argocd app sync "$app" --prune --force
done

log_info "Deployment completed successfully."
log_info "Verify Tekton: oc get pods -n $TEKTON_NAMESPACE"
log_info "Verify AWX: oc get pods -n $ANSIBLE_NAMESPACE"

