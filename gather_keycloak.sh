#!/usr/bin/env bash

set -eu -o pipefail
s=declare_out_of_trap_script # Workaround for https://github.com/koalaman/shellcheck/issues/3287
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

LOGS_DIR="/must-gather"

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
    readarray -t KEYCLOAK_CRD_NAMES < <(oc get csv --ignore-not-found "$KEYCLOAK_CURRENT_CSV" -A -o json | jq -r '.items[].spec.customresourcedefinitions.owned[]?.name // empty')
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

    # Gather ConfigMaps (excluding kube-root-ca.crt which is in every namespace)
    echo "gather_keycloak:$LINENO] collecting configmaps in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/core"
    oc get configmaps -n "$NAMESPACE" --ignore-not-found -o yaml | \
        yq eval 'del(.items[] | select(.metadata.name == "kube-root-ca.crt" or .metadata.name == "openshift-service-ca.crt"))' - \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/configmaps.yaml" 2>/dev/null || \
        oc get configmaps -n "$NAMESPACE" --ignore-not-found -o yaml > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/configmaps.yaml" 2>/dev/null || true

    # Gather Secrets metadata only (no actual secret data for security)
    echo "gather_keycloak:$LINENO] collecting secrets metadata in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get secrets -n "$NAMESPACE" --ignore-not-found -o json | \
        jq 'del(.items[].data, .items[].stringData)' | \
        jq '.items[] |= . + {data: "REDACTED", stringData: "REDACTED"}' \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/secrets-metadata.json" 2>/dev/null || true

    # Gather Services
    echo "gather_keycloak:$LINENO] collecting services in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get services -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/services.yaml" 2>/dev/null || true

    # Gather Routes
    echo "gather_keycloak:$LINENO] collecting routes in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get routes -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/routes.yaml" 2>/dev/null || true

    # Gather Ingresses
    echo "gather_keycloak:$LINENO] collecting ingresses in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get ingresses -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/ingresses.yaml" 2>/dev/null || true

    # Gather PVCs
    echo "gather_keycloak:$LINENO] collecting pvcs in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get pvc -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/pvcs.yaml" 2>/dev/null || true

    # Gather pod logs
    echo "gather_keycloak:$LINENO] collecting pod logs in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/logs"

    # Get all pods in the namespace
    readarray -t PODS < <(oc get pods -n "$NAMESPACE" --ignore-not-found -o jsonpath='{.items[*].metadata.name}')
    for POD in ${PODS[@]}; do
        # Get current logs
        oc logs -n "$NAMESPACE" "$POD" --all-containers=true --ignore-errors=true \
            > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}.log" 2>&1 || true

        # Get previous logs if pod has restarted
        oc logs -n "$NAMESPACE" "$POD" --previous --all-containers=true --ignore-errors=true \
            > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}-previous.log" 2>&1 || true
    done

    # Gather Events (Warning and Error level)
    echo "gather_keycloak:$LINENO] collecting events in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    oc get events -n "$NAMESPACE" --ignore-not-found --field-selector type!=Normal -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/events.yaml" 2>/dev/null || true
done

# Gather StatefulSets across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting StatefulSets .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get statefulsets -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/statefulsets.yaml" 2>/dev/null || true
done

# Gather Deployments across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting Deployments .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get deployments -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/deployments.yaml" 2>/dev/null || true
done

# Gather ReplicaSets across Keycloak namespaces
echo "gather_keycloak:$LINENO] collecting ReplicaSets .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
for NAMESPACE in "${UNIQUE_NAMESPACES[@]}"; do
    oc get replicasets -n "$NAMESPACE" --ignore-not-found -o yaml \
        > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/replicasets.yaml" 2>/dev/null || true
done

echo "gather_keycloak:$LINENO] must-gather collection complete!" | tee -a "${LOGS_DIR}/gather_keycloak.log"
