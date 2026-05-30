# Linux Performance & Troubleshooting Interview Guide

**Target Role:** Principal Platform Engineer / SRE Lead
**Why this matters:** Every SRE interview has Linux fundamentals. Expect 3-5 questions on production troubleshooting.

---

## 1. The Golden Rule — USE Method

For any performance problem, follow the **USE Method** (Brendan Gregg):

- **U**tilisation — how busy is the resource? (% time busy)
- **S**aturation — how much work is queued? (queue depth)
- **E**rrors — any error events?

Apply to: CPU, Memory, Disk, Network, every resource.

Before running any command, state which resource you're investigating and which USE dimension you're checking.

---

## 2. CPU Troubleshooting

### Q: How do you investigate high CPU on a Linux server?

```bash
# Step 1: Top-level overview
top           # press 'P' to sort by CPU, '1' for per-CPU view
htop          # better TUI — shows per-CPU bars, tree view

# Step 2: Identify which process
ps aux --sort=-%cpu | head -20

# Step 3: Load average
uptime
# Output: load average: 2.15, 1.87, 1.52  (1m, 5m, 15m)
# On a 4-core server: load > 4.0 = overloaded
# Rising trend (1m > 15m) = problem getting worse
# Falling trend = recovering

# Step 4: CPU type — user vs system vs iowait vs steal
vmstat 1 5
# us: user space    sy: kernel     wa: waiting for I/O    st: stolen by hypervisor
# High 'sy': system calls, context switching, kernel issue
# High 'wa': I/O bound, not CPU bound
# High 'st': noisy neighbour on VM host — cloud infrastructure issue

# Step 5: Context switching
vmstat 1 | awk '{print $12, $13}'  # cs = context switches, in = interrupts
# High context switches with low throughput = too many threads competing
```

### Q: What is load average and what does it actually mean?

Load average = number of processes in **runnable** state (running or waiting for CPU) + processes in **uninterruptible sleep** (waiting for I/O).

It is NOT CPU utilisation. A load average of 2.0 on a 4-core machine = 50% busy. On a 1-core machine = heavily overloaded.

**Rule of thumb:** Load average > number of CPU cores = potential bottleneck.

```bash
nproc                    # number of logical CPU cores
cat /proc/cpuinfo | grep "model name" | head -1
```

---

## 3. Memory Troubleshooting

### Q: How do you investigate a memory issue?

```bash
# Overview
free -h
# Output:
#               total    used    free   shared  buff/cache  available
# Mem:           31Gi    12Gi   4.2Gi   1.1Gi      15Gi      18Gi
# "available" is the right column — free + reclaimable cache
# "free" alone is misleading — Linux uses free RAM as cache (this is normal)

# Detailed breakdown
cat /proc/meminfo
# MemTotal, MemFree, MemAvailable, Buffers, Cached, SwapTotal, SwapUsed

# Which processes use most memory
ps aux --sort=-%mem | head -20
smem -s rss -r | head -20   # more accurate — shows PSS (proportional set size)
```

### Q: What is the difference between VSZ and RSS?

| | VSZ | RSS |
|---|---|---|
| Name | Virtual Size | Resident Set Size |
| What | All virtual memory mapped (including unloaded shared libs) | Physical RAM actually used |
| Reliability | Misleading — always much larger than RSS | Better indicator of actual memory usage |
| Shared libs | Counted once per process | Counted once per process (shared pages not separated) |

For accurate per-process memory, use **PSS (Proportional Set Size)**: shared memory divided proportionally across processes that map it. `smem` tool shows PSS.

### Q: What is the OOM Killer?

When the system runs out of memory, the kernel OOM (Out-Of-Memory) Killer selects a process to kill.

Selection algorithm: each process gets an `oom_score` (0-1000). Higher score = more likely to be killed. Score based on: memory usage, swap usage, process age, whether it's privileged.

```bash
# See OOM kill events
dmesg | grep -i "oom\|killed process"
journalctl -k | grep -i oom

# Check a process's OOM score
cat /proc/<pid>/oom_score

# Protect a process from OOM kill (set to -1000 = never kill)
echo -1000 > /proc/<pid>/oom_score_adj
# Or mark as candidate (1000 = kill first)
echo 1000 > /proc/<pid>/oom_score_adj
```

**In Kubernetes:** OOMKill = container's memory limit exceeded → container killed and restarted. Check via `kubectl describe pod` — look for `OOMKilled` in container state.

### Q: What is swap and should you use it on a Kubernetes node?

Swap allows the OS to move pages from RAM to disk when RAM is full.

**On Kubernetes nodes: disable swap** (or configure correctly in K8s 1.28+).
- Kubernetes scheduler makes pod placement decisions based on memory requests
- With swap, a pod can exceed its memory limit by using swap → unpredictable performance
- Swapping = disk I/O for memory access → latency spikes for containers

```bash
swapoff -a                              # disable immediately
# Also remove swap entry from /etc/fstab for persistence
```

---

## 4. Disk I/O Troubleshooting

### Q: How do you investigate disk I/O issues?

```bash
# Overview
iostat -xz 1
# r/s: reads/sec   w/s: writes/sec
# r_await: avg read latency (ms)    w_await: avg write latency (ms)
# %util: % time device was busy (100% = saturated)
# await > 10ms = slow disk    %util > 80% = disk bottleneck

# Which process is doing I/O
iotop -o           # only show processes with active I/O
iotop -oP          # by process (not thread)

# Disk space
df -h              # filesystem usage
du -sh /var/log/*  # find large directories

# Inode exhaustion (less common but tricky)
df -i              # check inode usage — can run out even with disk space free

# Find large files
find / -type f -size +1G 2>/dev/null | sort -k5 -rn
```

### Q: What causes high iowait and how do you fix it?

High `wa` in vmstat = CPU waiting for I/O to complete. Root causes:

1. **Slow disk** — HDD instead of SSD, or disk is failing
2. **High write throughput** — logs filling disk, large database writes
3. **NFS/network storage** — latency spikes on network attached storage
4. **Container logs** — containers writing too much to stdout/stderr (Docker/containerd writes to disk)

Fixes:
- Move to SSD storage
- Add read/write caching (LVM cache)
- Limit container log size (`--log-opt max-size=100m --log-opt max-file=3`)
- Move write-heavy workloads to dedicated volumes

---

## 5. Network Troubleshooting

### Q: Walk me through investigating "application is slow/unreachable"

```bash
# Step 1: Is it reachable at all?
ping <host>          # ICMP — not always reliable (firewalled)
telnet <host> <port> # TCP connectivity check
nc -zv <host> <port> # netcat — cleaner than telnet

# Step 2: DNS resolution
dig <hostname>       # check DNS resolution and latency
nslookup <hostname>
cat /etc/resolv.conf # check DNS server config

# Step 3: Routing
traceroute <host>    # where does it slow down?
mtr <host>           # continuous traceroute with packet loss

# Step 4: Is the port listening?
ss -tlnp             # listening TCP ports (ss replaces netstat)
ss -tlnp | grep 8080 # check specific port

# Step 5: Active connections
ss -s                # summary: total connections, states
ss -tp state ESTABLISHED # all established TCP connections

# Step 6: Packet capture
tcpdump -i eth0 port 8080 -w /tmp/capture.pcap  # capture to file
tcpdump -i eth0 host <ip> -n                     # live capture for host
```

### Q: What is the difference between `netstat` and `ss`?

`ss` (socket statistics) replaced `netstat`. It reads directly from kernel memory (not `/proc`), making it faster for large numbers of connections.

```bash
ss -tlnp    # TCP, listening, numeric, show process
ss -unlp    # UDP, listening, numeric, show process  
ss -s       # summary statistics
ss -o state established '( dport = :443 or sport = :443 )'  # filter by state/port
```

### Q: How do you troubleshoot DNS issues in Kubernetes?

```bash
# Test DNS from inside a pod
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Check CoreDNS is running
kubectl get pods -n kube-system | grep coredns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# Test service DNS resolution
kubectl exec -it <pod> -- nslookup <service-name>.<namespace>.svc.cluster.local

# Check /etc/resolv.conf inside pod
kubectl exec -it <pod> -- cat /etc/resolv.conf
# Should show: nameserver 10.96.0.10 (CoreDNS ClusterIP)
```

Common Kubernetes DNS issues:
- `ndots:5` in resolv.conf causes 5 DNS queries per lookup (add FQDN to avoid)
- CoreDNS overloaded — increase replicas or add NodeLocal DNSCache
- Search domain mismatch — pod queries wrong namespace

---

## 6. Process Management

### Q: What are the important Linux signals?

| Signal | Number | Default action | Common use |
|---|---|---|---|
| `SIGHUP` | 1 | Terminate | Reload config (nginx, syslog) |
| `SIGINT` | 2 | Terminate | Ctrl+C from terminal |
| `SIGKILL` | 9 | Terminate immediately | Cannot be caught/ignored — last resort |
| `SIGTERM` | 15 | Terminate gracefully | `kill <pid>` default — allows cleanup |
| `SIGSTOP` | 19 | Pause | Cannot be caught — suspends process |
| `SIGUSR1/2` | 10/12 | User-defined | Application-specific (e.g., nginx: reload workers) |

**Always try `SIGTERM` first.** Give the process 30 seconds to clean up. Only use `SIGKILL` if it won't stop.

In Docker/Kubernetes: `docker stop` / `kubectl delete pod` sends `SIGTERM`, waits `terminationGracePeriodSeconds` (default 30s), then `SIGKILL`.

### Q: How do you find what process has a port open?

```bash
ss -tlnp | grep :8080          # fastest
lsof -i :8080                  # shows PID, user, process name
fuser 8080/tcp                 # just the PID
```

### Q: What is a zombie process?

A zombie process has finished execution but its parent hasn't called `wait()` to read its exit status. It stays in the process table in `Z` state with no resource usage except a PID slot.

```bash
ps aux | awk '$8=="Z"'   # find zombies
```

If you have many zombies, the parent process is buggy (not reaping children). Kill the parent to clean up zombies — they'll be reparented to init which will reap them.

---

## 7. Systemd

### Q: How do you manage services with systemd?

```bash
# Service management
systemctl start nginx
systemctl stop nginx
systemctl restart nginx
systemctl reload nginx          # reload config without restart (SIGHUP)
systemctl status nginx          # show status + last 10 log lines
systemctl enable nginx          # start on boot
systemctl disable nginx

# Logs
journalctl -u nginx             # all logs for service
journalctl -u nginx -f          # follow (like tail -f)
journalctl -u nginx --since "1 hour ago"
journalctl -u nginx -n 100      # last 100 lines
journalctl -k                   # kernel messages only
journalctl --disk-usage         # how much disk journal uses

# List all services
systemctl list-units --type=service
systemctl list-units --failed   # only failed services
```

### Q: How do you write a systemd unit file?

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My Application
After=network.target         # start after network is up
Requires=postgresql.service  # fail if postgres not running

[Service]
Type=simple
User=appuser
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/bin/server --port 8080
ExecReload=/bin/kill -HUP $MAINPID    # nginx-style reload
Restart=on-failure
RestartSec=5
StandardOutput=journal                 # logs go to journald
StandardError=journal
Environment=ENV=production
EnvironmentFile=/opt/myapp/.env        # load env file

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload    # reload unit file changes
systemctl enable --now myapp.service
```

---

## 8. File System & Storage

### Q: What are inodes?

An inode stores metadata about a file: permissions, owner, timestamps, size, data block pointers. It does NOT store the filename.

The directory entry maps filename → inode number. This is why hard links work (multiple filenames pointing to same inode).

```bash
ls -i file.txt              # show inode number
stat file.txt               # full inode metadata
df -i                       # inode usage per filesystem
find / -inum <inode>        # find file by inode number
```

**Disk full but `df -h` shows space?** Check `df -i` — inode exhaustion. Can happen with many small files (logs, temp files). Fix: find and delete many-file directories.

### Q: What is the difference between hard links and soft links?

```bash
ln source.txt hardlink.txt      # hard link — same inode
ln -s source.txt softlink.txt   # soft link — new inode pointing to path
```

| | Hard link | Soft (symbolic) link |
|---|---|---|
| Works across filesystems | No | Yes |
| Works for directories | No (except `.` and `..`) | Yes |
| If target deleted | Still works (inode still referenced) | Dangling link — broken |
| Inode | Same as original | New inode with path |

---

## 9. Performance Investigation Script

A structured approach for any "server is slow" problem:

```bash
#!/bin/bash
# 60-second performance snapshot
echo "=== Uptime/Load ==="
uptime

echo "=== CPU (5 samples) ==="
vmstat 1 5

echo "=== Memory ==="
free -m

echo "=== Disk I/O ==="
iostat -xz 1 3

echo "=== Network ==="
ss -s

echo "=== Top CPU processes ==="
ps aux --sort=-%cpu | head -10

echo "=== Top memory processes ==="
ps aux --sort=-%mem | head -10

echo "=== Disk space ==="
df -h

echo "=== Recent kernel errors ==="
dmesg | tail -20 | grep -i "error\|warn\|fail\|oom"
```

---

## Quick One-Liners

| Question | Answer |
|---|---|
| What is load average? | Runnable + uninterruptible-sleep processes; not CPU %. Compare to core count. |
| What is iowait? | CPU % waiting for I/O — not actual CPU work. High = disk/network bottleneck. |
| What kills a process that ignores SIGTERM? | SIGKILL (signal 9) — cannot be caught or ignored |
| VSZ vs RSS? | VSZ = all virtual memory mapped; RSS = RAM actually used. RSS is more meaningful. |
| What is OOM Killer? | Kernel selects highest oom_score process to kill when RAM exhausted |
| `ss` vs `netstat`? | `ss` reads directly from kernel, faster. Use `ss` — `netstat` is deprecated. |
| What is a zombie process? | Finished process whose parent hasn't called wait() — PID held, no resources |
| Disk full but df shows space? | Inode exhaustion — `df -i` to confirm. Delete dirs with many small files. |
| What does `vmstat wa` mean? | CPU % spent waiting for I/O (iowait) — high value = I/O bottleneck not CPU |
| How to reload nginx without downtime? | `systemctl reload nginx` or `nginx -s reload` — sends SIGHUP to master process |
