# Keycloak (RHBK) Must-Gather

`keycloak-must-gather` is a tool to gather diagnostic information about Red Hat build of Keycloak (RHBK) and upstream Keycloak running on OpenShift Container Platform (OCP). It is built on top of [OpenShift must-gather](https://github.com/openshift/must-gather).

## About Must-Gather

The `oc adm must-gather` command is a diagnostic tool that collects information about the cluster for debugging and troubleshooting. This Keycloak-specific must-gather image extends the base functionality to capture Keycloak-specific resources and configurations.

## Usage

Run the following command to gather diagnostic data:

```sh
oc adm must-gather --image=quay.io/fpezzull/keycloak-must-gather:latest
```

For Red Hat customers using RHBK, you may use the official Red Hat registry image once available:

```sh
oc adm must-gather --image=registry.redhat.io/rhbk/keycloak-must-gather-rhel8:latest
```

The command will create a local directory with a dump of the Keycloak/RHBK state. Note that this command will only get data related to Keycloak in your OpenShift cluster.

## What Data is Collected

This must-gather tool collects:

- **Keycloak Custom Resources**:
  - All Keycloak CRDs (CustomResourceDefinitions) related to `keycloak.org` and `operators.coreos.com`
  - Keycloak CR instances (both `k8s.keycloak.org` and `keycloak.org` API groups)
  - KeycloakRealmImport resources
  - All other Keycloak-related custom resources (both namespaced and cluster-scoped)

- **RBAC Resources**:
  - Keycloak/RHBK-related ClusterRoles and ClusterRoleBindings

- **Namespace Resources** (collected from operator and Keycloak instance namespaces):
  - All namespace-scoped resources using `oc adm inspect`, including:
    - Operator information (Subscriptions, ClusterServiceVersions, InstallPlans)
    - ConfigMaps
    - Secrets (with sensitive data automatically handled by `oc adm inspect`)
    - Services
    - Routes (OpenShift)
    - Ingresses (Kubernetes)
    - PersistentVolumeClaims
    - Deployments
    - StatefulSets
    - ReplicaSets
    - Pods
    - Roles and RoleBindings
    - Events

- **Pod Logs** (selectively collected from RHBK-related pods):
  - Current logs from pods matching: keycloak, rhbk, postgres, or database
  - Previous logs from these pods (if they have restarted)

- **Cluster Information**:
  - ClusterVersion (OpenShift only)

### Security Note

**Secrets**: The must-gather tool uses `oc adm inspect` which automatically handles secrets securely. Sensitive data in secrets is handled according to OpenShift's inspection policies.

## Output Structure

The must-gather creates a directory structure like:

```
must-gather-output/
├── cluster-scoped-resources/
│   ├── <api-group>/
│   │   └── <resource-plural>.yaml
│   └── rbac.authorization.k8s.io/
│       ├── clusterroles/
│       └── clusterrolebindings/
├── namespaces/
│   └── <namespace-name>/
│       ├── <api-group>/
│       │   └── <resource-plural>.yaml
│       ├── <resource-type>/
│       │   └── ...
│       └── logs/
│           ├── <rhbk-pod-name>.log
│           └── <rhbk-pod-name>-previous.log
└── gather_keycloak.log
```

**Note**: The exact structure within each namespace is determined by `oc adm inspect` and may vary based on the resources present. Pod logs are collected only for RHBK-related pods (keycloak, rhbk, postgres, database).

## Development

### Prerequisites

- `podman` or `docker`
- `shellcheck` (for linting)
- OpenShift CLI (`oc`)

### Building the Image

```sh
make image
```

To build with a custom registry/tag:

```sh
make image CONTAINER_REGISTRY=quay.io REGISTRY_USERNAME=myuser CONTAINER_IMAGE_TAG=v1.0
```

### Linting

Run shellcheck on the gathering script:

```sh
make lint
```

### Pushing the Image

```sh
make push
```

Or with custom parameters:

```sh
make push REGISTRY_USERNAME=myuser CONTAINER_IMAGE_TAG=v1.0
```

### Cleaning Up

Remove the built image:

```sh
make clean
```

## Testing

### Manual Testing

1. Deploy Keycloak operator on an OpenShift cluster:

```sh
# For upstream Keycloak operator
oc create -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/latest/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
oc create -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/latest/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
oc create -f https://raw.githubusercontent.com/keycloak/keycloak-operator/main/deploy/operator.yaml
```

2. Create a Keycloak instance:

```sh
oc apply -f - <<EOF
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: example-keycloak
  namespace: keycloak
spec:
  instances: 1
  http:
    tlsSecret: example-tls-secret
  hostname:
    hostname: keycloak.example.com
EOF
```

3. Run the must-gather:

```sh
oc adm must-gather --image=quay.io/myuser/keycloak-must-gather:latest
```

4. Verify the collected data:

```sh
ls -R must-gather.local.*
```

## Contributing

Contributions are welcome! Please ensure:

1. All shell scripts pass `shellcheck` linting
2. Test your changes against a real OpenShift cluster with Keycloak installed
3. Document any new collection features in this README

## License

Apache License 2.0

## Support

For issues and questions:
- Red Hat Customers: Open a support case for RHBK-related issues
- Community: File an issue in this repository

## Related Projects

- [Keycloak Operator](https://github.com/keycloak/keycloak-operator)
- [OpenShift Must-Gather](https://github.com/openshift/must-gather)
- [Red Hat Build of Keycloak](https://access.redhat.com/products/red-hat-build-of-keycloak)
