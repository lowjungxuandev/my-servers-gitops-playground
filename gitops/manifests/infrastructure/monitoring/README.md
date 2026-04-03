# Monitoring

This folder defines the monitoring stack managed by Argo CD.

Notes:

- source chart: `kube-prometheus-stack`
- deployment method: Argo CD application in Git
- Grafana and Prometheus are pinned to `infrastructure-node`
- no manual `helm` CLI is required
