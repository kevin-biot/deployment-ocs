#!/bin/bash
set -euo pipefail

# Clean up Tekton operator and pipeline resources

# Delete Tekton operator subscription and operatorgroup in the operator namespace (usually "openshift-operators")
echo "Deleting Subscription and OperatorGroup in openshift-operators..."
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators --force --grace-period=0 || true
oc delete operatorgroup --all -n openshift-operators --force --grace-period=0 || true

# Delete any TektonPipeline CR in the runtime namespace
echo "Deleting TektonPipeline CRs in openshift-pipelines..."
oc delete tektonpipeline --all -n openshift-pipelines || true

# Delete any remaining Tekton operator pods in both namespaces
echo "Deleting Tekton operator pods..."
oc delete pod -n openshift-operators --selector=app=openshift-pipelines-operator-rh --force --grace-period=0 || true
oc delete pod -n openshift-pipelines --selector=app=tekton-operator || true

echo "Cleanup complete."
