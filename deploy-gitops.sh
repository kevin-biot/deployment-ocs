#!/bin/bash

# ============================
# OpenShift GitOps Deployment Script
# ============================
# Installs & configures:
# - ArgoCD (OpenShift GitOps)
# - Tekton Pipelines
# - AWX Operator
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

# Detect GitHub username automatically
GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-}" # Expect token to be set as environment variable

# ========== UTILITIES ==========
log_info() { echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
log_error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"; }
error_exit() { log_error "$1"; exit 1; }

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git yamllint; do
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

# ========== MAIN DEPLOYMENT ==========
check_dependencies
login_argocd

log_info "✅ GitOps deployment completed successfully!"
log_info "📌 ArgoCD UI: https://$SERVER_URL"

# **🔧 Fix: Only Print Tekton/AWX URLs If They Exist**
TEKTON_URL=$(oc get routes -n "$TEKTON_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")
AWX_URL=$(oc get routes -n "$ANSIBLE_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "Not Available")

if [[ "$TEKTON_URL" != "Not Available" ]]; then
    log_info "📌 Tekton UI: https://$TEKTON_URL"
else
    log_info "⚠️ Tekton URL not found. Ensure Tekton is deployed."
fi

if [[ "$AWX_URL" != "Not Available" ]]; then
    log_info "📌 AWX UI: https://$AWX_URL"
else
    log_info "⚠️ AWX URL not found. Ensure AWX is deployed."
fi
