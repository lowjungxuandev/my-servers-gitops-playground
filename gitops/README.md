# GitOps Layout

This `gitops/` folder is organized in four layers:

- `bootstrap/`: the first Argo CD root application
- `root/`: top-level app-of-apps split into infrastructure and workloads
- `apps/`: Argo CD `Application` and `AppProject` objects
- `manifests/`: Kubernetes manifests managed by `kustomize`

Flow:

1. Bootstrap applies `bootstrap/root-application.yaml`
2. The root app points to `root/`
3. `root/` creates the `infrastructure` and `workloads` app groups
4. Each app group points to Git-managed manifests under `manifests/`

Placement:

- dummy website: `application-node`
- Grafana and Prometheus: `infrastructure-node`

Guideline:

- prefer `kustomization.yaml` and plain Kubernetes YAML
- avoid manual `helm` CLI operations
