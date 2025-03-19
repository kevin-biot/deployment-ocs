#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Configures GitOps workflow using existing ArgoCD installation
# - Verifies ArgoCD (OpenShift GitOps)
# - Deploys Tekton Pipelines
# - Deploys AWX Operator
# Ensures proper logging, error handling, and cleanup on failure.

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
GIT_TOKEN="${GIT_TOKEN:-}" # Expect token to be set as environment variable

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
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

if [[ -z "$GIT_TOKEN" ]]; then
    error_exit "GIT_TOKEN environment variable not set. Please set it before running the script."
fi

log_info "Checking OpenShift login status..."
if ! oc whoami &>/dev/null; then
    log_info "Logging in to OpenShift..."
    oc login -u kubeadmin || error_exit "OpenShift login failed!"
fi
log_info "OpenShift login verified."

if [[ ! -d "$LOCAL_GIT_DIR" ]]; then
    error_exit "Expected script to be run in $LOCAL_GIT_DIR, but it is missing!"
fi
log_info "Correct directory detected."

# ========== CLEANUP FUNCTION ==========
cleanup_on_failure() {
    log_info "Cleaning up due to failure..."
    read -t 30 -p "Proceed with forced cleanup of namespaces? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete ns "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" --force --grace-period=0 --ignore-not-found
        log_info "Cleanup complete."
    else
        log_info "Cleanup skipped by user request."
    fi
}

# ========== WAIT FUNCTION ==========
wait_for_pods() {
    local namespace="$1"
    local TIMEOUT=300
    local INTERVAL=10
    local RETRIES=3
    local attempt=1

    while [ $attempt -le $RETRIES ]; do
        local elapsed=0
        log_info "Attempt $attempt of $RETRIES: Waiting for pods in $namespace..."
        while true; do
            RUNNING_COUNT=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Running")
            TOTAL_COUNT=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | wc -l)
            if [[ "$RUNNING_COUNT" -gt 0 && "$RUNNING_COUNT" -eq "$TOTAL_COUNT" ]]; then
                log_info "All pods in $namespace are running."
                return 0
            fi
            if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
                log_error "Attempt $attempt: Pods in $namespace did not start within $TIMEOUT seconds"
                break
            fi
            sleep "$INTERVAL"
            elapsed=$((elapsed + INTERVAL))
            log_info "Waiting for pods in $namespace... ($elapsed/$TIMEOUT seconds elapsed)"
        done
        if [ $attempt -eq $RETRIES ]; then
            error_exit "Failed to start pods in $namespace after $RETRIES attempts"
        fi
        ((attempt++))
        sleep 5
    done
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
    if [[ ! -d "$LOCAL_GIT_DIR/.git" ]]; then
        log_info "Initializing new Git repository..."
        git -C "$LOCAL_GIT_DIR" init
        git -C "$LOCAL_GIT_DIR" remote add origin "$GIT_REPO"
        git -C "$LOCAL_GIT_DIR" branch -M "$GIT_BRANCH"
    fi

    log_info "Ensuring repo contains necessary files..."
    mkdir -p "$LOCAL_GIT_DIR/argocd"

    # Tekton Application YAML
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

    # AWX Application YAML
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

    # Add basic manifests if directories don’t exist
    mkdir -p "$LOCAL_GIT_DIR/tekton" "$LOCAL_GIT_DIR/awx"
    if [[ ! -f "$LOCAL_GIT_DIR/tekton/tekton-pipelines.yaml" ]]; then
        cat <<EOF > "$LOCAL_GIT_DIR/tekton/tekton-pipelines.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: $TEKTON_NAMESPACE
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    fi

    if [[ ! -f "$LOCAL_GIT_DIR/awx/awx-operator.yaml" ]]; then
        cat <<EOF > "$LOCAL_GIT_DIR/awx/awx-operator.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: awx-operator
  namespace: $ANSIBLE_NAMESPACE
spec:
  channel: alpha
  name: awx-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
    fi

    git -C "$LOCAL_GIT_DIR" add .
    git -C "$LOCAL_GIT_DIR" commit -m "Initialize GitOps configuration for Tekton and AWX" || true
    git -C "$LOCAL_GIT_DIR" push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH" || error_exit "Failed to push changes to GitHub."
    log_info "Git repository successfully updated."
}

# ========== VALIDATE AND CREATE NAMESPACES ==========
validate_and_create_namespaces() {
    log_info "Validating and ensuring target namespaces exist..."

    # Check and create Tekton namespace
    if oc get ns "$TEKTON_NAMESPACE" &>/dev/null; then
        log_info "Namespace $TEKTON_NAMESPACE already exists."
    else
        log_info "Namespace $TEKTON_NAMESPACE not found, creating it..."
        oc create namespace "$TEKTON_NAMESPACE" --dry-run=client -o yaml | oc apply -f - || error_exit "Failed to create namespace $TEKTON_NAMESPACE."
        log_info "Namespace $TEKTON_NAMESPACE created successfully."
    fi

    # Check and create AWX namespace
    if oc get ns "$ANSIBLE_NAMESPACE" &>/dev/null; then
        log_info "Namespace $ANSIBLE_NAMESPACE already exists."
    else
        log_info "Namespace $ANSIBLE_NAMESPACE not found, creating it..."
        oc create namespace "$ANSIBLE_NAMESPACE" --dry-run=client -o yaml | oc apply -f - || error_exit "Failed to create namespace $ANSIBLE_NAMESPACE."
        log_info "Namespace $ANSIBLE_NAMESPACE created successfully."
    fi

    log_info "Namespace validation and setup complete."
}

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    log_info "Registering Git repository in ArgoCD..."
    argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || error_exit "Failed to add Git repo."

    log_info "Checking if Tekton and AWX ArgoCD applications exist..."
    if ! argocd app get tekton-app &>/dev/null; then
        log_info "Creating Tekton ArgoCD application..."
        argocd app create tekton-app --upsert \
          --repo "$GIT_REPO" --path "tekton" \
          --dest-server "https://kubernetes.default.svc" --dest-namespace "$TEKTON_NAMESPACE" \
          --sync-policy automated || error_exit "Failed to create Tekton application."
    else
        log_info "Tekton application already exists."
    fi

    if ! argocd app get awx-app &>/dev/null; then
        log_info "Creating AWX ArgoCD application..."
        argocd app create awx-app --upsert \
          --repo "$GIT_REPO" --path "awx" \
          --dest-server "https://kubernetes.default.svc" --dest-namespace "$ANSIBLE_NAMESPACE" \
          --sync-policy automated || error_exit "Failed to create AWX application."
    else
        log_info "AWX application already exists."
    fi

    log_info "Syncing ArgoCD applications..."
    argocd app sync tekton-app --timeout 300 || error_exit "Failed to sync Tekton application."
    argocd app sync awx-app --timeout 300 || error_exit "Failed to sync AWX application."

    log_info "Waiting for Tekton deployment..."
    wait_for_pods "$TEKTON_NAMESPACE"
    log_info "Waiting for AWX deployment..."
    wait_for_pods "$ANSIBLE_NAMESPACE"
}

# ========== MAIN DEPLOYMENT ==========
check_dependencies
verify_gitops
login_argocd
setup_git
validate_and_create_namespaces  # Updated function name
create_argocd_apps

TEKTON_URL=$(oc get routes -n "$TEKTON_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")
AWX_URL=$(oc get routes -n "$ANSIBLE_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")

log_info "✅ GitOps deployment completed successfully!"
log_info "📌 ArgoCD UI: https://$SERVER_URL"
if [[ "$TEKTON_URL" != "Not Available" ]]; then
    log_info "📌 Tekton UI: https://$TEKTON_URL"
else
    log_error "⚠️ Tekton URL not found. Deployment might have failed."
fi
if [[ "$AWX_URL" != "Not Available" ]]; then
    log_info "📌 AWX UI: https://$AWX_URL"
else
    log_error "⚠️ AWX URL not found. Deployment might have failed."
fi
