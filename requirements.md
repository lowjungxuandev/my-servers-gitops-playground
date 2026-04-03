# Requirements

- Use original Kubernetes only: `kubeadm`, `kubelet`, `kubectl`
- Do not use `k3s`, `kind`, or `microk8s`
- Use 3 Ubuntu servers in Docker
- `Server 1` is the control plane
- `Server 2` is a worker node for the dummy website
- `Server 3` is a worker node for Grafana and Prometheus
- Use Argo CD for GitOps
- Argo CD dashboard must be accessible
- Use the real GitHub account `lowjungxuandev`
- GitOps repo must include both apps and infra
- Changes pushed to GitHub should sync automatically
- Use `kustomization.yaml` and Kubernetes YAML as the main config format
- Avoid manual `helm` CLI usage
- Setup should be clean enough to study as a DevOps boilerplate
