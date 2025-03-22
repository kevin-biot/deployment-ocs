#!/bin/bash

set -euo pipefail

# ========== CONFIGURATION ==========
GIT_REPO="https://github.com/kevin-biot/deployment-ocs.git"
GIT_BRANCH="main"
ARGO_NAMESPACE="openshift-gitops"

# Namespaces for operator installation and runtime
TEKTON_OPERATOR_NAMESPACE="openshift-operators"  # Where OLM installs the operator
TEKTON_NAMESPACE="openshift-pipelines"          # Where pipelines run
ANSIBLE_NAMESPACE="awx"

LOCAL_GIT_DIR=~/deployment-ocs
LOG_DIR="$LOCAL_GIT_DIR/logs"
DEPLOY_LOG="$LOG_DIR/deployment.log"

GIT_USERNAME="${GIT_USERNAME:-kevin-biot}"
GIT_TOKEN="${GIT_TOKEN:-}"

# Variables per Red Hat documentation:
TEKTON_OPERATOR_PACKAGE="openshift-pipelines-operator-rh"
TEKTON_OPERATOR_CHANNEL="pipelines-1.18"
TEKTON_OPERATOR_STARTINGCSV="openshift-pipelines-operator-rh.v1.18.0"

# ========== UTILITIES ==========
log_info() {
    echo -e "\e[32m[INFO] $1\e[0m" | tee -a "$DEPLOY_LOG"
}
log_error() {
    echo -e "\e[31m[ERROR] $1\e[0m" | tee -a "$DEPLOY_LOG"
}
error_exit() {
    log_error "$1"
    exit 1
}

# ========== CHECK DEPENDENCIES ==========
check_dependencies() {
    log_info "Checking dependencies..."
    for cmd in oc argocd git jq; do
        command -v "$cmd" >/dev/null || error_exit "Missing $cmd, please install."
    done
    log_info "Dependencies verified."
}

# ========== ENSURE NAMESPACE EXISTS ==========
ensure_namespace() {
    local ns="$1"
    if ! oc get namespace "$ns" >/dev/null 2>&1; then
        log_info "Namespace '$ns' not found; creating it..."
        oc create namespace "$ns"
    else
        log_info "Namespace '$ns' exists."
    fi
}

# ========== DELETE ARGOCD APPS ==========
delete_argocd_apps() {
    log_info "Deleting existing ArgoCD applications to prevent sync interference..."
    argocd app delete tekton-app --yes 2>/dev/null || true
    argocd app delete tekton-operator-app --yes 2>/dev/null || true
    argocd app delete awx-app --yes 2>/dev/null || true
    sleep 5
    log_info "Verifying that ArgoCD apps are fully deleted..."
    for app in tekton-app tekton-operator-app awx-app; do
        local app_status
        app_status=$(argocd app get "$app" --output json 2>/dev/null | jq -r '.metadata.name' || echo "not found")
        if [[ "$app_status" != "not found" ]]; then
            log_error "ArgoCD app $app still exists; retrying deletion..."
            argocd app delete "$app" --yes 2>/dev/null || true
            sleep 10
        fi
    done
    log_info "ArgoCD applications removed successfully."
}

# ========== CLEAN GIT REPO ==========
clean_git_repo() {
    log_info "Cleaning Git repository state..."
    cd "$LOCAL_GIT_DIR"
    rm -rf tekton awx argocd tekton-olm
    git add -A
    git commit -m "Cleanup before fresh deployment" || log_info "No changes to commit."
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
    git clean -fdx
    mkdir -p tekton awx argocd tekton-olm
}

# ========== CLEANUP OLD RESOURCES ==========
cleanup_old_resources() {
    log_info "Cleaning up old resources..."
    log_info "Deleting custom CatalogSources in openshift-marketplace..."
    for catalog in "awx-catalog" "tekton-catalog" "community-catalog" "tektoncd-catalog"; do
        if oc get catalogsource "$catalog" -n openshift-marketplace &>/dev/null; then
            log_info "Deleting $catalog..."
            oc delete catalogsource "$catalog" -n openshift-marketplace --force --grace-period=0 2>/dev/null || true
            oc delete pod -n openshift-marketplace -l olm.catalogSource="$catalog" --force --grace-period=0 2>/dev/null || true
        fi
    done

    log_info "Cleaning up subscriptions, operatorgroups, and custom resources..."
    oc delete subscription --all -n "$TEKTON_OPERATOR_NAMESPACE" --force --grace-period=0 2>/dev/null || true
    oc delete subscription --all -n "$TEKTON_NAMESPACE" --force --grace-period=0 2>/dev/null || true
    oc delete subscription --all -n "$ANSIBLE_NAMESPACE" --force --grace-period=0 2>/dev/null || true
    oc delete tektonpipeline --all -n "$TEKTON_NAMESPACE" 2>/dev/null || true
    oc delete awx --all -n "$ANSIBLE_NAMESPACE" 2>/dev/null || true
    oc delete operatorgroup --all -n "$TEKTON_OPERATOR_NAMESPACE" 2>/dev/null || true
    oc delete operatorgroup --all -n "$TEKTON_NAMESPACE" 2>/dev/null || true
    oc delete operatorgroup --all -n "$ANSIBLE_NAMESPACE" 2>/dev/null || true

    log_info "Deleting operator and app pods..."
    oc delete pod -n tekton-operator --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n awx-operator --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n "$TEKTON_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n "$ANSIBLE_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n "$TEKTON_OPERATOR_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true

    log_info "Resource cleanup complete."
}

# ========== VERIFY CLEAN SLATE ==========
verify_clean_slate() {
    log_info "Verifying clean slate..."
    local unexpected_pods_found=false

    for ns in "openshift-marketplace" "tekton-operator" "awx-operator" "$TEKTON_NAMESPACE" "$TEKTON_OPERATOR_NAMESPACE"; do
        log_info "Checking pods in namespace: $ns"
        local pod_count
        pod_count=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        if [ "$pod_count" -gt 0 ]; then
            if [ "$ns" == "openshift-marketplace" ]; then
                # For marketplace, filter out expected system pods and completed pods.
                local unexpected
                unexpected=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v -E "marketplace-operator|certified-operators|community-operators|redhat-operators|redhat-marketplace" | grep -v "Completed")
                if [ -n "$unexpected" ]; then
                    log_error "Unexpected pods found in $ns after cleanup:"
                    echo "$unexpected"
                    unexpected_pods_found=true
                else
                    log_info "Only expected system pods or completed pods found in $ns:"
                    oc get pods -n "$ns"
                fi
            else
                # For other namespaces, check for non-completed pods.
                local running_pods
                running_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Completed")
                if [ -n "$running_pods" ]; then
                    log_error "Found running pods in $ns after cleanup:"
                    echo "$running_pods"
                    unexpected_pods_found=true
                else
                    log_info "No running pods found in $ns:"
                    oc get pods -n "$ns"
                fi
            fi
        else
            log_info "No pods found in $ns."
        fi
    done

    if $unexpected_pods_found; then
        log_error "Cleanup incomplete; unexpected pods detected."
        # Optionally, exit the script if unexpected pods are critical.
        # error_exit "Cleanup incomplete; unexpected pods detected."
    else
        log_info "Clean slate verified."
    fi
}
# ========== MAIN EXECUTION FLOW ==========
check_dependencies
delete_argocd_apps
clean_git_repo
cleanup_old_resources
verify_oc_login
verify_argocd
