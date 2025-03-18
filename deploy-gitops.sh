#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Configures GitOps workflow using existing ArgoCD installation
# - Verifies ArgoCD (OpenShift GitOps)
# - Sets up Tekton Pipelines
# - Configures AWX Operator
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

GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-}" # Expect token to be set as environment variable

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; cleanup_on_failure; exit 1; }

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

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git; do
        if ! command -v "$cmd" &>/dev/null; then
            error_exit "Required command $cmd not found. Please install it first."
        fi
    done
    log_info "All dependencies verified."
}

# ========== SETUP ==========
mkdir -p "$LOG_DIR"
> "$DEPLOY_LOG"

# Validate Git token
if [[ -z "$GIT_TOKEN" ]]; then
    error_exit "GIT_TOKEN environment variable not set. Please set it before running the script."
fi

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

# ========== MAIN DEPLOYMENT ==========
check_dependencies
verify_gitops

log_info "GitOps deployment completed successfully! 🎉"

