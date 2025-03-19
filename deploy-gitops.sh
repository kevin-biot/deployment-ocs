#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Deploys a CI/CD environment using open-source Tekton and AWX operators
# Follows GitOps principles: declarative, automated, repeatable via Git and ArgoCD

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

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        if ! command -v "$cmd" &>/dev/null; then
            error_exit "Missing required command: $cmd. Please install it."
        fi
    done
    log_info "All dependencies verified."
}

# ========== CLEANUP OLD CATALOGSOURCES ==========
cleanup_old_catalogs() {
    log_info "Cleaning up old CatalogSources for a known state..."
    for catalog in "awx-catalog" "tektoncd-catalog"; do
        if oc get catalogsource "$catalog" -n openshift-marketplace &>/dev/null; then
            log_info "Found $catalog in openshift-marketplace, deleting..."
            oc delete catalogsource "$catalog" -n openshift-marketplace --force --grace-period=0 || log_error "Failed to delete $catalog, continuing..."
        else
            log_info "$catalog not found in openshift-marketplace, skipping deletion."
        fi
    done
    log_info "Old CatalogSource cleanup complete."
}

# ========== SETUP ==========
mkdir -p "$LOG_DIR"
> "$DEPLOY_LOG"

if [[ -z "$GIT_TOKEN" ]]; then
    error_exit "GIT_TOKEN environment variable not set. Please set it."
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
cd "$LOCAL_GIT_DIR"
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
    local TIMEOUT=600  # 10 minutes for CRC
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
        error_exit "ArgoCD namespace $ARGO_NAMESPACE not found. Ensure OpenShift GitOps operator is installed."
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
        git init
        git remote add origin "$GIT_REPO"
        git branch -M "$GIT_BRANCH"
    fi

    log_info "Ensuring repo contains necessary files..."
    mkdir -p "$LOCAL_GIT_DIR/argocd" "$LOCAL_GIT_DIR/tekton" "$LOCAL_GIT_DIR/awx"

    # Tekton Application YAML
    log_info "Creating tekton-app.yaml..."
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
    log_info "Creating awx-app.yaml..."
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

    # Shared Community CatalogSource
    log_info "Creating tekton/catalogsource.yaml..."
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/catalogsource.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: community-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/operatorhubio/catalog:latest
  displayName: Community OperatorHub Catalog
  publisher: OperatorHub.io
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

    # Tekton OperatorGroup
    log_info "Creating tekton/operatorgroup.yaml..."
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/operatorgroup.yaml"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: tekton-operator-group
  namespace: $TEKTON_NAMESPACE
spec:
  targetNamespaces:
  - $TEKTON_NAMESPACE
EOF

    # Tekton Subscription
    log_info "Creating tekton/tekton-pipelines.yaml..."
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/tekton-pipelines.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tekton-operator
  namespace: $TEKTON_NAMESPACE
spec:
  channel: stable
  name: tekton-operator
  source: community-catalog
  sourceNamespace: openshift-marketplace
EOF

    # AWX OperatorGroup
    log_info "Creating awx/operatorgroup.yaml..."
    cat <<EOF > "$LOCAL_GIT_DIR/awx/operatorgroup.yaml"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: awx-operator-group
  namespace: $ANSIBLE_NAMESPACE
spec:
  targetNamespaces:
  - $ANSIBLE_NAMESPACE
EOF

    # AWX Subscription
    log_info "Creating awx/awx-operator.yaml..."
    cat <<EOF > "$LOCAL_GIT_DIR/awx/awx-operator.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: awx-operator
  namespace: $ANSIBLE_NAMESPACE
spec:
  channel: stable
  name: awx-operator
  source: community-catalog
  sourceNamespace: openshift-marketplace
EOF

    # Verify files exist
    log_info "Verifying local files..."
    for file in "$LOCAL_GIT_DIR/tekton/catalogsource.yaml" "$LOCAL_GIT_DIR/tekton/operatorgroup.yaml" "$LOCAL_GIT_DIR/tekton/tekton-pipelines.yaml" "$LOCAL_GIT_DIR/awx/operatorgroup.yaml" "$LOCAL_GIT_DIR/awx/awx-operator.yaml"; do
        if [[ ! -f "$file" ]]; then
            error_exit "File $file was not created successfully."
        else
            log_info "Confirmed $file exists."
        fi
    done

    # Force commit and push
    log_info "Committing changes to Git..."
    git add .
    git commit -m "Deploy CI/CD env with resilient cleanup and OperatorHub.io catalog" || log_info "No changes to commit."
    log_info "Pushing to GitHub..."
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH" --force || error_exit "Failed to push changes to GitHub."
    log_info "Git repository successfully updated."
}

# ========== VALIDATE AND CREATE NAMESPACES ==========
validate_and_create_namespaces() {
    log_info "Validating and ensuring target namespaces exist..."
    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        if oc get ns "$ns" &>/dev/null; then
            log_info "Namespace $ns already exists."
        else
            log_info "Creating namespace $ns..."
            oc create namespace "$ns" || error_exit "Failed to create namespace $ns."
        fi
    done
    log_info "Namespace setup complete."
}

# ========== SYNC ARGOCD APPLICATION ==========
sync_argocd_app() {
    local app_name="$1"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Syncing $app_name (Attempt $attempt of $max_attempts)..."
        if argocd app sync "$app_name" --prune --force; then
            log_info "$app_name synced successfully."
            return 0
        else
            log_error "Failed to sync $app_name on attempt $attempt."
            if [ $attempt -eq $max_attempts ]; then
                error_exit "Failed to sync $app_name after $max_attempts attempts."
            fi
            sleep 10
            ((attempt++))
        fi
    done
}

# ========== CREATE ARGOCD APPLICATIONS ==========
create_argocd_apps() {
    log_info "Registering Git repository in ArgoCD..."
    argocd repo add "$GIT_REPO" --username "$GIT_USERNAME" --password "$GIT_TOKEN" || error_exit "Failed to add Git repo."

    log_info "Checking if ArgoCD applications exist..."
    for app in "tekton-app" "awx-app"; do
        if ! argocd app get "$app" &>/dev/null; then
            log_info "Creating $app ArgoCD application..."
            argocd app create "$app" --upsert \
              --repo "$GIT_REPO" --path "${app%-app}" \
              --dest-server "https://kubernetes.default.svc" --dest-namespace "${app%-app}" \
              --sync-policy automated || error_exit "Failed to create $app application."
        else
            log_info "$app application already exists."
        fi
    done

    log_info "Syncing ArgoCD applications..."
    sync_argocd_app "tekton-app"
    sync_argocd_app "awx-app"

    log_info "Waiting for Tekton deployment..."
    wait_for_pods "$TEKTON_NAMESPACE"
    log_info "Waiting for AWX deployment..."
    wait_for_pods "$ANSIBLE_NAMESPACE"
}

# ========== MAIN DEPLOYMENT ==========
check_dependencies
cleanup_old_catalogs  # Added cleanup step here
verify_gitops
login_argocd
setup_git
validate_and_create_namespaces
create_argocd_apps

TEKTON_URL=$(oc get routes -n "$TEKTON_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")
AWX_URL=$(oc get routes -n "$ANSIBLE_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")

log_info "✅ GitOps CI/CD deployment completed successfully!"
log_info "📌 ArgoCD UI: https://$SERVER_URL"
log_info "📌 Tekton UI: ${TEKTON_URL:+https://$TEKTON_URL} (Not Available if no route)"
log_info "📌 AWX UI: ${AWX_URL:+https://$AWX_URL} (Not Available if no route)"
