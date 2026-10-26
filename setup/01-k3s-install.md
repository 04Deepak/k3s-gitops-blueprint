# 01 — K3s Installation

Install a single-node K3s cluster on your VPS. K3s is a lightweight, certified Kubernetes distribution that bundles Traefik (ingress), CoreDNS, local-path-provisioner (storage), and kube-proxy into a single binary.

**Time:** ~10 minutes

---

## Step 1: SSH into your server

```bash
ssh myserver
```

## Step 2: Update the system

```bash
apt update && apt upgrade -y
apt install -y curl wget git open-iscsi
```

## Step 3: Install K3s

```bash
curl -sfL https://get.k3s.io | sh -
```

This installs K3s as a systemd service and starts it immediately.

**Verify installation:**

```bash
kubectl get nodes
```

Expected:

```
NAME        STATUS   ROLES                  AGE   VERSION
srv123456   Ready    control-plane,master   30s   v1.31.x+k3s1
```

```bash
kubectl get pods -A
```

Expected (all Running or Completed):

```
NAMESPACE     NAME                                      READY   STATUS
kube-system   coredns-xxx                               1/1     Running
kube-system   local-path-provisioner-xxx                1/1     Running
kube-system   metrics-server-xxx                        1/1     Running
kube-system   svclb-traefik-xxx                         2/2     Running
kube-system   traefik-xxx                               1/1     Running
```

## Step 4: Verify Traefik

Traefik is K3s's built-in ingress controller, listening on ports 80 and 443.

```bash
kubectl -n kube-system get svc traefik
```

Expected:

```
NAME      TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)
traefik   LoadBalancer   10.43.x.x      YOUR_SERVER_IP 80:xxxxx/TCP,443:xxxxx/TCP
```

Quick test from your local machine:

```bash
curl -s -o /dev/null -w "%{http_code}" http://YOUR_SERVER_IP
```

Expected: `404` (Traefik is running but no routes configured yet).

## Step 5: Configure kubectl locally

Copy the kubeconfig from the server to your local machine:

```bash
# On your local machine
mkdir -p ~/.kube
scp myserver:/etc/rancher/k3s/k3s.yaml ~/.kube/config-myproject
```

Edit the file — replace `127.0.0.1` with your server's public IP:

```bash
sed -i '' "s/127.0.0.1/YOUR_SERVER_IP/g" ~/.kube/config-myproject
# On Linux (no '' after -i):
# sed -i "s/127.0.0.1/YOUR_SERVER_IP/g" ~/.kube/config-myproject
```

Set it as your active kubeconfig:

```bash
export KUBECONFIG=~/.kube/config-myproject
```

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
echo 'export KUBECONFIG=~/.kube/config-myproject' >> ~/.zshrc
```

**Verify remote access:**

```bash
kubectl get nodes
```

You should see the same node list as on the server.

## Step 6: Create namespaces

```bash
# Production app
kubectl create namespace {{NAMESPACE}}

# Staging
kubectl create namespace {{STAGING_NAMESPACE}}

# Shared services (Postgres, Redis)
kubectl create namespace shared
```

**Verify:**

```bash
kubectl get namespaces
```

Expected output includes:

```
NAME                   STATUS   AGE
default                Active   5m
kube-system            Active   5m
shared                 Active   10s
{{NAMESPACE}}          Active   10s
{{STAGING_NAMESPACE}}  Active   10s
```

## Step 7: Verify storage provisioner

K3s includes `local-path-provisioner` for persistent volumes.

```bash
kubectl get storageclass
```

Expected:

```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

This means PersistentVolumeClaims will automatically provision directories under `/opt/local-path-provisioner/` on the node.

---

## Troubleshooting

### K3s fails to start

```bash
# Check service status
systemctl status k3s

# Check logs
journalctl -u k3s -f --no-pager | tail -50
```

Common causes:
- **Port 6443 in use:** Another K8s install or service. Kill it: `ss -tlnp | grep 6443`
- **Firewall blocking:** Ensure ports 6443, 80, 443, 10250 are open
- **Insufficient memory:** K3s needs at least 512 MB free; 2 GB recommended

### kubectl connection refused from local machine

- Check the server IP in your kubeconfig: `grep server ~/.kube/config-myproject`
- Ensure port 6443 is open on the server firewall
- Test: `curl -k https://YOUR_SERVER_IP:6443/version`

### Traefik not running

```bash
kubectl -n kube-system describe pod -l app.kubernetes.io/name=traefik
```

Common causes:
- Port 80/443 already bound by nginx/apache: `ss -tlnp | grep -E ':80|:443'`
- Fix: `apt remove nginx apache2` or stop the conflicting service

### Reset and reinstall

If everything is broken and you want to start fresh:

```bash
# On the server
/usr/local/bin/k3s-uninstall.sh
curl -sfL https://get.k3s.io | sh -
```

---

## What you have now

- Single-node K3s cluster with Traefik, CoreDNS, metrics-server
- Remote kubectl access from your local machine
- Three namespaces ready for apps and shared services
- Default storage class for persistent volumes

**Next:** [02-shared-services.md](./02-shared-services.md) — deploy PostgreSQL and Redis.
