#!/bin/bash
# Ensure critical PVC is present after restart
if ! oc get pvc existing-hub-name-file-storage -n aap >/dev/null 2>&1; then
  echo "PVC missing — recreating..."
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: existing-hub-name-file-storage
  namespace: aap
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: crc-csi-hostpath-provisioner
EOF
fi
