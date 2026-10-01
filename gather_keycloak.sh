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
    oc adm inspect --dest-dir="${LOGS_DIR}" "${KEYCLOAK_CRDS[@]}" clusterversion/version > /dev/null 2>&1 || true
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

# Gather RHBK-related cluster roles and cluster role bindings
echo "gather_keycloak:$LINENO] inspecting RHBK-related clusterroles and clusterrolebindings .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
readarray -t RHBK_CLUSTERROLES < <(oc get clusterrole -o name | grep -Ei "keycloak|rhbk" || true)
readarray -t RHBK_CLUSTERROLEBINDINGS < <(oc get clusterrolebinding -o name | grep -Ei "keycloak|rhbk" || true)
if [ "${#RHBK_CLUSTERROLES[@]}" -gt 0 ] || [ "${#RHBK_CLUSTERROLEBINDINGS[@]}" -gt 0 ]; then
    oc adm inspect --dest-dir="${LOGS_DIR}" "${RHBK_CLUSTERROLES[@]}" "${RHBK_CLUSTERROLEBINDINGS[@]}" > /dev/null 2>&1 || true
fi

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

    # Use oc adm inspect for the namespace - this creates the proper structure for omc
    oc adm inspect --dest-dir="${LOGS_DIR}" "ns/$NAMESPACE" > /dev/null 2>&1 || true

    # Collect pod logs for RHBK-related pods
    echo "gather_keycloak:$LINENO] collecting RHBK-related pod logs in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
    mkdir -p "${LOGS_DIR}/namespaces/${NAMESPACE}/logs"

    readarray -t RHBK_PODS < <(oc get pods -n "$NAMESPACE" --ignore-not-found -o json | \
        jq -r '.items[] | select(.metadata.name | test("keycloak|rhbk|postgres|database"; "i")) | .metadata.name')

    for POD in "${RHBK_PODS[@]}"; do
        if [ -n "$POD" ]; then
            oc logs -n "$NAMESPACE" "$POD" --all-containers=true --ignore-errors=true \
                > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}.log" 2>&1 || true
            oc logs -n "$NAMESPACE" "$POD" --previous --all-containers=true --ignore-errors=true \
                > "${LOGS_DIR}/namespaces/${NAMESPACE}/logs/${POD}-previous.log" 2>&1 || true
        fi
    done
done

echo "gather_keycloak:$LINENO] must-gather collection complete!" | tee -a "${LOGS_DIR}/gather_keycloak.log"
