# My Servers

This project is a local Kubernetes playground built from three Ubuntu Docker containers and managed with GitOps through Argo CD.

Topology:

- `ubuntu-server-1`: upstream Kubernetes control plane
- `ubuntu-server-2`: worker node for the dummy website
- `ubuntu-server-3`: worker node for Prometheus and Grafana

## What This Includes

- Three Ubuntu containers created by Docker Compose
- An upstream Kubernetes cluster built with `kubeadm`, `kubelet`, and `kubectl`
- Argo CD as the GitOps controller
- A dummy website deployed on `ubuntu-server-2`
- `kube-prometheus-stack` with Grafana and Prometheus on `ubuntu-server-3`
- Host port mappings for the Kubernetes API and dashboards

## Main Files

- `docker-compose.yml`: Ubuntu node definitions and exposed ports
- `start.sh`: starts the Ubuntu containers
- `scripts/recreate-nodes.sh`: recreates the three Ubuntu nodes
- `scripts/install-kubernetes-cluster.sh`: installs upstream Kubernetes with `kubeadm`
- `scripts/bootstrap-argocd.sh`: installs Argo CD and applies the root app
- `scripts/bootstrap-lab.sh`: full bootstrap for the lab
- `scripts/get-argocd-admin-password.sh`: prints the Argo CD admin password
- `gitops/bootstrap/root-application.yaml`: app-of-apps entrypoint
- `gitops/apps/`: Argo CD applications
- `gitops/manifests/dummy-website/`: Git-managed demo workload

## URLs

- Kubernetes API: `https://127.0.0.1:6443`
- Dummy website: `http://localhost:8080`
- Grafana: `http://localhost:3000`
- Prometheus: `http://localhost:9090`
- Argo CD dashboard: `http://localhost:8081`

## Quick Start

Run the full bootstrap:

```bash
cd "/Users/jungxuanlow/Desktop/My Servers"
./scripts/bootstrap-lab.sh
```

This will:

- recreate the three Ubuntu containers
- install the Kubernetes cluster
- install Argo CD
- apply the GitOps root application

## Argo CD Dashboard

Open:

```text
http://localhost:8081
```

Username:

```text
admin
```

Get the initial password:

```bash
./scripts/get-argocd-admin-password.sh
```

## Useful Commands

Open shells:

```bash
docker exec -it ubuntu-server-1 bash
docker exec -it ubuntu-server-2 bash
docker exec -it ubuntu-server-3 bash
```

Check cluster nodes:

```bash
docker exec ubuntu-server-1 kubectl get nodes -o wide
```

Check Argo CD apps:

```bash
docker exec ubuntu-server-1 kubectl -n argocd get applications
```

Stop everything:

```bash
docker compose down
```

## Notes

- These are Docker containers, not full virtual machines.
- `ubuntu:latest` currently resolves to Ubuntu `24.04.4 LTS`.
- The Kubernetes bootstrap uses upstream packages from `pkgs.k8s.io`, not K3s, kind, or microk8s.
- Port `8081` is reserved for the Argo CD dashboard in this setup.
