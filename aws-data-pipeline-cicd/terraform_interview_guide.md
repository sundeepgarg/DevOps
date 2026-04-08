# Terraform Interview Guide

This guide covers essential Terraform concepts, commands, and scenario-based interview questions to help you prepare for your DevOps Engineer interview.

---

## 1. Core Concepts

### What is Terraform?
Terraform is an open-source Infrastructure as Code (IaC) tool created by HashiCorp. It allows you to define, provision, and manage infrastructure declaratively using HashiCorp Configuration Language (HCL).

### Key Components
- **Providers:** Plugins that interact with cloud providers, SaaS providers, and other APIs (e.g., AWS, Azure, GCP, GitHub).
- **Resources:** The most important element in Terraform. Each resource block describes one or more infrastructure objects (e.g., an EC2 instance, an S3 bucket).
- **Data Sources:** Allow data to be fetched or computed for use elsewhere in Terraform configuration.
- **State File (`terraform.tfstate`):** A JSON file where Terraform maps real-world infrastructure to your configuration. It keeps track of metadata and improves performance for large infrastructures.
- **Modules:** Containers for multiple resources that are used together. They allow you to create reusable abstractions.

---

## 2. Essential Commands

| Command | Purpose |
| :--- | :--- |
| `terraform init` | Initializes a working directory containing Terraform configuration. Downloads required providers and modules. |
| `terraform fmt` | Rewrites configuration files to a canonical format and style. |
| `terraform validate` | Checks the formatting and syntax validity of the `.tf` files. |
| `terraform plan` | Creates an execution plan. Shows exactly what actions Terraform will take (add, change, destroy) without applying them. |
| `terraform apply` | Executes the actions proposed in a Terraform plan to reach the desired state. |
| `terraform destroy` | Destroys all remote objects managed by a particular Terraform configuration. |
| `terraform state <subcommand>` | Advanced state management (e.g., `list`, `mv`, `rm`, `show`). |
| `terraform import <resource> <id>` | Maps existing infrastructure (created manually) into Terraform's state so Terraform can manage it. |

*Note: In newer versions of Terraform, `terraform taint` is deprecated in favor of `terraform apply -replace="resource_name"`.*

---

## 3. Scenario-Based Questions

### Scenario 1: State Locking
**Question:** You and another engineer are working on the same Terraform project. You both run `terraform apply` at the exact same time. What happens, and how do you prevent conflicts?
**Answer:** Without state locking, you could corrupt the state file. To prevent this, standard practice is to configure a **Remote Backend** (like AWS S3) that supports state locking (via DynamoDB). When an operation starts, Terraform acquires a lock. The second engineer's command will fail with a lock error, preserving the state's integrity.

### Scenario 2: Handling Infrastructure Drift
**Question:** Someone manually SSH'd into an EC2 instance or logged into the AWS console and changed the instance type from `t2.micro` to `t2.large`. How does Terraform handle this?
**Answer:** This is called configuration drift. When you run `terraform plan`, Terraform will refresh its state by querying the real-world infrastructure. It will notice the instance is `t2.large` but the code says `t2.micro`. The plan will indicate an update is required to "correct" the instance back to `t2.micro` to match the code. (To keep the `t2.large`, you would need to update the Terraform code).

### Scenario 3: Secret Management
**Question:** How do you handle sensitive data (like database passwords or API keys) in Terraform?
**Answer:** 
1. **Never hardcode secrets** in `.tf` files. 
2. Pass secrets dynamically using environment variables (`TF_VAR_password`), CI/CD secrets (like GitHub Secrets), or AWS Secrets Manager / Parameter Store.
3. Mark variables as `sensitive = true` in the `variables.tf` file so Terraform redacts them from console output.
4. Keep the `.tfstate` file secure (encrypted remotely in S3) because state files keep variables in plain text.

### Scenario 4: Refactoring and Renaming Resources
**Question:** You need to rename a resource in your Terraform code from `aws_instance.web` to `aws_instance.app`. If you just change the name in the file and run `apply`, what happens? How *should* you do it?
**Answer:** 
- **What happens:** Terraform will destroy the old resource (`web`) and create an entirely new one (`app`), causing downtime.
- **How to do it properly:** Use the `terraform state mv` command to move the resource in the state file before running apply.
  `terraform state mv aws_instance.web aws_instance.app`
  Alternatively, use the `moved ` block introduced in Terraform 1.1 inside the code itself.

### Scenario 5: CI/CD Pipeline Implementation
**Question:** How would you design a CI/CD pipeline for Terraform?
**Answer:** *(This aligns perfectly with the project built for this interview)*
1. **Pull Request Event:** Run `terraform init`, `terraform fmt -check`, `terraform validate`, and `terraform plan`. Output the plan as a comment on the PR for review.
2. **Merge/Push to Main Event:** Run `terraform init` and `terraform apply -auto-approve`. 
3. Store the state remotely, ensure the CI/CD runner has an IAM Role (or uses OIDC) rather than static keys if possible, and enforce branch protections.

### Scenario 6: Terraform Import
**Question:** Your company has an S3 bucket that was created manually via the AWS Console 3 years ago. We now want to manage it with Terraform. How do you do that?
**Answer:** 
1. Write the resource block code for the S3 bucket in your `main.tf` file.
2. Run the `terraform import` command (e.g., `terraform import aws_s3_bucket.legacy_bucket my-bucket-name`).
3. Run `terraform plan`. It will show any discrepancies between your written code and the actual bucket settings. Adjust your code until the plan shows `No changes`.

---

## 4. Advanced Concepts

### Workspaces
- Workspaces allow you to manage multiple states in a single directory. It is useful for managing multiple environments (dev, staging, prod) using the same code. (Note: Using separate directories per environment is heavily preferred over workspaces in most large-scale architectures).

### `count` vs `for_each`
- **`count`:** Creates identical resources based on an integer. If you remove an item from the middle of a list, Terraform shifts the indices, which can accidentally destroy and recreate subsequent infrastructure.
- **`for_each`:** Creates resources based on a map or set of strings. It indexes resources by their key, making it much safer to add/remove resources dynamically without impacting others.

### Provisioners
- `local-exec` runs commands on the machine running Terraform.
- `remote-exec` runs commands on the created resource (e.g., via SSH).
*Best Practice:* Provisioners are a last resort. Use specific providers, `user_data` (for AWS EC2), or configuration management tools (Ansible, Chef) instead.
