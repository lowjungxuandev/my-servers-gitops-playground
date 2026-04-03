# My Servers

This project is a local Kubernetes playground built from three Ubuntu Docker containers and managed with GitOps through Argo CD.

Topology:

- `cluster-node`: upstream Kubernetes control plane
- `application-node`: worker node for the dummy website
- `infrastructure-node`: worker node for Prometheus and Grafana

## What This Includes

- Three Ubuntu containers created by Docker Compose
- An upstream Kubernetes cluster built with `kubeadm`, `kubelet`, and `kubectl`
- Argo CD as the GitOps controller
- A dummy website deployed on `application-node`
- `kube-prometheus-stack` with Grafana and Prometheus on `infrastructure-node`
- Host port mappings for the Kubernetes API and dashboards

## Main Files

- `docker-compose.yml`: Ubuntu node definitions and exposed ports
- `scripts/start-infra.sh`: starts the Ubuntu containers and installs node dependencies on all servers
- `scripts/init-control-plane.sh`: initializes the Kubernetes control plane
- `scripts/join-workers.sh`: joins the worker nodes to the cluster
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

Run the infrastructure startup first:

```bash
cd "/Users/jungxuanlow/Desktop/My Servers"
./scripts/start-infra.sh
```

Then continue with:

```bash
./scripts/init-control-plane.sh
./scripts/join-workers.sh
```

This will:

- start the three Ubuntu containers
- install the node prerequisites
- initialize the Kubernetes cluster

## Argo CD Dashboard

Open:

```text
http://localhost:8081
```

Username:

```text
admin
```

## Useful Commands

Open shells:

```bash
docker exec -it cluster-node bash
docker exec -it application-node bash
docker exec -it infrastructure-node bash
```

Check cluster nodes:

```bash
docker exec cluster-node kubectl get nodes -o wide
```

Check Argo CD apps:

```bash
docker exec cluster-node kubectl -n argocd get applications
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
