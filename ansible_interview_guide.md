# Ansible Interview Guide

**Target Role:** Senior/Lead DevOps / Platform / MLOps Engineer  
**Background:** 12 years OpenShift/Kubernetes; Ansible for configuration management, OS hardening, app deployment

---

## 1. Core Concepts

### What is Ansible and how does it differ from Terraform?

Ansible is an **agentless, push-based configuration management and orchestration tool**. It uses SSH (Linux) or WinRM (Windows) to connect to targets and execute tasks.

| | Ansible | Terraform |
|---|---|---|
| Primary use | Configuration management, app deployment, orchestration | Infrastructure provisioning |
| State | Stateless (no state file) | Stateful (tfstate) |
| Language | YAML (Playbooks) | HCL |
| Execution model | Push (control node → targets) | Declarative reconciliation |
| Idempotency | Designed for it (most modules) | Built-in |
| Mutable infra | Yes — configures existing servers | No — prefers immutable |

**In platform/MLOps roles**, Ansible is used for:
- OS hardening and baseline config after Terraform creates VMs
- Kubernetes node configuration (sysctl, container runtime, kubelet flags)
- Deploying software not available as Helm charts
- OpenShift Day 2 operations (LDAP sync, certificate rotation, etcd backup)

### Key terminology

- **Playbook**: A YAML file defining what to do on which hosts — the main unit of execution
- **Play**: A section in a playbook that maps a set of tasks to a set of hosts
- **Task**: A single action (install package, copy file, start service)
- **Module**: The Python code that executes a task (`apt`, `yum`, `copy`, `template`, `shell`, etc.)
- **Role**: A reusable, structured collection of tasks, handlers, variables, and files
- **Inventory**: The list of target hosts (static file or dynamic script)
- **Handler**: A task triggered by `notify` — runs once at the end of a play if notified (e.g., restart nginx after config change)
- **Fact**: System info auto-gathered from targets (`ansible_os_family`, `ansible_default_ipv4`, etc.)

---

## 2. Inventory

### Static inventory

```ini
# inventory/hosts.ini
[web]
web01.example.com
web02.example.com ansible_user=ec2-user

[db]
db01.example.com ansible_host=10.0.1.5 ansible_port=2222

[prod:children]
web
db

[prod:vars]
ansible_python_interpreter=/usr/bin/python3
```

### Dynamic inventory

For cloud environments where IPs change, use dynamic inventory — a script or plugin that queries the cloud API at runtime.

**Azure dynamic inventory** (using `azure_rm` plugin):
```yaml
# inventory/azure_rm.yml
plugin: azure.azcollection.azure_rm
auth_source: auto           # Uses MSI or env vars
include_vm_resource_groups:
  - prod-rg
  - staging-rg
keyed_groups:
  - prefix: env
    key: tags.environment   # Group VMs by tag
  - prefix: role
    key: tags.role
```

Run: `ansible-inventory -i azure_rm.yml --list` — returns JSON of all VMs grouped by tags.

**Best practice for AKS/OpenShift**: Don't manage Kubernetes nodes with Ansible post-bootstrap. Use node pools / MachineConfig Operator for node config. Ansible is for bootstrap and for non-Kubernetes infrastructure.

### Scenario-Based Questions

**Q: You have 500 VMs in Azure spread across dev, staging, and production. How do you target only production web servers with a playbook?**

1. Tag VMs in Azure with `environment=production` and `role=web`
2. Use the `azure_rm` dynamic inventory plugin (groups VMs by tags)
3. Target with: `ansible-playbook -i azure_rm.yml site.yml --limit 'env_production:&role_web'`
   - `env_production` = all production hosts
   - `&role_web` = intersection with web hosts
4. Add `serial: 20%` in the playbook to roll updates in batches (avoid taking all 500 down simultaneously)

---

## 3. Playbooks

### Anatomy of a playbook

```yaml
---
- name: Configure web servers
  hosts: web
  become: true              # Escalate to sudo
  gather_facts: true        # Collect system facts first
  vars:
    nginx_port: 8080

  tasks:
    - name: Install nginx
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: true

    - name: Deploy nginx config
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        owner: root
        group: root
        mode: '0644'
      notify: Restart nginx

    - name: Ensure nginx is running and enabled
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true

  handlers:
    - name: Restart nginx
      ansible.builtin.service:
        name: nginx
        state: restarted
```

### Idempotency — the core principle

An Ansible task is idempotent if running it multiple times produces the same result as running it once. Most built-in modules are idempotent (`apt`, `copy`, `template`, `user`, `service`).

**The `shell` and `command` modules are NOT idempotent by default.** Make them idempotent with `creates` or `when`:
```yaml
- name: Initialize database (only if not already done)
  ansible.builtin.command:
    cmd: /opt/app/init-db.sh
    creates: /var/lib/app/.initialized  # Skip if this file exists
```

### Scenario-Based Questions

**Q: A playbook is failing on 3 of 50 hosts. You want the other 47 to continue. What do you configure?**

```yaml
- name: Deploy application
  hosts: app_servers
  max_fail_percentage: 10   # Abort if >10% of hosts fail
  any_errors_fatal: false   # Don't stop play on first failure
```

With `any_errors_fatal: false` and `max_fail_percentage: 10`, Ansible continues on the 47 successful hosts and only aborts if failures exceed the threshold. After the run, re-run with `--limit` on the 3 failed hosts after fixing the issue.

**Q: You need to deploy an application to 100 servers without downtime. How do you use Ansible to do a rolling update?**

```yaml
- name: Rolling deploy
  hosts: app_servers
  serial: 10               # Process 10 hosts at a time
  max_fail_percentage: 0   # Stop if any host fails in the batch

  tasks:
    - name: Remove from load balancer
      # Call LB API or shell command to drain this host

    - name: Stop application
      ansible.builtin.service:
        name: myapp
        state: stopped

    - name: Deploy new version
      ansible.builtin.unarchive:
        src: /tmp/myapp-v2.tar.gz
        dest: /opt/myapp/

    - name: Start application
      ansible.builtin.service:
        name: myapp
        state: started

    - name: Health check before adding back to LB
      ansible.builtin.uri:
        url: "http://{{ inventory_hostname }}:8080/health"
        status_code: 200
      retries: 5
      delay: 10

    - name: Add back to load balancer
      # Call LB API to add this host back
```

`serial: 10` means batches of 10 hosts at a time. Each batch must succeed before the next starts.

---

## 4. Roles

### What is a Role and why use them?

A role is a standardized directory structure that packages tasks, handlers, variables, files, and templates for a reusable, shareable unit:

```
roles/nginx/
├── tasks/
│   └── main.yml          # Entry point — executed when role is included
├── handlers/
│   └── main.yml
├── templates/
│   └── nginx.conf.j2
├── files/
│   └── ssl-cert.pem
├── vars/
│   └── main.yml          # Role-private vars (high precedence)
├── defaults/
│   └── main.yml          # Overridable defaults (lowest precedence)
├── meta/
│   └── main.yml          # Role metadata, dependencies
└── README.md
```

**Using a role in a playbook:**
```yaml
- hosts: web
  roles:
    - nginx
    - { role: ssl, when: "env == 'prod'" }
```

### Role best practices for senior engineers

1. **Defaults vs vars**: Put user-configurable settings in `defaults/main.yml` (low precedence, easily overridden). Put role-internal constants in `vars/main.yml` (high precedence, not meant to be overridden).
2. **Role dependencies**: Define in `meta/main.yml` — Ansible installs dependency roles from Ansible Galaxy automatically.
3. **Tag everything**: Add tags to task groups so users can run `--tags install` or `--tags configure` independently.
4. **Test with Molecule**: `molecule test` runs the role in a Docker container, applies it, and verifies with `testinfra` or `assert` tasks.

---

## 5. Variables and Precedence

### Variable precedence (lowest to highest)

The most common source of bugs in Ansible is variable precedence. Key levels (from lowest to highest):
1. Role defaults (`defaults/main.yml`)
2. Inventory file `[group:vars]`
3. Inventory `group_vars/` files
4. Inventory `host_vars/` files
5. Role vars (`vars/main.yml`)
6. Play vars (`vars:` in playbook)
7. Task vars (`vars:` on a task)
8. Extra vars (`-e` on command line) ← **always wins**

### Scenario-Based Questions

**Q: You set `nginx_port: 80` in `group_vars/web.yml` but the template keeps using the default value `8080`. Why?**

The task or role has `nginx_port: 8080` in `vars/main.yml` (role vars), which has higher precedence than `group_vars`. Solutions:
1. Move `nginx_port: 8080` to `defaults/main.yml` — group_vars will override defaults
2. Or explicitly pass it with `-e nginx_port=80` (extra vars always win)

Rule of thumb: If it's something users should configure, put it in `defaults/`. If it's a role-internal constant, put it in `vars/`.

---

## 6. Ansible Vault

### What is Ansible Vault?

Vault encrypts sensitive data (passwords, API keys, certificates) stored in files so they can be safely committed to Git.

```bash
# Encrypt a file
ansible-vault encrypt group_vars/prod/secrets.yml

# Edit in place (decrypts, opens editor, re-encrypts)
ansible-vault edit group_vars/prod/secrets.yml

# Encrypt a single string (embed in YAML)
ansible-vault encrypt_string 'MyP@ssword' --name 'db_password'

# Run playbook with vault password
ansible-playbook site.yml --vault-password-file ~/.vault_pass
# Or via environment variable
ANSIBLE_VAULT_PASSWORD_FILE=~/.vault_pass ansible-playbook site.yml
```

### Vault in CI/CD pipelines

In GitHub Actions:
```yaml
- name: Create vault password file
  run: echo "${{ secrets.ANSIBLE_VAULT_PASSWORD }}" > /tmp/vault_pass

- name: Run playbook
  run: |
    ansible-playbook -i inventory/ site.yml \
      --vault-password-file /tmp/vault_pass

- name: Clean up vault password
  if: always()
  run: rm -f /tmp/vault_pass
```

**Better alternative**: Use Ansible with Azure Key Vault via the `azure_keyvault_secret` lookup — no vault password needed, secrets fetched at runtime:
```yaml
vars:
  db_password: "{{ lookup('azure.azcollection.azure_keyvault_secret', 'db-password', vault_url='https://myvault.vault.azure.net') }}"
```

---

## 7. Ansible for Kubernetes / OpenShift

### OpenShift Day 2 operations with Ansible

This is directly relevant to Sundeep's background. Common Ansible use cases for OpenShift:

```yaml
# Example: Create OpenShift namespace + RBAC with Ansible
- hosts: localhost
  collections:
    - kubernetes.core

  tasks:
    - name: Create namespace
      kubernetes.core.k8s:
        api_version: v1
        kind: Namespace
        name: my-team-prod
        state: present

    - name: Apply resource quota
      kubernetes.core.k8s:
        definition:
          apiVersion: v1
          kind: ResourceQuota
          metadata:
            name: team-quota
            namespace: my-team-prod
          spec:
            hard:
              pods: "20"
              requests.cpu: "4"
              limits.memory: 8Gi

    - name: Apply RBAC from template
      kubernetes.core.k8s:
        template: rbac.yml.j2
```

**`kubernetes.core.k8s`** module: idempotent kubectl-equivalent. Supports `state: present/absent`, templates, entire manifest directories.

### Scenario-Based Questions

**Q: You need to rotate TLS certificates on 50 OpenShift nodes. How do you automate this with Ansible?**

```yaml
- name: Rotate node TLS certificates
  hosts: openshift_nodes
  serial: 5                  # 5 nodes at a time to preserve cluster quorum
  become: true

  tasks:
    - name: Check certificate expiry
      ansible.builtin.shell: |
        openssl x509 -in /etc/kubernetes/pki/node.crt -noout -enddate
      register: cert_expiry

    - name: Backup current cert
      ansible.builtin.copy:
        src: /etc/kubernetes/pki/node.crt
        dest: /etc/kubernetes/pki/node.crt.bak.{{ ansible_date_time.date }}
        remote_src: true

    - name: Request new certificate via CSR
      # ... generate CSR and submit to cluster CA

    - name: Verify new cert validity
      ansible.builtin.shell: |
        openssl verify -CAfile /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/node.crt
      register: cert_verify
      failed_when: "'OK' not in cert_verify.stdout"

    - name: Restart kubelet
      ansible.builtin.service:
        name: kubelet
        state: restarted
      notify: Wait for node ready

  handlers:
    - name: Wait for node ready
      ansible.builtin.command: |
        kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=120s
      delegate_to: localhost
```

Key design decisions: `serial: 5` to avoid quorum loss, backup before rotating, verify before restarting, wait for node Ready before moving to next batch.

---

## 8. Performance and Scale

### How do you speed up Ansible for large inventories?

**1. SSH multiplexing (ControlMaster)** — reuse SSH connections:
```ini
# ansible.cfg
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True            # Reduces SSH round trips
```

**2. Forks** — parallel task execution:
```ini
[defaults]
forks = 50                   # Default is 5 — increase for large fleets
```

**3. `gather_facts: false`** for playbooks that don't need facts (saves ~1-2s per host):
```yaml
- hosts: all
  gather_facts: false
```

**4. `async` tasks** for long-running operations — fire and poll:
```yaml
- name: Start long-running upgrade
  ansible.builtin.command: /opt/upgrade.sh
  async: 3600           # Max time allowed
  poll: 0               # Don't wait — fire and forget

- name: Check upgrade status
  ansible.builtin.async_status:
    jid: "{{ upgrade_result.ansible_job_id }}"
  register: job_result
  until: job_result.finished
  retries: 60
  delay: 30
```

**5. Mitogen strategy plugin** — alternative Python runner, 3–10x faster than default:
```ini
[defaults]
strategy_plugins = /path/to/mitogen/ansible_mitogen/plugins/strategy
strategy = mitogen_linear
```

---

## 9. Testing Ansible

### Molecule — the standard testing framework

```bash
molecule init role myrole   # Scaffold a role with molecule config
molecule test               # Full lifecycle: create → converge → verify → destroy
molecule converge           # Apply role to test instance
molecule verify             # Run assertions
molecule destroy            # Tear down test container
```

**`molecule/default/molecule.yml`** (Docker driver):
```yaml
driver:
  name: docker
platforms:
  - name: instance
    image: "ubuntu:22.04"

verifier:
  name: ansible           # Use Ansible tasks as assertions
```

**Verification tasks** (`molecule/default/verify.yml`):
```yaml
- name: Verify nginx installed and running
  hosts: all
  tasks:
    - name: Check nginx service
      ansible.builtin.service_facts:

    - name: Assert nginx is running
      ansible.builtin.assert:
        that:
          - "'nginx' in services"
          - "services['nginx'].state == 'running'"
```

---

## 10. Quick-Fire Concepts

**What is `delegate_to`?**  
Run a task on a different host than the current target. Common use: run `kubectl` or API calls from the control node while the play iterates over cluster nodes.
```yaml
- name: Drain node before maintenance
  ansible.builtin.command: kubectl drain {{ inventory_hostname }}
  delegate_to: localhost
```

**What is `block` / `rescue` / `always`?**  
Try/catch/finally equivalent:
```yaml
- block:
    - name: Attempt risky operation
      ansible.builtin.command: /opt/migrate.sh
  rescue:
    - name: Rollback on failure
      ansible.builtin.command: /opt/rollback.sh
  always:
    - name: Clean up temp files
      ansible.builtin.file:
        path: /tmp/migrate_lock
        state: absent
```

**What is `when` vs `failed_when` vs `changed_when`?**  
- `when`: Skip task if condition is false  
- `failed_when`: Override when a task is considered failed  
- `changed_when: false`: Tell Ansible a task never changes state (useful for read-only checks to avoid spurious "changed" status)

**What is the difference between `include_tasks` and `import_tasks`?**  
- `import_tasks`: Static — resolved at playbook parse time. Tags and conditions on the import apply to all tasks inside. Cannot use variables in the filename.  
- `include_tasks`: Dynamic — resolved at runtime. Variables can be used in the filename. `--tags` does not propagate into included tasks unless you use `apply: tags:`.

**How does Ansible handle Windows targets?**  
Uses WinRM (not SSH) by default, or SSH with OpenSSH enabled. Windows modules are prefixed `win_`: `win_package`, `win_service`, `win_copy`, `win_shell`. Inventory must specify `ansible_connection: winrm`.
