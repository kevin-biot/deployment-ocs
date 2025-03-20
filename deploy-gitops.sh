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
    for cmd in oc argocd git jq; do
        command -v "$cmd" >/dev/null || error_exit "Missing $cmd, please install."
    done
    log_info "Dependencies verified."
}

# ========== DELETE ARGOCD APPS ==========
delete_argocd_apps() {
    log_info "Deleting existing ArgoCD applications to prevent sync interference..."
    argocd app delete tekton-app --yes 2>/dev/null || true
    argocd app delete awx-app --yes 2>/dev/null || true
    sleep 5  # Give ArgoCD a moment to process deletions
    log_info "Verifying that ArgoCD apps are fully deleted..."
    for app in tekton-app awx-app; do
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
    # Remove entire directories to ensure complete cleanup
    rm -rf tekton awx argocd
    # Stage deletions and commit them
    git add -A
    git commit -m "Cleanup before fresh deployment" || log_info "No changes to commit."
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH"
    log_info "Performing deep Git cleanup..."
    git clean -fdx  # Remove ALL untracked files, including ignored ones
    # Recreate the directories so that new YAML files can be written
    mkdir -p tekton awx argocd
    # (Stray file check removed because tracked files are expected)
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
    oc delete subscription --all -n "$TEKTON_NAMESPACE" --force --grace-period=0 2>/dev/null || true
    oc delete subscription --all -n "$ANSIBLE_NAMESPACE" --force --grace-period=0 2>/dev/null || true
    oc delete tektonpipeline --all -n "$TEKTON_NAMESPACE" 2>/dev/null || true
    oc delete awx --all -n "$ANSIBLE_NAMESPACE" 2>/dev/null || true
    oc delete operatorgroup --all -n "$TEKTON_NAMESPACE" 2>/dev/null || true
    oc delete operatorgroup --all -n "$ANSIBLE_NAMESPACE" 2>/dev/null || true

    log_info "Deleting operator and app pods..."
    oc delete pod -n tekton-operator --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n awx-operator --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n "$TEKTON_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true
    oc delete pod -n "$ANSIBLE_NAMESPACE" --all --force --grace-period=0 2>/dev/null || true

    log_info "Resource cleanup complete."
}

# ========== VERIFY CLEAN SLATE ==========
verify_clean_slate() {
    log_info "Verifying clean slate..."
    for ns in "openshift-marketplace" "tekton-operator" "awx-operator" "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE"; do
        local pod_count
        pod_count=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        if [ "$pod_count" -gt 0 ]; then
            if [ "$ns" == "openshift-marketplace" ]; then
                local unexpected_pods
                unexpected_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v -E "marketplace-operator|certified-operators|community-operators|redhat-operators|redhat-marketplace" | wc -l)
                if [ "$unexpected_pods" -gt 0 ]; then
                    log_error "Found $unexpected_pods unexpected pods in $ns after cleanup:"
                    oc get pods -n "$ns" | grep -v -E "marketplace-operator|certified-operators|community-operators|redhat-operators|redhat-marketplace"
                    error_exit "Cleanup incomplete; unexpected pods detected in $ns."
                else
                    log_info "Only expected system pods found in $ns:"
                    oc get pods -n "$ns"
                fi
            else
                log_error "Found $pod_count pods in $ns after cleanup:"
                oc get pods -n "$ns"
                error_exit "Cleanup incomplete; residual pods detected in $ns."
            fi
        fi
    done
    log_info "Clean slate verified."
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

# ========== CREATE YAML FILES ==========
create_yaml_files() {
    log_info "Creating required YAML files..."

    # ArgoCD Applications (disable auto-sync initially)
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
    syncOptions:
    - ApplyOutOfSyncOnly=true
EOF

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
    syncOptions:
    - ApplyOutOfSyncOnly=true
EOF

    # Tekton: TektonPipeline Custom Resource
    cat <<EOF > "$LOCAL_GIT_DIR/tekton/tekton-pipeline.yaml"
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonPipeline
metadata:
  name: pipeline
  namespace: $TEKTON_NAMESPACE
spec:
  targetNamespace: $TEKTON_NAMESPACE
EOF

    # AWX: Operator Manifest
    cat <<EOF > "$LOCAL_GIT_DIR/awx/awx-operator.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: awx-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: awx-operator-clusterrolebinding
subjects:
- kind: ServiceAccount
  name: awx-operator
  namespace: awx-operator
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: awx-operator
  namespace: awx-operator
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: awx-operator
  namespace: awx-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      name: awx-operator
  template:
    metadata:
      labels:
        name: awx-operator
    spec:
      serviceAccountName: awx-operator
      containers:
      - name: awx-operator
        image: quay.io/ansible/awx-operator:2.14.0
        env:
        - name: WATCH_NAMESPACE
          value: "$ANSIBLE_NAMESPACE"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
EOF

    # AWX: AWX Instance Custom Resource
    cat <<EOF > "$LOCAL_GIT_DIR/awx/awx-instance.yaml"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: $ANSIBLE_NAMESPACE
spec:
  service_type: ClusterIP
  ingress_type: none
  hostname: awx.example.com
  image: quay.io/ansible/awx:24.0.0
  image_pull_policy: IfNotPresent
EOF

    log_info "YAML files created."
}

# ========== SETUP RBAC ROLEBINDING ==========
setup_rbac() {
    log_info "Setting up RBAC for ArgoCD service account..."
    oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n "$ARGO_NAMESPACE" 2>/dev/null || true

    for ns in "$TEKTON_NAMESPACE" "$ANSIBLE_NAMESPACE" "awx-operator"; do
        oc create rolebinding "argocd-admin-${ns}" \
            --clusterrole=admin \
            --serviceaccount="$ARGO_NAMESPACE:openshift-gitops-argocd-application-controller" \
            -n "$ns" --dry-run=client -o yaml | oc apply -f -
    done

    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-tekton-operator
rules:
- apiGroups: ["operator.tekton.dev"]
  resources: ["tektonpipelines", "tektontriggers", "tektonconfigs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-tekton-operator-binding
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: $ARGO_NAMESPACE
roleRef:
  kind: ClusterRole
  name: argocd-tekton-operator
  apiGroup: rbac.authorization.k8s.io
EOF

    log_info "RBAC RoleBindings and ClusterRole configured."
}

# ========== GIT COMMIT ==========
commit_git() {
    log_info "Committing and pushing YAML files..."
    cd "$LOCAL_GIT_DIR"
    git add .
    git commit -m "Deploy Tekton and AWX with full cleanup and controlled ArgoCD sync" || log_info "No changes to commit."
    git push "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com/kevin-biot/deployment-ocs.git" "$GIT_BRANCH" --force
    log_info "Changes pushed."
}

# ========== WAIT FOR ARGOCD SYNC ==========
wait_for_argocd_sync() {
    local app="$1"
    local attempt=1
    log_info "Terminating any existing operations for $app..."
    argocd app terminate-op "$app" 2>/dev/null || log_info "No prior operation to terminate."
    log_info "Forcing initial sync for $app..."
    argocd app sync "$app" --prune
    while [ $attempt -le 15 ]; do
        log_info "Waiting for $app to sync (Attempt $attempt)..."
        local status=$(argocd app get "$app" --output json | jq -r '.status.sync.status')
        local health=$(argocd app get "$app" --output json | jq -r '.status.health.status')
        if [[ "$status" == "Synced" && "$health" == "Healthy" ]]; then
            log_info "$app synced and healthy."
            return
        elif [[ "$status" == "Synced" ]]; then
            log_info "$app synced but health is $health. Checking pods..."
            oc get pods -n "${app//-app/}-operator" -o wide
            oc get pods -n "${app//-app/}" -o wide
            local operator_pod_status=$(oc get pods -n "${app//-app/}-operator" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NoPod")
            if [[ "$operator_pod_status" != "Running" ]]; then
                log_error "Operator pod in ${app//-app/}-operator is not running: $operator_pod_status"
                oc describe pod -n "${app//-app/}-operator" -l name="${app//-app/}-operator"
                error_exit "Deployment failed due to unhealthy operator pod."
            fi
            log_info "Pod events for ${app//-app/}-operator:"
            oc get events -n "${app//-app/}-operator" --sort-by='.lastTimestamp'
            log_info "Pod events for ${app//-app/}:"
            oc get events -n "${app//-app/}" --sort-by='.lastTimestamp'
            sleep 30
        else
            log_info "$app status: $status, health: $health. Waiting..."
        fi
        sleep 30
        attempt=$((attempt+1))
    done
    error_exit "$app failed to sync or become healthy after 15 attempts."
}

# ========== WAIT FOR PODS ==========
wait_for_pods() {
    local ns="$1"
    log_info "Waiting for pods in $ns..."
    oc wait --for=condition=ready pod -n "$ns" --all --timeout=600s || log_info "Pods in $ns may still be starting."
    log_info "Pods in $ns checked."
}

# ========== MAIN EXECUTION FLOW ==========
check_dependencies
delete_argocd_apps  # Delete apps first to stop sync
clean_git_repo
cleanup_old_resources
verify_oc_login
verify_argocd
login_argocd
ensure_argocd_git_credentials
create_directories
create_yaml_files
commit_git

oc create ns "$TEKTON_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc create ns "$ANSIBLE_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
# Remove creation of "tekton-operator" namespace since we expect the OLM-installed operator to handle Tekton pipelines.
oc create ns "awx-operator" --dry-run=client -o yaml | oc apply -f -

setup_rbac  # RBAC before app creation

argocd app create tekton-app --upsert -f "$LOCAL_GIT_DIR/argocd/tekton-app.yaml"
argocd app create awx-app --upsert -f "$LOCAL_GIT_DIR/argocd/awx-app.yaml"

verify_clean_slate

wait_for_argocd_sync "tekton-app"
wait_for_argocd_sync "awx-app"

wait_for_pods "$TEKTON_NAMESPACE"
wait_for_pods "$ANSIBLE_NAMESPACE"

log_info "✅ Deployment complete!"
ARGO_SERVER=$(oc get route openshift-gitops-server -n "$ARGO_NAMESPACE" -o jsonpath='{.spec.host}')
log_info "📌 ArgoCD UI: https://$ARGO_SERVER"
log_info "🔑 ArgoCD Admin Password: (get using oc CLI:)"
log_info "  oc get secret openshift-gitops-cluster -n $ARGO_NAMESPACE -o jsonpath='{.data.admin\.password}' | base64 -d"
