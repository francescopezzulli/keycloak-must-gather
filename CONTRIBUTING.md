# Contributing to Keycloak Must-Gather

Thank you for your interest in contributing to the Keycloak Must-Gather project!

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```sh
   git clone https://github.com/YOUR_USERNAME/keycloak-must-gather.git
   cd keycloak-must-gather
   ```
3. Create a branch for your changes:
   ```sh
   git checkout -b my-feature-branch
   ```

## Development Guidelines

### Code Style

- All shell scripts must pass `shellcheck` linting
- Use 4-space indentation for shell scripts
- Follow existing code patterns and conventions
- Add comments for complex logic

### Testing Your Changes

Before submitting a pull request:

1. **Lint your code:**
   ```sh
   make lint
   ```

2. **Build the image:**
   ```sh
   make image
   ```

3. **Test on a real cluster:**
   
   a. Set up an OpenShift cluster with Keycloak/RHBK installed
   
   b. Run the must-gather with your custom image:
   ```sh
   make image REGISTRY_USERNAME=myuser CONTAINER_IMAGE_TAG=test
   make push REGISTRY_USERNAME=myuser CONTAINER_IMAGE_TAG=test
   oc adm must-gather --image=quay.io/myuser/keycloak-must-gather:test
   ```
   
   c. Verify the output contains all expected resources:
   ```sh
   ls -R must-gather.local.*
   ```

4. **Check for common issues:**
   - Ensure secrets are properly redacted (no actual secret values in output)
   - Verify logs are collected from all relevant pods
   - Check that CRDs and custom resources are properly gathered
   - Ensure the script handles missing resources gracefully (no fatal errors)

### What to Test

Your changes should be tested against:

- **Upstream Keycloak Operator** (from keycloak/keycloak-operator)
- **Red Hat Build of Keycloak (RHBK)** operator (if you have access)

Test scenarios:

1. Cluster with Keycloak operator but no Keycloak instances
2. Cluster with one Keycloak instance
3. Cluster with multiple Keycloak instances in different namespaces
4. Cluster with Keycloak and KeycloakRealmImport resources
5. Cluster with pods in various states (Running, CrashLoopBackOff, etc.)

## Submitting Changes

1. **Commit your changes:**
   ```sh
   git add .
   git commit -m "Description of your changes"
   ```

2. **Push to your fork:**
   ```sh
   git push origin my-feature-branch
   ```

3. **Open a Pull Request:**
   - Provide a clear description of the changes
   - Reference any related issues
   - Include test results if applicable

### Pull Request Checklist

- [ ] Code passes `make lint`
- [ ] Changes tested on a real OpenShift cluster
- [ ] Documentation updated (README.md) if needed
- [ ] Commit messages are clear and descriptive
- [ ] No secrets or sensitive data in commits

## Adding New Collection Features

When adding new resource types to collect:

1. **Consider security:** Ensure sensitive data (passwords, tokens, keys) is redacted
2. **Handle missing resources:** Use `--ignore-not-found` to avoid errors when resources don't exist
3. **Log collection progress:** Add echo statements to track collection progress
4. **Organize output:** Place resources in appropriate directories following the existing structure
5. **Update README:** Document what new data is being collected

### Example: Adding a New Resource Type

```bash
# In gather_keycloak.sh
echo "gather_keycloak:$LINENO] collecting new-resource in namespace $NAMESPACE .." | tee -a "${LOGS_DIR}/gather_keycloak.log"
oc get new-resource -n "$NAMESPACE" --ignore-not-found -o yaml \
    > "${LOGS_DIR}/namespaces/${NAMESPACE}/core/new-resource.yaml" 2>/dev/null || true
```

## Reporting Issues

If you find a bug or have a feature request:

1. Check if an issue already exists
2. If not, create a new issue with:
   - Clear description of the problem or feature
   - Steps to reproduce (for bugs)
   - Expected vs actual behavior
   - Environment details (OCP version, Keycloak/RHBK version)

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow

## Questions?

If you have questions about contributing, feel free to:

- Open an issue with the `question` label
- Reach out to the maintainers

Thank you for contributing to Keycloak Must-Gather!
