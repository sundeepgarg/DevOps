# Docker & Containers Interview Guide

**Target Role:** Principal Platform Engineer / SRE / DevOps Lead
**Why this matters:** Asked in every platform/SRE interview. Kubernetes knowledge assumed but Docker fundamentals still tested.

---

## 1. Docker Architecture

### Q: Explain the Docker architecture.

```
Docker CLI  →  Docker Daemon (dockerd)  →  containerd  →  runc
              (REST API on /var/run/docker.sock)
```

| Component | Role |
|---|---|
| **Docker CLI** | Client — sends commands to daemon via REST API |
| **dockerd** | Daemon — manages images, containers, networks, volumes |
| **containerd** | Industry-standard container runtime — manages container lifecycle (pull, create, start, stop) |
| **runc** | OCI runtime — actually creates the container (namespace + cgroup setup, then exec) |

**Kubernetes uses containerd directly** — it bypassed Docker as of Kubernetes 1.24 (`dockershim` removed). Kubernetes talks to containerd via CRI (Container Runtime Interface). Docker is now just a developer tool; production Kubernetes clusters use containerd or CRI-O.

### Q: What is the OCI standard?

OCI = Open Container Initiative. Defines two specifications:
1. **Image spec** — how a container image is structured (layers, config, manifest)
2. **Runtime spec** — how a container is run (namespaces, cgroups, mounts)

OCI compliance means: images built with Docker, Podman, Buildah, or Kaniko all work on any OCI-compliant runtime (containerd, CRI-O, runc).

---

## 2. Container Internals

### Q: How does a container actually work? What makes it isolated?

A container is a process with kernel namespace isolation and cgroup resource limits. No hypervisor, no guest OS — just a regular Linux process with restricted visibility.

**Linux namespaces used:**

| Namespace | Isolates |
|---|---|
| `pid` | Process IDs — container processes can't see host processes |
| `net` | Network stack — own IP, routes, iptables |
| `mnt` | Filesystem mounts — container sees its own filesystem tree |
| `uts` | Hostname — container has its own hostname |
| `ipc` | IPC resources — shared memory, semaphores |
| `user` | User/group IDs — UID 0 inside ≠ UID 0 outside (with user namespaces) |

**cgroups (control groups):**
- Limit and account for resource usage: CPU, memory, disk I/O, network
- `memory.limit_in_bytes` → triggers OOM kill when exceeded
- `cpu.shares` → relative CPU weight between containers

```bash
# See cgroups for a running container
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.limit_in_bytes
```

### Q: What is OverlayFS and how do image layers work?

Docker images are built in layers. Each `RUN`, `COPY`, `ADD` instruction creates a new layer. Layers are stacked using **OverlayFS** (or Union filesystem).

```
Layer 5 (Read-Write)  ← container layer — your changes go here
Layer 4 (Read-Only)   ← COPY app/ /app/
Layer 3 (Read-Only)   ← RUN pip install requirements.txt
Layer 2 (Read-Only)   ← COPY requirements.txt .
Layer 1 (Read-Only)   ← FROM python:3.11-slim
```

**How OverlayFS works:**
- `lowerdir` = all read-only layers stacked
- `upperdir` = container's writable layer
- `merged` = unified view shown to the container

When a container writes to a file that exists in a lower layer: **copy-on-write** — the file is copied to the upperdir, then modified. The original lower layer is unchanged.

**Practical implication:** Multiple containers sharing the same base image share read-only layers → disk efficient. Each container only stores its unique changes.

---

## 3. Dockerfile Best Practices

### Q: What is a multi-stage build and why use it?

Multi-stage builds reduce final image size by separating build-time dependencies from runtime.

```dockerfile
# Stage 1: Builder (has all build tools)
FROM golang:1.21 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

# Stage 2: Final image (minimal runtime)
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

Without multi-stage: final image includes Go compiler, build tools, source code → 800MB+
With multi-stage: only the compiled binary in a distroless base → 10-20MB

### Q: What are the key Dockerfile optimisations?

```dockerfile
# 1. Order layers by change frequency (stable → frequently changing)
#    Put RUN pip install BEFORE COPY app/ — so pip install is cached
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .          # ← rarely changes
RUN pip install -r requirements.txt   # ← cached when requirements.txt unchanged
COPY . .                         # ← changes often, doesn't invalidate pip layer

# 2. Combine RUN commands to reduce layers
RUN apt-get update && apt-get install -y \
    curl wget git \
    && rm -rf /var/lib/apt/lists/*   # clean apt cache in same layer

# 3. Use .dockerignore
# .dockerignore:
# .git/
# __pycache__/
# *.pyc
# node_modules/
# .env

# 4. Use non-root user
RUN useradd -r -u 1001 appuser
USER 1001

# 5. Use specific base image tags, not 'latest'
FROM python:3.11.9-slim   # not python:latest
```

### Q: ENTRYPOINT vs CMD — what is the difference?

| | `CMD` | `ENTRYPOINT` |
|---|---|---|
| Purpose | Default arguments | Fixed executable |
| Override | `docker run image new-command` replaces CMD | `docker run --entrypoint new-cmd image` required |
| Combined | ENTRYPOINT + CMD = executable + default args | |

```dockerfile
ENTRYPOINT ["python", "app.py"]   # fixed — always runs python app.py
CMD ["--port", "8080"]            # default args — can be overridden

# docker run myimage → python app.py --port 8080
# docker run myimage --port 9090 → python app.py --port 9090
# docker run myimage --debug → python app.py --debug
```

Use **ENTRYPOINT** when the container should always run one specific executable.
Use **CMD** alone when you want to allow full command override.

---

## 4. Docker Networking

### Q: What are Docker networking modes?

| Mode | What it does | Use case |
|---|---|---|
| **bridge** (default) | Creates `docker0` bridge. Containers get private IP. NAT for outbound. | Single-host container communication |
| **host** | Container shares host network stack. No NAT, same IP. | Performance-critical, low latency |
| **overlay** | Multi-host networking (Docker Swarm). VxLAN tunnels. | Distributed applications across hosts |
| **none** | No network interface. | Maximum isolation, security scanning |
| **macvlan** | Container gets its own MAC address on host network. | Legacy apps expecting direct LAN access |

```bash
# Create custom bridge network (containers can resolve each other by name)
docker network create myapp-network
docker run --network myapp-network --name db postgres
docker run --network myapp-network --name app my-app
# 'app' container can reach 'db' by hostname "db" via Docker DNS
```

### Q: How does Docker DNS work?

Custom user-defined bridge networks get automatic DNS resolution. Containers resolve each other by container name or service name.

Default `docker0` bridge: no automatic DNS — containers only communicate by IP.

This is why docker-compose creates a custom network automatically — so services can reference each other by name (`db`, `redis`, `app`).

---

## 5. Container Security

### Q: What are the main container security concerns?

**1. Running as root:**
```dockerfile
# Bad — runs as root inside container
FROM node:18
COPY . .
CMD ["node", "server.js"]

# Good — non-root user
FROM node:18
RUN useradd -r -u 1001 nodeuser
USER 1001
COPY --chown=nodeuser:nodeuser . .
CMD ["node", "server.js"]
```

**2. Privileged containers:**
```yaml
# Never do this unless absolutely required
securityContext:
  privileged: true   # ← full host access, defeats all isolation
```

**3. Capabilities:**
Containers get a subset of Linux capabilities by default. Always drop all, add only what's needed:
```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]  # Only if binding to port < 1024
```

**4. Read-only filesystem:**
```yaml
securityContext:
  readOnlyRootFilesystem: true   # Prevents writing to container filesystem
```

**5. Image scanning:**
```bash
# Trivy — scan image for CVEs
trivy image my-app:v1.2
```

### Q: What is the difference between a container and a VM?

| | Container | VM |
|---|---|---|
| Isolation | Kernel namespaces + cgroups | Hypervisor + guest kernel |
| Boot time | Milliseconds | Seconds to minutes |
| OS | Shares host kernel | Full guest OS |
| Size | MBs | GBs |
| Overhead | Near-zero | ~10-20% CPU/memory overhead |
| Security boundary | Weaker (shared kernel) | Stronger (separate kernel) |

Containers are NOT VMs. A container escape (breaking out of namespace isolation via kernel exploit) gives host access. VMs require hypervisor exploit. For PCI-DSS workloads consider VMs or sandboxed containers (gVisor, Kata Containers).

---

## 6. Container Runtimes

### Q: Docker vs containerd vs CRI-O — what are the differences?

| | Docker | containerd | CRI-O |
|---|---|---|---|
| Type | Full platform (build + run + push) | Container runtime | Container runtime |
| CRI support | Via dockershim (removed K8s 1.24) | Native CRI plugin | Native CRI |
| Used by | Developers, local dev | Most Kubernetes (GKE, EKS, AKS) | OpenShift, some vanilla K8s |
| OCI compliant | Yes | Yes | Yes |

**OpenShift uses CRI-O** by default. CRI-O is purpose-built for Kubernetes — no Docker daemon, minimal attack surface.

**containerd** is used by most managed Kubernetes services (GKE, EKS, AKS default).

### Q: What is Podman and how is it different from Docker?

Podman is a daemonless container tool. Docker requires a running `dockerd` daemon (running as root). Podman runs containers directly without a daemon.

| Feature | Docker | Podman |
|---|---|---|
| Daemon | Required (dockerd) | None — each run is a direct fork |
| Root requirement | dockerd runs as root | Can run fully rootless |
| CLI compatibility | `docker` | `alias docker=podman` works for most commands |
| Pods | No (Kubernetes concept only) | Yes — run multi-container pods locally |
| Security | dockerd socket = root access | Rootless by default |

On OpenShift / RHEL environments: Podman is the default tool. Docker isn't installed.

---

## 7. Common Debugging Commands

```bash
# Container basics
docker ps -a                          # all containers including stopped
docker logs <container> --tail 100 -f # follow logs
docker exec -it <container> sh        # shell inside running container
docker inspect <container>            # full JSON config including IPs, mounts

# Resource usage
docker stats                          # live CPU, memory, net I/O per container

# Image inspection
docker image history <image>          # show layers and sizes
docker image inspect <image>          # full metadata

# Network debugging
docker network ls
docker network inspect bridge

# Cleanup
docker system prune -a --volumes      # remove all unused resources
docker image prune -a                 # remove untagged + unused images

# Copy files in/out
docker cp <container>:/path/to/file ./local-copy
docker cp ./local-file <container>:/path/

# Check container resource limits
docker inspect <container> | grep -i memory
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.usage_in_bytes
```

---

## Quick One-Liners

| Question | Answer |
|---|---|
| What is containerd? | Industry-standard container runtime — manages lifecycle; Docker and Kubernetes both use it |
| What are namespaces? | Linux kernel feature providing process, network, filesystem isolation |
| What are cgroups? | Linux kernel feature limiting CPU, memory, I/O for a group of processes |
| What is OverlayFS? | Union filesystem stacking read-only image layers under a read-write container layer |
| What is copy-on-write? | Container modifying a file from a base layer gets a private copy — base layer unchanged |
| What is a multi-stage build? | Use multiple FROM stages; final image only gets artefacts from build stage — smaller size |
| Why non-root in containers? | UID 0 inside container = UID 0 on host if namespace escapes; run as UID 1000+ |
| What is privileged container? | Full host access, defeats isolation — avoid except for system-level tools |
| Docker vs VM? | Container = process with namespace isolation; VM = full OS with hypervisor |
| What is Podman? | Daemonless, rootless alternative to Docker; default on RHEL/OpenShift |
