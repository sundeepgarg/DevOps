# Ansible — Complete Detailed Guide

**Companion to:** `ansible_interview_guide.md` (Q&A format)
**This file covers:** Architecture, all common modules, Jinja2, loops, conditionals,
error handling, variables deep dive, collections, AWX/Tower, project structure, interview Q&A

---

## 1. How Ansible Works Internally

### Architecture — Agentless Design

```
Control Node                                    Managed Nodes
────────────                                    ──────────────
ansible.cfg
inventory/                                      Server A (SSH port 22)
  hosts.ini          SSH connection    ┌──────► /tmp/.ansible/tmp/
playbooks/        ──────────────────►  │           module_copy.py (executed)
roles/                                 │           results → stdout → back to control node
collections/                           │
                                       └──────► Server B
                                       └──────► Server C

No agent installed on managed nodes.
Ansible:
  1. Opens SSH connection to target
  2. Copies small Python module to /tmp/.ansible/tmp/ on target
  3. Executes the module with arguments
  4. Module runs, returns JSON result to stdout
  5. Ansible reads stdout → parses result → ok/changed/failed
  6. Cleans up temp files
  7. Closes SSH connection
```

### ansible.cfg — Configuration File

```ini
# ansible.cfg (searched in order: ./ansible.cfg, ~/.ansible.cfg, /etc/ansible/ansible.cfg)

[defaults]
inventory           = inventory/           # default inventory path
remote_user         = ansible              # default SSH user
private_key_file    = ~/.ssh/ansible_key   # default SSH key
roles_path          = roles:~/.ansible/roles  # where to look for roles
collections_path    = ~/.ansible/collections   # where collections are stored
host_key_checking   = false               # disable host key verification (dev only)
retry_files_enabled = false               # don't create .retry files
forks               = 20                  # parallel tasks (default: 5)
timeout             = 30                  # SSH timeout seconds
stdout_callback     = yaml                # output format: yaml, json, debug
callbacks_enabled   = timer, profile_tasks  # show task timing
gathering            = smart             # cache facts (only gather if not cached)
fact_caching         = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout = 3600              # facts cache TTL: 1 hour

[privilege_escalation]
become              = false              # don't become by default
become_method       = sudo               # use sudo (alt: su, pbrun, pfexec)
become_user         = root
become_ask_pass     = false

[ssh_connection]
pipelining          = true               # IMPORTANT: reduces SSH round-trips significantly
ssh_args            = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
control_path        = /tmp/ansible-ssh-%%h-%%p-%%r

[galaxy]
server_list         = automation_hub, galaxy
```

---

## 2. Inventory — All Formats

### INI Format (traditional)

```ini
# inventory/hosts.ini

# Ungrouped hosts
server1.example.com
192.168.1.10

# Group with alias
[web]
web01 ansible_host=10.0.1.1 ansible_user=ubuntu ansible_port=22
web02 ansible_host=10.0.1.2
web03 ansible_host=10.0.1.3 ansible_python_interpreter=/usr/bin/python3

# DB group with variables
[db]
db01 ansible_host=10.0.2.1 pg_port=5432 pg_data_dir=/var/lib/postgresql
db02 ansible_host=10.0.2.2

# Group of groups
[prod:children]
web
db

# Group variables
[web:vars]
nginx_port=80
app_port=8080
deploy_user=www-data

[prod:vars]
environment=production
log_level=WARN
```

### YAML Format (modern, recommended)

```yaml
# inventory/hosts.yml
all:
  vars:
    ansible_user: ansible
    ansible_ssh_private_key_file: ~/.ssh/ansible

  children:
    prod:
      vars:
        environment: production
      children:
        web:
          vars:
            nginx_port: 80
          hosts:
            web01:
              ansible_host: 10.0.1.1
            web02:
              ansible_host: 10.0.1.2
        db:
          hosts:
            db01:
              ansible_host: 10.0.2.1
              pg_port: 5432

    staging:
      vars:
        environment: staging
      hosts:
        staging01:
          ansible_host: 10.1.0.1
```

### group_vars and host_vars

```
inventory/
├── hosts.yml
├── group_vars/
│   ├── all.yml              ← applies to ALL hosts
│   ├── all/                 ← directory form — multiple files per group
│   │   ├── main.yml
│   │   └── vault.yml        ← encrypted secrets
│   ├── web.yml              ← applies to [web] group
│   ├── db.yml
│   └── prod.yml
└── host_vars/
    ├── web01.yml            ← applies only to web01
    └── db01.yml

# group_vars/all.yml
ntp_servers:
  - ntp1.example.com
  - ntp2.example.com
log_dir: /var/log/myapp

# group_vars/web.yml
nginx_worker_processes: auto
nginx_worker_connections: 1024

# host_vars/web01.yml
nginx_worker_processes: 8      # override for this specific host
```

### Dynamic Inventory

```yaml
# inventory/aws_ec2.yml — AWS dynamic inventory
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
  - eu-west-1
filters:
  instance-state-name: running
  "tag:Project": myapp
keyed_groups:
  - key: tags.Environment
    prefix: env
  - key: tags.Role
    prefix: role
  - key: placement.availability_zone
    prefix: az
compose:
  ansible_host: public_ip_address    # use public IP
  ansible_user: "ubuntu"

# Result: groups like env_production, role_web, az_us_east_1a
```

```bash
# Test dynamic inventory
ansible-inventory -i inventory/aws_ec2.yml --list
ansible-inventory -i inventory/aws_ec2.yml --graph

# Run against a dynamic group
ansible-playbook -i inventory/aws_ec2.yml site.yml --limit env_production:&role_web
```

---

## 3. Playbook — Full Anatomy

```yaml
---
# Multiple plays in one playbook
- name: Configure load balancers        # Play 1
  hosts: lb                             # which inventory group
  order: sorted                         # host execution order (default: inventory)
  become: true                          # run tasks as sudo
  become_user: root
  gather_facts: true                    # run setup module first (collect facts)
  gather_subset:                        # only collect specific facts (faster)
    - network
    - hardware
  any_errors_fatal: false               # continue other hosts if one fails
  max_fail_percentage: 20               # abort play if >20% of hosts fail
  serial: 5                             # process 5 hosts at a time (rolling)
  ignore_errors: false                  # play level (override per task)
  environment:                          # set env vars for all tasks in play
    HTTP_PROXY: "http://proxy.example.com:3128"
    NO_PROXY: "localhost,127.0.0.1"
  module_defaults:                      # default parameters for modules
    ansible.builtin.file:
      owner: www-data
      group: www-data
      mode: '0644'

  vars:
    app_version: "2.1.0"
    config_dir: /etc/myapp

  vars_files:                           # include external variable files
    - vars/common.yml
    - vars/{{ environment }}.yml        # dynamic file based on variable

  vars_prompt:                          # prompt user for input at runtime
    - name: admin_password
      prompt: "Enter admin password"
      private: true                     # don't echo input

  pre_tasks:                            # run before roles
    - name: Check disk space
      ansible.builtin.shell: df -h /
      register: disk_check

  roles:
    - common
    - { role: nginx, nginx_port: 443, when: "env == 'prod'" }

  tasks:                                # run after roles
    - name: Configure application
      include_tasks: tasks/configure.yml
      tags: configure

  post_tasks:                           # run after tasks
    - name: Send completion notification
      ansible.builtin.uri:
        url: "https://hooks.example.com/deploy"
        method: POST
        body_format: json
        body:
          status: "deployed"
          version: "{{ app_version }}"

  handlers:
    - name: Reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded

- name: Configure application servers   # Play 2
  hosts: app
  become: true
  tasks:
    - import_playbook: deploy.yml       # include another playbook
```

---

## 4. Essential Modules — Complete Reference

### 4.1 Package Management

```yaml
# apt — Debian/Ubuntu
- name: Install packages
  ansible.builtin.apt:
    name:
      - nginx
      - curl
      - git
    state: present          # present / absent / latest
    update_cache: true      # run apt-get update first
    cache_valid_time: 3600  # don't update if cache < 1hr old
    autoremove: true        # remove unused dependencies

- name: Remove a package
  ansible.builtin.apt:
    name: apache2
    state: absent
    purge: true             # also remove config files

# yum / dnf — RHEL/CentOS/Fedora
- name: Install packages (RHEL)
  ansible.builtin.yum:
    name:
      - httpd
      - php
    state: latest
    update_cache: true

# pip — Python packages
- name: Install Python packages
  ansible.builtin.pip:
    name:
      - requests
      - boto3
    state: latest
    virtualenv: /opt/myapp/venv         # install in virtualenv
    virtualenv_python: python3

# package — OS-agnostic (uses apt/yum/etc. based on OS)
- name: Install nginx (any distro)
  ansible.builtin.package:
    name: nginx
    state: present
```

### 4.2 File and Directory Operations

```yaml
# file — create directories, files, symlinks; set permissions
- name: Create application directory
  ansible.builtin.file:
    path: /opt/myapp
    state: directory        # directory / file / link / absent / touch
    owner: app_user
    group: app_group
    mode: '0755'
    recurse: true           # apply permissions recursively

- name: Create symlink
  ansible.builtin.file:
    src: /opt/myapp/current
    dest: /usr/local/bin/myapp
    state: link

- name: Delete file
  ansible.builtin.file:
    path: /tmp/old_config.conf
    state: absent

# copy — copy local file to remote
- name: Copy config file
  ansible.builtin.copy:
    src: files/nginx.conf    # relative to playbook/role files/ dir
    dest: /etc/nginx/nginx.conf
    owner: root
    group: root
    mode: '0644'
    backup: true             # backup existing file before overwriting
  notify: Restart nginx

# copy with inline content
- name: Create config from inline content
  ansible.builtin.copy:
    content: |
      [database]
      host = {{ db_host }}
      port = {{ db_port }}
    dest: /etc/myapp/db.conf
    mode: '0600'

# template — Jinja2 template rendering
- name: Deploy config from template
  ansible.builtin.template:
    src: templates/nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    owner: nginx
    group: nginx
    mode: '0644'
    validate: /usr/sbin/nginx -t -c %s  # validate before installing
  notify: Reload nginx

# fetch — copy file FROM remote TO control node
- name: Fetch log file for analysis
  ansible.builtin.fetch:
    src: /var/log/app/error.log
    dest: /tmp/logs/{{ inventory_hostname }}/   # saves as hostname/file
    flat: false

# find — find files matching criteria
- name: Find old log files
  ansible.builtin.find:
    paths: /var/log/myapp
    patterns: "*.log"
    age: 30d                 # older than 30 days
    recurse: true
  register: old_logs

- name: Delete old logs
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ old_logs.files }}"

# stat — check if file/directory exists, get info
- name: Check if config exists
  ansible.builtin.stat:
    path: /etc/myapp/config.yml
  register: config_file

- name: Deploy config only if missing
  ansible.builtin.template:
    src: config.yml.j2
    dest: /etc/myapp/config.yml
  when: not config_file.stat.exists

# lineinfile — manage single lines in a file
- name: Set max file descriptors
  ansible.builtin.lineinfile:
    path: /etc/security/limits.conf
    line: "* soft nofile 65536"
    state: present
    regexp: "^\\* soft nofile"   # replace if line matching regex exists

# blockinfile — manage multi-line blocks
- name: Add kernel parameters
  ansible.builtin.blockinfile:
    path: /etc/sysctl.conf
    marker: "# {mark} ANSIBLE MANAGED BLOCK - k8s"
    block: |
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
      vm.max_map_count = 262144

# replace — find and replace in file
- name: Update config value
  ansible.builtin.replace:
    path: /etc/myapp/config.ini
    regexp: "^timeout=.*"
    replace: "timeout=30"
```

### 4.3 Service Management

```yaml
# service — manage system services
- name: Ensure nginx is started and enabled
  ansible.builtin.service:
    name: nginx
    state: started          # started / stopped / restarted / reloaded
    enabled: true           # enable at boot

# systemd — more control over systemd units
- name: Enable and start kubelet
  ansible.builtin.systemd:
    name: kubelet
    state: started
    enabled: true
    daemon_reload: true     # run systemctl daemon-reload first

- name: Create systemd service
  ansible.builtin.template:
    src: myapp.service.j2
    dest: /etc/systemd/system/myapp.service
  notify:
    - Reload systemd
    - Restart myapp

# handlers for systemd
handlers:
  - name: Reload systemd
    ansible.builtin.systemd:
      daemon_reload: true

  - name: Restart myapp
    ansible.builtin.systemd:
      name: myapp
      state: restarted
```

### 4.4 Command Execution

```yaml
# command — run a command (no shell features)
- name: Initialize application database
  ansible.builtin.command:
    cmd: /opt/myapp/bin/init-db
    chdir: /opt/myapp          # working directory
    creates: /var/lib/myapp/.initialized  # skip if file exists (idempotent!)
  register: db_init_result

# shell — run in shell (supports pipes, redirection, glob)
- name: Get pod count
  ansible.builtin.shell: |
    kubectl get pods -n production --no-headers | wc -l
  register: pod_count
  changed_when: false          # command only reads, mark as never changed

- name: Conditional shell
  ansible.builtin.shell: |
    if [ -f /var/lock/myapp.lock ]; then
      echo "already running"
    else
      /opt/myapp/start.sh && touch /var/lock/myapp.lock
      echo "started"
    fi
  register: start_result
  changed_when: "'started' in start_result.stdout"

# script — copy local script to remote and execute
- name: Run deployment script
  ansible.builtin.script:
    cmd: scripts/deploy.sh --version {{ app_version }}
    executable: /bin/bash
  register: deploy_result

# raw — SSH command without Python (for systems without Python)
- name: Install Python on bare machine
  ansible.builtin.raw: apt-get install -y python3
  when: ansible_python_interpreter is not defined
```

### 4.5 User and Group Management

```yaml
# user — manage Linux users
- name: Create application user
  ansible.builtin.user:
    name: appuser
    comment: Application Service User
    shell: /sbin/nologin        # no interactive login
    home: /opt/myapp
    create_home: true
    system: true                # system account (low UID)
    groups:
      - docker
      - ssl-cert
    append: true                # add to groups, don't replace
    password: "{{ vault_appuser_password | password_hash('sha512') }}"
    password_expire_max: 90     # force password change after 90 days

- name: Remove old user
  ansible.builtin.user:
    name: olduser
    state: absent
    remove: true                # delete home directory

# group — manage groups
- name: Create application group
  ansible.builtin.group:
    name: appgroup
    gid: 2000
    state: present

# authorized_key — manage SSH authorized keys
- name: Add SSH key for deployment
  ansible.posix.authorized_key:
    user: ansible
    key: "{{ lookup('file', '~/.ssh/deploy_key.pub') }}"
    state: present
    exclusive: false            # don't remove other keys
```

### 4.6 Network and Web Requests

```yaml
# uri — HTTP requests (API calls, health checks, webhooks)
- name: Check application health
  ansible.builtin.uri:
    url: "http://{{ inventory_hostname }}:8080/health"
    method: GET
    status_code: 200
    return_content: true
    timeout: 10
  register: health_check
  retries: 5
  delay: 10
  until: health_check.status == 200

- name: Call API to deregister from load balancer
  ansible.builtin.uri:
    url: "https://lb.example.com/api/nodes/{{ inventory_hostname }}"
    method: DELETE
    headers:
      Authorization: "Bearer {{ lb_api_token }}"
      Content-Type: "application/json"
    status_code: [200, 204]     # accept either response

- name: POST JSON payload
  ansible.builtin.uri:
    url: "https://api.example.com/deploy"
    method: POST
    body_format: json
    body:
      service: payment-api
      version: "{{ app_version }}"
      environment: "{{ environment }}"
    headers:
      Authorization: "Bearer {{ api_token }}"

# get_url — download files
- name: Download application binary
  ansible.builtin.get_url:
    url: "https://releases.example.com/myapp-{{ app_version }}.tar.gz"
    dest: /tmp/myapp.tar.gz
    checksum: "sha256:abc123..."   # verify integrity
    mode: '0644'

# wait_for — wait for port, file, or condition
- name: Wait for application to start
  ansible.builtin.wait_for:
    port: 8080
    host: "{{ inventory_hostname }}"
    timeout: 60
    state: started

- name: Wait for file to appear
  ansible.builtin.wait_for:
    path: /var/run/myapp.pid
    timeout: 30

# wait_for_connection — wait for SSH to be available (after reboot)
- name: Reboot server
  ansible.builtin.reboot:
    reboot_timeout: 300

- name: Wait for SSH after reboot
  ansible.builtin.wait_for_connection:
    timeout: 120
```

### 4.7 Archive and Unarchive

```yaml
# unarchive — extract archives on remote
- name: Extract application tarball
  ansible.builtin.unarchive:
    src: files/myapp-2.1.0.tar.gz    # local file
    dest: /opt/myapp/
    owner: appuser
    group: appgroup
    creates: /opt/myapp/bin/myapp    # skip if already extracted

- name: Download and extract from URL
  ansible.builtin.unarchive:
    src: "https://releases.example.com/myapp-{{ app_version }}.tar.gz"
    dest: /opt/myapp/
    remote_src: false              # src is local file
    extra_opts: ['--strip-components=1']

# archive — create archive on remote
- name: Archive logs for backup
  community.general.archive:
    path: /var/log/myapp/
    dest: "/backup/logs-{{ ansible_date_time.date }}.tar.gz"
    format: gz
    remove: false
```

### 4.8 Kubernetes Modules

```yaml
# kubernetes.core.k8s — manage K8s resources
- name: Create namespace
  kubernetes.core.k8s:
    kind: Namespace
    name: my-app
    state: present
    kubeconfig: /etc/kubernetes/admin.conf

- name: Deploy application
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: my-app
        namespace: my-app
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: my-app
        template:
          metadata:
            labels:
              app: my-app
          spec:
            containers:
              - name: app
                image: "my-registry/my-app:{{ app_version }}"
                ports:
                  - containerPort: 8080

- name: Apply manifest file
  kubernetes.core.k8s:
    src: manifests/deployment.yml
    state: present
    namespace: my-app

- name: Apply directory of manifests
  kubernetes.core.k8s:
    src: "{{ item }}"
    state: present
  with_fileglob:
    - manifests/*.yml

# kubernetes.core.k8s_info — get resource info
- name: Get pod info
  kubernetes.core.k8s_info:
    kind: Pod
    namespace: my-app
    label_selectors:
      - app = my-app
  register: pod_list

- name: Print pod names
  ansible.builtin.debug:
    msg: "{{ item.metadata.name }}"
  loop: "{{ pod_list.resources }}"

# kubernetes.core.helm — deploy Helm charts
- name: Deploy via Helm
  kubernetes.core.helm:
    name: my-app
    chart_ref: ./helm-chart
    release_namespace: my-app
    create_namespace: true
    values:
      image:
        repository: my-registry/my-app
        tag: "{{ app_version }}"
      replicaCount: 3
    wait: true
    wait_timeout: 5m
```

---

## 5. Variables — Deep Dive

### All Variable Sources

```yaml
# 1. Command line extra vars (highest precedence)
ansible-playbook site.yml -e "env=production app_version=2.1.0"
ansible-playbook site.yml -e "@vars/override.yml"  # from file

# 2. Task vars (per task)
- name: Task with inline vars
  ansible.builtin.template:
    src: config.j2
    dest: /etc/app/config
  vars:
    config_mode: strict

# 3. Play vars (per play)
- hosts: web
  vars:
    nginx_port: 80
    app_port: 8080

# 4. vars_files
- hosts: web
  vars_files:
    - vars/nginx.yml
    - "vars/{{ ansible_os_family }}.yml"  # OS-specific vars

# 5. Role vars (vars/main.yml) — high precedence, not for user override
# 6. Role defaults (defaults/main.yml) — lowest precedence, for user config

# 7. group_vars/all.yml → group_vars/groupname.yml → host_vars/hostname.yml

# 8. Facts (gathered automatically)
ansible_hostname, ansible_os_family, ansible_distribution,
ansible_default_ipv4.address, ansible_memory_mb.real.total
```

### register — Capture Task Output

```yaml
- name: Get current app version
  ansible.builtin.command: /opt/app/bin/app --version
  register: version_output
  changed_when: false

# version_output contains:
#   .stdout:      "myapp version 2.0.1"
#   .stderr:      ""
#   .rc:          0 (return code)
#   .stdout_lines: ["myapp version 2.0.1"]
#   .failed:      false
#   .changed:     false

- name: Show current version
  ansible.builtin.debug:
    msg: "Current version: {{ version_output.stdout }}"

- name: Deploy only if version is old
  ansible.builtin.include_tasks: deploy.yml
  when: "'2.0' in version_output.stdout"

# URI register
- name: Check API
  ansible.builtin.uri:
    url: http://localhost:8080/api/health
    return_content: true
  register: api_response

- name: Parse JSON response
  ansible.builtin.debug:
    msg: "Status: {{ api_response.json.status }}"
```

### Magic Variables (built-in)

```yaml
# inventory_hostname:     current host being processed
# inventory_hostname_short: without domain
# group_names:            list of groups current host belongs to
# groups:                 dict of all groups → host lists
# hostvars:               access any host's variables
# ansible_play_hosts:     list of hosts in current play
# playbook_dir:           directory of the playbook
# role_path:              directory of the current role
# ansible_check_mode:     true if running with --check flag

# Example: access another host's variable
- name: Get DB host address
  ansible.builtin.debug:
    msg: "DB is at {{ hostvars['db01']['ansible_host'] }}"

# Example: check group membership
- name: Apply web-specific config
  ansible.builtin.template:
    src: web-config.j2
    dest: /etc/app/web.conf
  when: "'web' in group_names"

# Example: run on first host only
- name: Run migration (once per play)
  ansible.builtin.command: /opt/app/migrate.sh
  when: inventory_hostname == ansible_play_hosts[0]
```

### set_fact — Create Variables Dynamically

```yaml
- name: Get app user details
  ansible.builtin.getent:
    database: passwd
    key: appuser
  register: user_info

- name: Set app user home as fact
  ansible.builtin.set_fact:
    app_user_home: "{{ user_info.ansible_facts.getent_passwd.appuser[4] }}"

- name: Use the dynamic fact
  ansible.builtin.file:
    path: "{{ app_user_home }}/.config"
    state: directory

# Set facts with cacheable: true (survives to next play/playbook)
- name: Set persistent fact
  ansible.builtin.set_fact:
    deployment_timestamp: "{{ ansible_date_time.iso8601 }}"
    cacheable: true
```

---

## 6. Jinja2 Templating

### Template Files (.j2)

```jinja2
{# templates/nginx.conf.j2 — comments use {# #} #}
user {{ nginx_user | default('nginx') }};
worker_processes {{ nginx_worker_processes | default('auto') }};

events {
    worker_connections {{ nginx_worker_connections | default(1024) }};
}

http {
    sendfile on;
    tcp_nopush on;

    {# Loop over upstream servers #}
    upstream backend {
        {% for host in groups['app'] %}
        server {{ hostvars[host]['ansible_host'] }}:{{ app_port }};
        {% endfor %}
    }

    {# Conditional block #}
    {% if ssl_enabled | default(false) %}
    server {
        listen 443 ssl;
        ssl_certificate {{ ssl_cert_path }};
        ssl_certificate_key {{ ssl_key_path }};
    }
    {% else %}
    server {
        listen {{ nginx_port | default(80) }};
    }
    {% endif %}

    server {
        location / {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        {# Loop with loop.index for numbered entries #}
        {% for path in blocked_paths | default([]) %}
        location {{ path }} {
            return 403;
        }
        {% endfor %}
    }
}
```

### Filters — Transform Data

```yaml
# String filters
"hello world" | upper            → "HELLO WORLD"
"hello world" | title            → "Hello World"
"  spaces  " | trim              → "spaces"
"hello" | replace("l", "r")     → "herro"
"abc" | b64encode                → "YWJj"
"YWJj" | b64decode               → "abc"

# Default values
{{ variable | default("fallback") }}             → use fallback if undefined
{{ variable | default(omit) }}                   → omit parameter if undefined
{{ variable | default(None) | ternary("yes","no") }}

# Numbers
{{ 42 | abs }}                   → 42
{{ 3.7 | round }}                → 4
{{ 3.7 | round(0, 'floor') }}   → 3

# Lists
{{ [1,2,3] | length }}           → 3
{{ [3,1,2] | sort }}             → [1, 2, 3]
{{ [1,2,3] | reverse | list }}   → [3, 2, 1]
{{ [1,2,2,3] | unique }}         → [1, 2, 3]
{{ [1,2] | union([2,3]) }}       → [1, 2, 3]
{{ [1,2,3] | select('odd') | list }} → [1, 3]
{{ [1,2,3] | map('pow', 2) | list }} → [1, 4, 9]
{{ items | selectattr('state', 'eq', 'running') | list }}

# Dictionaries
{{ {'a':1,'b':2} | dict2items }}  → [{key:'a',value:1},{key:'b',value:2}]
{{ items | items2dict }}           → convert [{key,value}] list to dict
{{ my_dict | combine(extra_dict) }} → merge dicts

# Type conversion
{{ "123" | int }}                → 123
{{ 123 | string }}               → "123"
{{ "true" | bool }}              → True
{{ [1,2,3] | join(", ") }}       → "1, 2, 3"
{{ "a,b,c" | split(",") }}       → ["a", "b", "c"]

# Conditionals
{{ value | ternary("yes", "no") }}
{{ groups['web'] | length > 0 | ternary('has web hosts', 'no web hosts') }}

# Path and file
{{ "/etc/nginx/nginx.conf" | basename }}   → "nginx.conf"
{{ "/etc/nginx/nginx.conf" | dirname }}    → "/etc/nginx"
{{ path | expanduser }}                    → expand ~

# Passwords and hashing
{{ "password" | password_hash('sha512') }}
{{ "password" | password_hash('sha512', 'mysalt') }}
{{ "data" | hash('sha256') }}
{{ "text" | md5 }}

# JSON
{{ my_dict | to_json }}
{{ my_dict | to_nice_json }}          → pretty-printed
{{ json_string | from_json }}
{{ my_dict | to_yaml }}
```

### Tests — Boolean Checks in Templates

```yaml
# In when conditions and templates:
when: my_var is defined
when: my_var is undefined
when: my_var is none
when: my_var is not none
when: result is failed
when: result is changed
when: result is success
when: result is skipped
when: path is file
when: path is directory
when: value is string
when: value is number
when: value is iterable
when: 5 is divisibleby 2     → false

# In templates:
{% if my_var is defined and my_var is not none %}
value = {{ my_var }}
{% endif %}
```

---

## 7. Loops and Conditionals

### Loops — loop (modern) and with_* (legacy)

```yaml
# Basic loop
- name: Install packages
  ansible.builtin.apt:
    name: "{{ item }}"
    state: present
  loop:
    - nginx
    - curl
    - git

# Loop with dict items
- name: Create users
  ansible.builtin.user:
    name: "{{ item.name }}"
    shell: "{{ item.shell | default('/bin/bash') }}"
    groups: "{{ item.groups | default([]) }}"
  loop:
    - { name: alice, shell: /bin/bash, groups: [sudo, docker] }
    - { name: bob,   shell: /bin/sh }
    - { name: svc_app, shell: /sbin/nologin }

# Loop index (loop.index starts at 1, loop.index0 at 0)
- name: Print numbered items
  ansible.builtin.debug:
    msg: "Item {{ loop.index }}: {{ item }}"
  loop: "{{ my_list }}"

# Loop control — label for cleaner output
- name: Deploy services
  ansible.builtin.template:
    src: "{{ item.name }}.conf.j2"
    dest: "/etc/services/{{ item.name }}.conf"
  loop: "{{ services }}"
  loop_control:
    label: "{{ item.name }}"   # show this in output instead of full item

# Loop over dict
- name: Set environment variables
  ansible.builtin.lineinfile:
    path: /etc/environment
    line: "{{ item.key }}={{ item.value }}"
  loop: "{{ env_vars | dict2items }}"

# Nested loops — with_nested (legacy) / loop + product filter
- name: Configure firewall rules
  ansible.builtin.iptables:
    chain: INPUT
    protocol: "{{ item[0] }}"
    destination_port: "{{ item[1] }}"
    jump: ACCEPT
  loop: "{{ ['tcp', 'udp'] | product([80, 443, 8080]) | list }}"

# until — retry loop
- name: Wait for service to respond
  ansible.builtin.uri:
    url: "http://localhost:8080/health"
    status_code: 200
  register: result
  until: result.status == 200
  retries: 10
  delay: 5                 # wait 5 seconds between retries

# Loop over files in directory
- name: Process all config files
  ansible.builtin.include_tasks: process_config.yml
  loop: "{{ query('fileglob', 'configs/*.yml') }}"
  loop_control:
    loop_var: config_file   # use different var name than 'item'
```

### Conditionals — when

```yaml
# Simple condition
- name: Install on Debian only
  ansible.builtin.apt:
    name: nginx
  when: ansible_os_family == "Debian"

# Multiple conditions (AND)
- name: Configure for production
  ansible.builtin.template:
    src: prod.conf.j2
    dest: /etc/app/config
  when:
    - environment == "production"
    - ansible_memory_mb.real.total >= 4096
    - app_version is defined

# OR condition
- name: Handle RHEL-family
  ansible.builtin.yum:
    name: nginx
  when: >
    ansible_distribution == "CentOS" or
    ansible_distribution == "RedHat" or
    ansible_distribution == "Rocky"

# Registered variable condition
- name: Check if app is running
  ansible.builtin.command: pgrep myapp
  register: app_check
  ignore_errors: true
  changed_when: false

- name: Start app if not running
  ansible.builtin.service:
    name: myapp
    state: started
  when: app_check.rc != 0

# Condition with filter
- name: Deploy if version changed
  ansible.builtin.include_tasks: deploy.yml
  when: current_version.stdout != desired_version

# Condition in loop
- name: Install optional packages
  ansible.builtin.apt:
    name: "{{ item.name }}"
  loop: "{{ packages }}"
  when: item.required | default(true)
```

---

## 8. Error Handling — Complete Patterns

### ignore_errors and failed_when

```yaml
# ignore_errors — continue play even if task fails
- name: Try to stop service (may not exist)
  ansible.builtin.service:
    name: old-service
    state: stopped
  ignore_errors: true

# failed_when — custom failure condition
- name: Run database migration
  ansible.builtin.command: /opt/app/migrate.sh
  register: migration_result
  failed_when:
    - migration_result.rc != 0
    - "'already applied' not in migration_result.stdout"  # not a failure if already applied

# changed_when — control "changed" status
- name: Check cluster status
  ansible.builtin.command: kubectl cluster-info
  register: cluster_status
  changed_when: false    # this command never changes anything

# Treat stderr as not an error (some tools write info to stderr)
- name: Run tool that writes to stderr
  ansible.builtin.command: my-tool --verbose
  register: tool_output
  failed_when: tool_output.rc != 0   # only fail on non-zero exit
```

### block / rescue / always — Try/Catch/Finally

```yaml
- name: Deploy application with error handling
  block:
    - name: Stop current version
      ansible.builtin.service:
        name: myapp
        state: stopped

    - name: Deploy new version
      ansible.builtin.unarchive:
        src: /tmp/myapp-{{ app_version }}.tar.gz
        dest: /opt/myapp/

    - name: Run migrations
      ansible.builtin.command: /opt/myapp/migrate.sh

    - name: Start new version
      ansible.builtin.service:
        name: myapp
        state: started

    - name: Verify health
      ansible.builtin.uri:
        url: http://localhost:8080/health
        status_code: 200
      retries: 5
      delay: 10

  rescue:
    - name: Log failure
      ansible.builtin.debug:
        msg: "Deployment failed: {{ ansible_failed_task.name }}"

    - name: Roll back to previous version
      ansible.builtin.command: /opt/myapp/rollback.sh

    - name: Restart previous version
      ansible.builtin.service:
        name: myapp
        state: started

    - name: Notify on-call
      ansible.builtin.uri:
        url: "https://pagerduty.com/api/..."
        method: POST
        body_format: json
        body:
          summary: "Deployment failed on {{ inventory_hostname }}"

  always:
    - name: Clean up temp files
      ansible.builtin.file:
        path: /tmp/myapp-{{ app_version }}.tar.gz
        state: absent

    - name: Send completion status
      ansible.builtin.uri:
        url: "https://deploy-tracker.example.com/update"
        method: POST
        body_format: json
        body:
          host: "{{ inventory_hostname }}"
          version: "{{ app_version }}"
          status: "{{ 'success' if not ansible_failed_task is defined else 'failed' }}"
```

---

## 9. Tags — Selective Task Execution

```yaml
- name: Install and configure nginx
  hosts: web
  tasks:
    - name: Install nginx
      ansible.builtin.apt:
        name: nginx
      tags:
        - install
        - nginx

    - name: Configure nginx
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
      tags:
        - configure
        - nginx

    - name: Deploy SSL certs
      ansible.builtin.copy:
        src: "files/ssl/{{ inventory_hostname }}.crt"
        dest: /etc/nginx/ssl/
      tags:
        - ssl
        - configure

    - name: Start nginx
      ansible.builtin.service:
        name: nginx
        state: started
      tags:
        - start
        - always     # 'always' tag runs EVEN with --tags (unless --skip-tags always)
```

```bash
# Run only install tasks
ansible-playbook site.yml --tags install

# Run only nginx-related tasks
ansible-playbook site.yml --tags nginx

# Run multiple tags (OR)
ansible-playbook site.yml --tags "install,configure"

# Skip specific tags
ansible-playbook site.yml --skip-tags ssl

# List all tags in playbook
ansible-playbook site.yml --list-tags

# Dry run (check mode) for specific tag
ansible-playbook site.yml --tags configure --check
```

---

## 10. Handlers — Complete Guide

```yaml
# Handlers are like tasks but only run when notified, and run ONCE at end of play
# Even if notified multiple times, they run once

tasks:
  - name: Update nginx config
    ansible.builtin.template:
      src: nginx.conf.j2
      dest: /etc/nginx/nginx.conf
    notify:
      - Validate nginx config
      - Reload nginx            # runs after validation

  - name: Update SSL certificate
    ansible.builtin.copy:
      src: ssl.crt
      dest: /etc/nginx/ssl/
    notify: Reload nginx        # won't run twice even though notified again

  - name: Force handlers to run NOW (not at end of play)
    ansible.builtin.meta: flush_handlers

handlers:
  - name: Validate nginx config
    ansible.builtin.command: nginx -t
    register: nginx_test
    failed_when: nginx_test.rc != 0
    listen: Validate nginx config   # can have multiple triggers

  - name: Reload nginx
    ansible.builtin.service:
      name: nginx
      state: reloaded
    listen: Reload nginx

  # Handlers run in DEFINITION ORDER, not notification order
  # Validate always runs before Reload because it's defined first
```

---

## 11. include_tasks vs import_tasks vs import_playbook

```yaml
# import_tasks — static (parsed at load time)
# - Tags on import apply to ALL tasks inside
# - Cannot use variables in filename
# - All tasks visible in --list-tasks output
- name: Configure application
  import_tasks: tasks/configure.yml
  tags: configure          # applies to ALL tasks in configure.yml

# include_tasks — dynamic (resolved at runtime)
# - Variables CAN be used in filename
# - Tags don't propagate automatically
# - Tasks only visible when loop runs
- name: Include OS-specific tasks
  include_tasks: "tasks/{{ ansible_os_family | lower }}.yml"

- name: Include tasks with loop
  include_tasks: tasks/configure_service.yml
  loop: "{{ services }}"
  loop_control:
    loop_var: current_service

# import_role — static role include
- name: Apply security role
  import_role:
    name: security
  vars:
    hardening_level: strict

# include_role — dynamic role include (supports conditional inclusion)
- name: Apply optional monitoring role
  include_role:
    name: monitoring
  when: install_monitoring | default(false)

# import_playbook — include another playbook (play level)
- import_playbook: playbooks/database.yml
- import_playbook: playbooks/web.yml
```

---

## 12. delegate_to and local_action

```yaml
# delegate_to — run task on a different host
- name: Drain node from load balancer (runs on control node, not target)
  ansible.builtin.uri:
    url: "http://lb.example.com/api/drain/{{ inventory_hostname }}"
    method: POST
  delegate_to: localhost

- name: Add DNS record (runs on DNS server, not target)
  ansible.builtin.command: >
    nsupdate -k /etc/named/rndc.key << EOF
    update add {{ inventory_hostname }}.example.com 300 A {{ ansible_host }}
    send
    EOF
  delegate_to: dns01.example.com

# delegate_to: localhost is so common it has a shorthand
- name: Check external API
  local_action:
    module: ansible.builtin.uri
    url: "https://api.example.com/status"
    method: GET

# run_once — execute only once even if multiple hosts match
- name: Run database migration (only needs to run once)
  ansible.builtin.command: /opt/app/migrate.sh
  run_once: true
  delegate_to: "{{ groups['db'][0] }}"   # run on first DB host

# delegate_facts — gather facts and store under delegated host
- name: Gather facts about DB servers
  ansible.builtin.setup:
  delegate_to: "{{ item }}"
  delegate_facts: true
  loop: "{{ groups['db'] }}"
```

---

## 13. Async Tasks

```yaml
# For long-running tasks: fire and forget, then poll for completion

- name: Start long-running OS patching
  ansible.builtin.yum:
    name: "*"
    state: latest
  async: 3600        # allow up to 1 hour
  poll: 0            # don't wait — continue to next task immediately
  register: patch_job

- name: Do other tasks while patching runs...
  ansible.builtin.debug:
    msg: "Patching is running in background (job id: {{ patch_job.ansible_job_id }})"

- name: Check patch status
  ansible.builtin.async_status:
    jid: "{{ patch_job.ansible_job_id }}"
  register: patch_result
  until: patch_result.finished
  retries: 60
  delay: 30

- name: Fail if patching failed
  ansible.builtin.fail:
    msg: "Patching failed: {{ patch_result.stderr }}"
  when: patch_result.failed

# Async for parallel tasks across hosts with lower fork count
# Even with forks=5, 100 hosts can run the task at the same time
# then you poll each one for completion
```

---

## 14. Ansible Collections

### What Collections Are

```
Collections = packaged namespaces of modules, roles, plugins, playbooks.
Replaces the old "galaxy roles" model.

Format: namespace.collection_name
  ansible.builtin      ← core Ansible modules (always available)
  community.general    ← community general purpose modules
  kubernetes.core      ← K8s, Helm, kubectl modules
  amazon.aws           ← AWS modules (EC2, S3, RDS, etc.)
  azure.azcollection   ← Azure modules
  community.docker     ← Docker modules
  ansible.posix        ← POSIX (Linux) modules
  community.crypto     ← cryptography, certificate modules
```

### Installing Collections

```bash
# Install from Ansible Galaxy
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install amazon.aws
ansible-galaxy collection install community.general

# Install specific version
ansible-galaxy collection install kubernetes.core:==2.3.0

# Install from requirements file
cat requirements.yml
collections:
  - name: kubernetes.core
    version: ">=2.3.0"
  - name: amazon.aws
    version: ">=6.0.0"
  - name: community.general
  - name: azure.azcollection

ansible-galaxy collection install -r requirements.yml

# Install to project-local path (not global)
ansible-galaxy collection install -r requirements.yml -p ./collections

# List installed collections
ansible-galaxy collection list
```

### Using Collections in Playbooks

```yaml
# Method 1: FQCN (Fully Qualified Collection Name) — recommended
- name: Create K8s namespace
  kubernetes.core.k8s:
    kind: Namespace
    name: my-ns

# Method 2: collections declaration (use short names within play)
- hosts: localhost
  collections:
    - kubernetes.core
    - amazon.aws
  tasks:
    - name: Create namespace
      k8s:                     # short name (collections list resolved)
        kind: Namespace
        name: my-ns

    - name: Create S3 bucket
      s3_bucket:               # short name
        name: my-bucket
```

---

## 15. Ansible Tower / AWX

### What Tower/AWX Is

```
Ansible Tower = Red Hat's commercial enterprise version of Ansible
AWX           = Open-source upstream of Tower (runs on Kubernetes)

Both provide:
  Web UI:            Run playbooks without CLI, visualise results
  RBAC:              Control who can run what playbook on what hosts
  API:               REST API + webhooks to trigger playbooks from CI/CD
  Credentials:       Encrypted storage for SSH keys, vault passwords, cloud creds
  Surveys:           Forms to collect variables before running a job
  Schedules:         Cron-based automation
  Notifications:     Email/Slack/Teams on job success/failure
  Job Templates:     Reusable playbook configurations
  Workflow Templates: Chain multiple job templates with conditional logic
  Inventories:       Sync from cloud, SCM, custom scripts
  Projects:          Sync playbooks from Git (GitHub, GitLab, Bitbucket)
```

### Key Concepts

```
Organization:     Top-level namespace. Separate teams/customers.

Project:          Git repo with playbooks.
                  Tower syncs the repo periodically or on demand.
                  Update on launch: auto-sync before every job.

Inventory:        List of hosts. Sources:
                  - Manual input
                  - Cloud source (AWS, Azure, GCP, VMware)
                  - Custom script (dynamic inventory)
                  - Project (inventory file in the Git repo)

Credentials:      Encrypted secrets (not visible after creation):
                  - SSH private key
                  - Ansible Vault password
                  - AWS/Azure/GCP credentials
                  - Container registry credentials
                  - GitHub token

Job Template:     Defines HOW to run a playbook:
                  - Which playbook
                  - Which inventory
                  - Which credentials
                  - Extra variables
                  - Concurrency limit

Workflow Template: Chain job templates:
                  success → next template
                  failure → alert/rollback template
                  Always: cleanup template

Survey:           Form presented before a job runs:
                  - "Target environment?" (dev/staging/prod dropdown)
                  - "Version to deploy?" (text input)
                  - "Skip tests?" (checkbox)
                  Variables from survey override playbook vars.
```

### Job Template via API (CI/CD Integration)

```bash
# Trigger a Tower job from GitHub Actions or CI/CD pipeline
curl -X POST https://tower.example.com/api/v2/job_templates/42/launch/ \
  -H "Authorization: Bearer <tower-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "extra_vars": {
      "app_version": "2.1.0",
      "environment": "production"
    }
  }'

# Response: {"id": 1234, "url": "/api/v2/jobs/1234/", "status": "pending"}

# Poll for completion
curl https://tower.example.com/api/v2/jobs/1234/ \
  -H "Authorization: Bearer <tower-token>"
# { "status": "successful" / "failed" / "running" }
```

### Workflow Template Example

```
[Update Code]  ──success──►  [Run Tests]  ──success──►  [Deploy Staging]
                                  │                            │
                                  │ failure                    │ success
                                  ▼                            ▼
                             [Notify Dev]              [Manual Approval] ──► [Deploy Prod]
                                                               │
                                                               │ failure / timeout
                                                               ▼
                                                          [Notify Team]
```

---

## 16. Project Directory Structure

```
ansible-project/
├── ansible.cfg                   ← project-level Ansible config
├── requirements.yml              ← collections and roles to install
│
├── inventory/
│   ├── production/
│   │   ├── hosts.yml            ← or hosts.ini
│   │   ├── group_vars/
│   │   │   ├── all.yml
│   │   │   ├── all/
│   │   │   │   ├── main.yml
│   │   │   │   └── vault.yml    ← ansible-vault encrypted
│   │   │   ├── web.yml
│   │   │   └── db.yml
│   │   └── host_vars/
│   │       └── web01.yml
│   ├── staging/
│   │   └── ... (same structure)
│   └── aws_ec2.yml              ← dynamic inventory config
│
├── playbooks/
│   ├── site.yml                 ← master playbook (imports all others)
│   ├── web.yml
│   ├── db.yml
│   └── deploy.yml
│
├── roles/
│   ├── common/                  ← applied to all hosts
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   ├── templates/
│   │   ├── files/
│   │   ├── vars/main.yml
│   │   ├── defaults/main.yml
│   │   └── meta/main.yml
│   ├── nginx/
│   ├── postgresql/
│   └── myapp/
│
├── collections/                  ← project-local collections (gitignore vendor)
│
├── library/                      ← custom modules
│   └── my_custom_module.py
│
├── filter_plugins/               ← custom Jinja2 filters
│   └── my_filters.py
│
├── scripts/
│   └── dynamic_inventory.py
│
└── molecule/                     ← testing (if not inside roles)
    └── default/
```

---

## 17. Interview Questions

### Q: What is idempotency and why is it critical in Ansible?

Idempotency means running a task multiple times produces the same result as running it once. If the desired state already exists, the task makes no changes.

Built-in modules are idempotent by design:
- `ansible.builtin.apt` with `state: present` — if package is installed, no change
- `ansible.builtin.file` — if directory exists with correct permissions, no change
- `ansible.builtin.service` — if service is started, no change

Why critical:
- **Safe to re-run:** if a playbook fails halfway, re-run from the start — completed tasks skip cleanly
- **No side effects:** running nightly cron job applying playbooks doesn't break running services
- **Predictable state:** cluster always converges to defined state regardless of history

How to make `command` and `shell` idempotent:
```yaml
# Use 'creates' to skip if result already exists
- ansible.builtin.command:
    cmd: /opt/app/init-db.sh
    creates: /var/lib/app/.initialized

# Use 'when' with registered check
- ansible.builtin.command: grep -q "configured" /etc/app.conf
  register: already_configured
  ignore_errors: true
  changed_when: false
- ansible.builtin.command: /opt/app/configure.sh
  when: already_configured.rc != 0
```

---

### Q: Explain Ansible variable precedence. Which one always wins?

From **lowest to highest** precedence:
1. Role defaults (`defaults/main.yml`) — meant to be overridden by users
2. Inventory file vars (`[group:vars]`)
3. `group_vars/` files
4. `host_vars/` files
5. Role vars (`vars/main.yml`) — internal constants, overrides group_vars
6. Play vars (vars: in playbook)
7. Task vars (vars: on individual task)
8. Set_fact / registered vars
9. `include_vars` task
10. **Extra vars (-e on CLI)** — ALWAYS WINS, cannot be overridden

Common bug: put configurable values in `vars/main.yml` instead of `defaults/main.yml`. Group_vars won't override role vars. Fix: move to `defaults/`.

Rule: user-configurable → `defaults/`, internal constants → `vars/`.

---

### Q: What is the difference between import and include in Ansible?

| | import_tasks / import_role | include_tasks / include_role |
|---|---|---|
| Resolution | Static — at parse time | Dynamic — at runtime |
| Variable in filename | No | Yes (`include_tasks: "{{ os }}.yml"`) |
| Tags propagation | Yes — parent tags apply to all inner tasks | No — need `apply: tags:` |
| Conditional (when) | Applied to each task individually | Entire include is skipped |
| Loop | No | Yes — can loop over includes |
| --list-tasks | All tasks visible | Only shown when reached |

Use `import_tasks` when: filename is static, you want tags to propagate.
Use `include_tasks` when: filename uses variables, inside a loop, conditional include.

---

### Q: How does Ansible handle secrets in production?

**Ansible Vault** encrypts files or individual strings. Vault password stored in:
- File (not committed to Git): `--vault-password-file ~/.vault_pass`
- CI/CD secret: `echo $VAULT_PASS > /tmp/vp && ansible-playbook --vault-password-file /tmp/vp`
- Multiple vault IDs (different passwords per environment): `--vault-id prod@prompt --vault-id dev@~/.dev_vault_pass`

**Better (production):** Don't store secrets in Git at all. Use lookups at runtime:
```yaml
# Fetch from HashiCorp Vault
db_password: "{{ lookup('hashi_vault', 'secret=prod/db/password:password') }}"

# Fetch from Azure Key Vault
db_password: "{{ lookup('azure.azcollection.azure_keyvault_secret', 'db-password', vault_url='https://myvault.vault.azure.net') }}"

# Fetch from AWS Secrets Manager
db_password: "{{ lookup('amazon.aws.aws_secret', 'prod/db/password', region='us-east-1') }}"
```

---

### Q: You need to patch 500 servers with minimal downtime. How do you design this with Ansible?

```yaml
- name: Rolling OS patch
  hosts: all_servers
  serial:
    - 1          # First: test on 1 server
    - 10%        # Then: batches of 10% at a time (50 servers)
  max_fail_percentage: 5    # abort if >5% of a batch fails

  pre_tasks:
    - name: Drain from load balancer
      ansible.builtin.uri:
        url: "{{ lb_api_url }}/drain/{{ inventory_hostname }}"
        method: POST
      delegate_to: localhost

  tasks:
    - name: Apply patches
      ansible.builtin.yum:
        name: "*"
        state: latest
      async: 3600
      poll: 30

    - name: Reboot if kernel was updated
      ansible.builtin.reboot:
        reboot_timeout: 300
      when: needs_reboot | default(false)

    - name: Verify services are running
      ansible.builtin.service_facts:
    - name: Assert critical services running
      ansible.builtin.assert:
        that:
          - "'kubelet' in services"
          - "services['kubelet'].state == 'running'"

  post_tasks:
    - name: Return to load balancer
      ansible.builtin.uri:
        url: "{{ lb_api_url }}/enable/{{ inventory_hostname }}"
        method: POST
      delegate_to: localhost
```

Key design: `serial` with test-then-batch pattern, LB drain/enable, service verification, max_fail_percentage.

---

## Quick Reference

```
Key commands:
  ansible -m ping all                           test connectivity
  ansible -m setup web01                        gather facts
  ansible-playbook site.yml --check             dry run
  ansible-playbook site.yml --diff              show config diffs
  ansible-playbook site.yml -v / -vvv           verbose output
  ansible-playbook site.yml --tags deploy       run tagged tasks
  ansible-playbook site.yml --limit web01       run on specific host
  ansible-playbook site.yml -e "var=val"        extra variables
  ansible-vault encrypt secrets.yml             encrypt file
  ansible-vault decrypt secrets.yml             decrypt file
  ansible-vault edit secrets.yml                edit encrypted
  ansible-doc -l                                list all modules
  ansible-doc ansible.builtin.template          module documentation
  ansible-galaxy collection install kubernetes.core  install collection

Important concepts:
  Idempotent:     same result every run, no side effects
  Agentless:      no agent on managed nodes (uses SSH/WinRM)
  Push model:     control node pushes tasks to managed nodes
  Handlers:       run once at end of play when notified
  Vault:          encrypted variables stored safely in Git
  Facts:          system info gathered by setup module
  Forks:          parallel task execution across hosts
  serial:         rolling batch size for zero-downtime ops
  delegate_to:    run a task on a different host
  register:       capture task output as variable
  run_once:       execute exactly once across all matched hosts
```
