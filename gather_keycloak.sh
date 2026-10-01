#!/usr/bin/env bash

set -eu -o pipefail
s=declare_out_of_trap_script # Workaround for https://github.com/koalaman/shellcheck/issues/3287
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Use LOGS_DIR environment variable if set, otherwise default to /must-gather for container use
# For local development, you can run: LOGS_DIR=./must-gather ./gather_keycloak.sh
LOGS_DIR="${LOGS_DIR:-/must-gather}"

mkdir -p "${LOGS_DIR}"

# Gathering Keycloak Operator subscription information
echo "gather_keycloak:$LINENO] inspecting Keycloak operator subscription .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
KEYCLOAK_CURRENT_CSV=$(
    oc get subscriptions.operators.coreos.com --ignore-not-found -A -o json \
    | jq -r '.items[] | select(.metadata.name | contains("rhbk-operator") or contains("keycloak-operator")) | .status.currentCSV' \
    | head -n1 \
    || true # Subscription resource is missing on k8s or future OCP version
)

if [ -z "$KEYCLOAK_CURRENT_CSV" ]; then
    echo "gather_keycloak:$LINENO] No Keycloak operator subscription found" | tee -a "${LOGS_DIR}/gather_keycloak.log"
    KEYCLOAK_CRD_NAMES=()
else
    echo "gather_keycloak:$LINENO] Found Keycloak operator CSV: $KEYCLOAK_CURRENT_CSV" | tee -a "${LOGS_DIR}/gather_keycloak.log"
    readarray -t KEYCLOAK_CRD_NAMES < <(oc get csv --ignore-not-found -A -o json | jq -r --arg csv "$KEYCLOAK_CURRENT_CSV" '.items[] | select(.metadata.name == $csv) | .spec.customresourcedefinitions.owned[]?.name // empty')
fi

# Gathering cluster version and all CRDs related to operators.coreos.com and keycloak.org
echo "gather_keycloak:$LINENO] inspecting CRDs, clusterversion .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
readarray -t KEYCLOAK_CRDS < <(oc get crd -o name | grep -Ei "keycloak.org|operators.coreos.com" || true)
if [ "${#KEYCLOAK_CRDS[@]}" -gt 0 ]; then
    oc adm inspect --dest-dir="${LOGS_DIR}" "${KEYCLOAK_CRDS[@]}" clusterversion/version > /dev/null || true # ClusterVersion resource is missing on k8s
fi

# Gathering all namespaced custom resources across the cluster that contain "keycloak.org"
oc get crd -o json | jq -r '.items[] | select((.spec.group | contains("keycloak.org")) and .spec.scope=="Namespaced") | .spec.group + " " + .metadata.name + " " + .spec.names.plural' |
while read -r API_GROUP APIRESOURCE API_PLURAL_NAME; do
    echo "gather_keycloak:$LINENO] collecting ${APIRESOURCE} .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    readarray -t NAMESPACES < <(oc get "${APIRESOURCE}" --all-namespaces=true --ignore-not-found -o jsonpath='{range .items[*]}{@.metadata.namespace}{"\n"}{end}' | uniq)
    for NAMESPACE in "${NAMESPACES[@]}"; do
        mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/${API_GROUP}"
        oc get "${APIRESOURCE}" -n "${NAMESPACE}" -o=yaml >"${LOGS_DIR}/namespaces/${NAMESPACE}/${API_GROUP}/${API_PLURAL_NAME}.yaml"
    done
done

# Gathering all cluster-scoped custom resources that contain "keycloak.org"
oc get crd -o json | jq -r '.items[] | select((.spec.group | contains("keycloak.org")) and .spec.scope=="Cluster") | .spec.group + " " + .metadata.name + " " + .spec.names.plural' |
while read -r API_GROUP APIRESOURCE API_PLURAL_NAME; do
    mkdir -p "${LOGS_DIR}/cluster-scoped-resources/${API_GROUP}"
    echo "gather_keycloak:$LINENO] collecting ${APIRESOURCE} .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get "${APIRESOURCE}" -o=yaml >"${LOGS_DIR}/cluster-scoped-resources/${API_GROUP}/${API_PLURAL_NAME}.yaml"
done

# Gather cluster roles and cluster role bindings
echo "gather_keycloak:$LINENO] inspecting clusterroles and clusterrolebindings .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc adm inspect --dest-dir="${LOGS_DIR}" clusterrole,clusterrolebinding > /dev/null

# Inspecting operator namespace and namespaces containing Keycloak instances
echo "gather_keycloak:$LINENO] inspecting Keycloak operator and instance namespaces .." | tee -a "${LOGS_DIR}/gather_keycloak.log"

# Get operator namespace
readarray -t OPERATOR_NAMESPACES < <(oc get subscriptions.operators.coreos.com -A --ignore-not-found -o json | jq -r '.items[] | select(.metadata.name | contains("rhbk-operator") or contains("keycloak-operator")) | .metadata.namespace' || true)

# Get namespaces where Keycloak instances exist
readarray -t KEYCLOAK_INSTANCE_NAMESPACES < <(oc get keycloaks.k8s.keycloak.org,keycloaks.keycloak.org -A --ignore-not-found -o json 2>/dev/null | jq -r '.items[]?.metadata.namespace // empty' | sort -u || true)

# Combine and deduplicate namespaces
ALL_NAMESPACES=()
for ns in "${OPERATOR_NAMESPACES[@]}" "${KEYCLOAK_INSTANCE_NAMESPACES[@]}"; do
    if [ -n "$ns" ]; then
        ALL_NAMESPACES+=("$ns")
    fi
done
readarray -t UNIQUE_NAMESPACES < <(printf "%s\n" "${ALL_NAMESPACES[@]}" | sort -u)

# Inspect each namespace
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    echo "gather_keycloak:$LINENO] inspecting namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"

    # Inspect namespace and its objects
    oc adm inspect --dest-dir="${LOGS_DIR}" "ns/$NAMESPACE" > /dev/null

    # Inspect roles and rolebindings
    oc adm inspect --dest-dir="${LOGS_DIR}" -n "$NAMESPACE" roles,rolebindings > /dev/null || true

    # Inspect operator resources (CSV, subscriptions, install plans)
    echo "gather_keycloak:$LINENO] inspecting csv,sub,ip for namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    readarray -t CSVS_SUBS_IPS < <(oc get --ignore-not-found clusterserviceversions.operators.coreos.com,installplans.operators.coreos.com,subscriptions.operators.coreos.com -o name -n "$NAMESPACE" || true)
    if [ "${#CSVS_SUBS_IPS[@]}" -gt 0 ]; then
        oc adm inspect --dest-dir="${LOGS_DIR}" "${CSVS_SUBS_IPS[@]}" -n "$NAMESPACE" &> /dev/null || true
    fi

    # Gather RHBK-related ConfigMaps (keycloak, rhbk, postgres, database related)
    echo "gather_keycloak:$LINENO] collecting RHBK-related configmaps in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/core"
    oc get configmaps -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/configmaps.yaml" 2>/dev/null || true

    # Gather RHBK-related Secrets metadata only (no actual secret data for security)
    echo "gather_keycloak:$LINENO] collecting RHBK-related secrets metadata in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get secrets -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database|credential|admin"; "i"))' | \
        jq 'del(.data, .stringData) | . + {data: "REDACTED", stringData: "REDACTED"}' | \
        jq -s '.' > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/secrets-metadata.json" 2>/dev/null || true

    # Gather RHBK-related Services
    echo "gather_keycloak:$LINENO] collecting RHBK-related services in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get services -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/services.yaml" 2>/dev/null || true

    # Gather RHBK-related Routes
    echo "gather_keycloak:$LINENO] collecting RHBK-related routes in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get routes -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/routes.yaml" 2>/dev/null || true

    # Gather RHBK-related Ingresses
    echo "gather_keycloak:$LINENO] collecting RHBK-related ingresses in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get ingresses -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/ingresses.yaml" 2>/dev/null || true

    # Gather RHBK-related PVCs (postgres, database, keycloak)
    echo "gather_keycloak:$LINENO] collecting RHBK-related pvcs in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get pvc -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/pvcs.yaml" 2>/dev/null || true

    # Gather pod logs for RHBK-related pods only
    echo "gather_keycloak:$LINENO] collecting RHBK-related pod logs in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/logs"

    # Get RHBK-related pods (keycloak, rhbk-operator, postgres/database pods)
    readarray -t PODS < <(oc get pods -n "$NAMESPACE" --ignore-not-found -o json | \
        jq -r '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i")) | .metadata.name')
    for POD in "${PODS[@]}"; do
        if [ -n "$POD" ]; then
            # Get current logs
            oc logs -n "$NAMESPACE" "$POD" --all-containers=true --ignore-errors=true \
                > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}.log" 2>&1 || true

            # Get previous logs if pod has restarted
            oc logs -n "$NAMESPACE" "$POD" --previous --all-containers=true --ignore-errors=true \
                > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}-previous.log" 2>&1 || true
        fi
    done

    # Gather RHBK-related Pods definition
    echo "gather_keycloak:$LINENO] collecting RHBK-related pods in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get pods -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/pods.yaml" 2>/dev/null || true

    # Gather RHBK-related ServiceAccounts
    echo "gather_keycloak:$LINENO] collecting RHBK-related serviceaccounts in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get serviceaccounts -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/serviceaccounts.yaml" 2>/dev/null || true

    # Gather NetworkPolicies
    echo "gather_keycloak:$LINENO] collecting networkpolicies in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get networkpolicies -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/networkpolicies.yaml" 2>/dev/null || true

    # Gather PodDisruptionBudgets
    echo "gather_keycloak:$LINENO] collecting poddisruptionbudgets in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get poddisruptionbudgets -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/poddisruptionbudgets.yaml" 2>/dev/null || true

    # Gather detailed describe output for RHBK pods
    echo "gather_keycloak:$LINENO] describing RHBK-related pods in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/describe"
    readarray -t DESCRIBE_PODS < <(oc get pods -n "$NAMESPACE" --ignore-not-found -o json | \
        jq -r '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i")) | .metadata.name')
    for POD in "${DESCRIBE_PODS[@]}"; do
        if [ -n "$POD" ]; then
            oc describe pod -n "$NAMESPACE" "$POD" \
                > "${LOGS_DIR}/namespaces/${NAMESPACE}/describe/${POD}.txt" 2>&1 || true
        fi
    done

    # Gather Events (Warning and Error level)
    echo "gather_keycloak:$LINENO] collecting events in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get events -n "$NAMESPACE" --ignore-not-found --field-selector type!=Normal -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/events.yaml" 2>/dev/null || true
done

# Gather RHBK-related StatefulSets across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting RHBK-related StatefulSets .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get statefulsets -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/statefulsets.yaml" 2>/dev/null || true
done

# Gather RHBK-related Deployments across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting RHBK-related Deployments .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get deployments -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/deployments.yaml" 2>/dev/null || true
done

# Gather RHBK-related ReplicaSets across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting RHBK-related ReplicaSets .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get replicasets -n "$NAMESPACE" --ignore-not-found -o json | \
        jq '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
        jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
        oc get -f - -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/replicasets.yaml" 2>/dev/null || true
done

# Gather cluster-level resources useful for troubleshooting
echo "gather_keycloak:$LINENO] collecting cluster-level resources .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
mkdir -p "${LOGS_DIR}/cluster-scoped-resources/storage"
mkdir -p "${LOGS_DIR}/cluster-scoped-resources/nodes"

# Gather StorageClasses (useful for PVC troubleshooting)
echo "gather_keycloak:$LINENO] collecting storageclasses .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc get storageclasses --ignore-not-found -o yaml \
    > "${LOGS_DIR}/cluster-scoped-resources/storage/storageclasses.yaml" 2>/dev/null || true

# Gather PersistentVolumes related to RHBK
echo "gather_keycloak:$LINENO] collecting RHBK-related persistentvolumes .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc get pv --ignore-not-found -o json | \
    jq '.items[] | select(.spec.claimRef.name | test("keycloak|rhbk|postgres|database"; "i"))' | \
    jq -s '{"apiVersion": "v1", "kind": "List", "items": .}' | \
    oc get -f - -o yaml > "${LOGS_DIR}/cluster-scoped-resources/storage/persistentvolumes.yaml" 2>/dev/null || true

# Gather Node information (for scheduling/resource issues)
echo "gather_keycloak:$LINENO] collecting node information .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc get nodes --ignore-not-found -o yaml \
    > "${LOGS_DIR}/cluster-scoped-resources/nodes/nodes.yaml" 2>/dev/null || true

# Gather all operators status (helps understand operator health)
echo "gather_keycloak:$LINENO] collecting all operators status .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc get operators --ignore-not-found -A -o yaml \
    > "${LOGS_DIR}/cluster-scoped-resources/operators.yaml" 2>/dev/null || true

echo "gather_keycloak:$LINENO] must-gather collection complete!" | tee -a "${LOGS_DIR}/gather_keycloak.log"
