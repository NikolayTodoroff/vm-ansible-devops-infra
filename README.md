# vm-ansible-devops-infra

An Ubuntu virtual machine provisioned with Terraform, configured with Ansible through an Azure DevOps pipeline, monitored with an Azure Automation runbook, and wired to outbound notifications via Azure DevOps Service Hooks.

---

## Highlights

- Ubuntu 22.04 VM provisioned with Terraform — static public IP, system-assigned managed identity, RBAC-mode Key Vault, and an SSH keypair generated in-code and stored in Key Vault, never touching local disk
- Agentless configuration with Ansible run from the pipeline — nginx install, static site deploy, and firewall rules
- Dynamic NSG lifecycle — the VM ships with SSH closed; the pipeline opens port 22 to the agent's live IP at runtime and removes the rule under `condition: always()`, so a failed run never leaves the port open
- Azure Automation account with a daily PowerShell health-check runbook using its managed identity — two-plane access: `Get-AzMetric` for CPU from outside the guest, `Invoke-AzVMRunCommand` for disk and service status inside it
- Four-stage Azure DevOps pipeline — Validate → Plan → gated Apply → Ansible — with Terraform outputs handed to the Ansible stage as a published artifact rather than a second state read

---

## Repository Structure

```
vm-ansible-devops-infra/
├── ansible/                
│   └── playbook.yml                 
├── infra/
│   ├── main/
│   │   ├── main.tf                   
│   │   ├── rbac.tf                   
│   │   ├── locals.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tf              
│   ├── modules/
│   │   ├── networking/               
│   │   ├── vm/                       
│   │   ├── key-vault/                
│   │   ├── automation/               
│   │   │   └── runbooks/
│   │   │       └── vm-health-check.ps1
│   │   └── monitoring/               
│   └── env/
│       ├── dev.tfvars
│       ├── prod.tfvars
│       ├── dev.backend.hcl
│       └── prod.backend.hcl
├── pipelines/
│   └── infrastructure.yml                  
├── scripts/
│   ├── bootstrap.sh
│   └── assign-roles.ps1
└── README.md
```

---

## Infrastructure

Both `dev` and `prod` environments provision identical resources:

| Resource | Name Pattern |
|---|---|
| Resource Group | `rg-main-vmansible-{env}` |
| Virtual Network | `vnet-vmansible-{env}` |
| Subnet | `snet-vmansible-{env}` |
| Network Security Group | `nsg-vmansible-{env}` |
| Public IP | `pip-vmansible-{env}` |
| Virtual Machine | `vm-vmansible-{env}` |
| Key Vault | `kv-vmansible-{env}` |
| Automation Account | `aa-vmansible-{env}` |
| Log Analytics Workspace | `log-vmansible-{env}` |
| Action Group | `ag-vmansible-{env}` |

The VM is a `Standard D2s v3` Ubuntu 22.04 image with a system-assigned managed identity and password authentication disabled — SSH key only. The public IP is `Standard` SKU with static allocation so the address is stable across the deployment's life.

---

## The Three Identities

The repo has three distinct authentication flows, each using a separate identity for a separate job. Keeping them apart is the core of the security model:

| Flow | Identity | Grant | Purpose |
|---|---|---|---|
| Pipeline agent → VM | SSH private key (from Key Vault) | — | Ansible connects over SSH |
| VM → Key Vault | VM system-assigned identity | Key Vault Secrets User | Read secrets from inside the VM |
| Runbook → metrics / VM | Automation account identity | Reader (RG) + Virtual Machine Contributor (VM) | Read CPU metrics, run in-guest commands |

The deployer's own Key Vault access (Secrets Officer, to *write* the SSH secret during apply) is granted at bootstrap via `assign-roles.ps1` at subscription scope, so it exists before any apply runs — which is why there is no propagation-lag dependency on the secret write in Terraform.

---

## Terraform-to-Ansible SSH Key Flow

```
tls_private_key (generated during apply)
    → public key placed on the VM (admin_ssh_key)
    → private key written to Key Vault as `vm-ssh-private-key` (secret, at root)
    → pipeline pulls the private key from Key Vault into the agent at runtime
    → Ansible uses it to connect over SSH
```

The SSH key pair is created by Terraform so its lifecycle follows the infrastructure, not a specific laptop. Since `tls_private_key` stores the private key in Terraform state as plaintext, the state file is treated as sensitive and stored in an encrypted, RBAC-restricted remote Azure Storage backend.

---

## Ansible Configuration

The VM ships as bare Ubuntu with no `custom_data` or cloud-init - Terraform provisions the infrastructure, Ansible configures the guest OS (over SSH).

`playbook.yml` installs nginx, deploys a static `index.html` (with a handler that restarts nginx only if the page actually changed), sets `ufw` rules for ports 22 and 80, and ensures nginx is running and enabled on boot.

---

## Dynamic NSG Lifecycle

The NSG ships with only a static HTTP rule (port 80 from Internet, so the static site is publicly viewable). SSH (port 22) has **no static rule** — inbound is blocked by the default `DenyAllInBound`. Instead, the Ansible pipeline stage manages port 22 imperatively:

```
open   → az network nsg rule create (port 22, source = agent's live public IP/32)
run    → ansible-playbook against the VM
close  → az network nsg rule delete   (condition: always())
```

This is the pattern that lets a Microsoft-hosted agent — whose IP changes every run — reach a VM whose SSH port is otherwise closed. The rule is named with `$(Build.BuildId)` so concurrent runs never collide. The close step's `condition: always()` is load-bearing: a failed playbook, a crashed step, anything — the port still closes.

Because the imperative rule is created and deleted entirely inside the Ansible stage (after `terraform apply`, which runs in an earlier stage), Terraform never observes it and reports no drift.

---

## Azure Automation Health Check

An Automation account with a system-assigned managed identity runs a PowerShell runbook (`vm-health-check.ps1`) on a daily schedule.

The health check spans two planes deliberately:

- **Outside the guest OS** — `Get-AzMetric` reads the VM's average CPU from Azure Monitor using the managed identity's Reader role. No network path into the VM required.
- **Inside the guest OS** — `Invoke-AzVMRunCommand` ships a shell script into the VM (disk usage via `df -h`, service status via `systemctl is-active nginx`) and returns the output. This reaches the guest through the Azure agent already on the VM, needing no open SSH port.

The schedule and the runbook are separate Terraform resources (`azurerm_automation_schedule` and `azurerm_automation_job_schedule`) linked together, reflecting that schedules and runbooks are independent objects in Azure Automation.

Runbook job logs are linked to the Log Analytics workspace, queryable via KQL in the `AzureDiagnostics` table.

---

## CI/CD Architecture

A single four-stage pipeline (`pipeline.yml`), gated by a `runApply` parameter (unchecked = plan only):

```
Validate  (fmt, init, validate, tflint)
    ↓
Plan      (terraform plan -out → publish tfplan artifact + tf-outputs.json)
    ↓
Apply     (deployment job, infrastructure-{env} environment, approval gate on prod,
           applies the exact reviewed plan; exports Terraform outputs as an artifact)
    ↓
Ansible   (downloads outputs, opens NSG, pulls SSH key from Key Vault, writes inventory,
           runs playbook, closes NSG under always())
```

Apply consumes the exact plan artifact produced by Plan, so no drift can slip in between review and apply. The Ansible stage does not re-initialize Terraform state — the Apply stage exports outputs (`terraform output -json`) as a `tf-outputs` artifact, and the Ansible stage reads the four values it needs (VM IP, NSG name, RG name, Key Vault name) from that JSON with `jq`. This keeps the Ansible stage's job scoped to "configure the VM," with no dependency on Terraform state or a second backend init.

---

## Key Design Decisions

- **SSH closed by default, opened dynamically.** The NSG carries no static SSH rule. The pipeline opens port 22 to the agent's live IP at runtime and removes it under `always()`. This is what makes Microsoft-hosted agents (dynamic IPs) workable against a locked-down VM without a self-hosted agent or Bastion, and it guarantees the port is never left open on failure.

- **SSH key generated in Terraform, stored in Key Vault, never on disk.** `tls_private_key` generates the pair during apply; the private half lands in Key Vault and is pulled by the pipeline at runtime. The tradeoff — the key lives in Terraform state in plaintext — is accepted and mitigated by a locked-down remote backend.

- **Terraform outputs handed to Ansible via artifact.** The Ansible stage reads a published `tf-outputs.json` instead of re-installing Terraform and re-initializing state. Each pipeline job runs on a fresh agent with nothing carried over, so re-reading state would mean a second install + init purely to extract four strings. The artifact handoff is cleaner and decouples the Ansible stage from Terraform entirely.

- **Managed identity for the runbook, not a RunAs account.** RunAs accounts were retired in September 2023. The Automation account's system-assigned identity authenticates with one line and holds least-privilege roles: Reader on the RG for metrics, Virtual Machine Contributor scoped to the single VM for run-command.

- **Scheduled runbook polls and Azure Monitor alerts.** The scheduled runbook polls health once a day. The metric alerts watch the same CPU metric continuously and fire the moment it crosses threshold. Both are included to show the contrast — polling vs. real-time watching — with Azure Monitor being the production-correct choice for monitoring.

---

## Monitoring

The `monitoring` module reuses the Log Analytics workspace created by the `automation` module. It deploys an action group and two Azure Monitor metric alerts on the VM:

- **CPU** — fires when average `Percentage CPU` exceeds 80% over a 5-minute window
- **Availability** — fires when `VmAvailabilityMetric` drops below 1 over a 5-minute window

Alerts fire into the action group, which fans out to its receivers (email here; extensible to SMS, webhook, or an Automation runbook). These platform-metric alerts read directly from Azure Monitor and require no agent inside the guest. This is the real-time, production-shaped counterpart to the scheduled runbook health check.

---

## Security

| Mechanism | Purpose |
|---|---|
| Workload Identity Federation | Pipeline authentication — no stored credentials |
| Terraform-generated SSH key in Key Vault | Key never on local disk; pulled by pipeline at runtime |
| VM system-assigned identity + Key Vault Secrets User | Credential-free secret reads from inside the VM |
| Automation system-assigned identity + Reader / VM Contributor | Runbook authenticates with no RunAs account |
| NSG — SSH closed by default | Port 22 opened dynamically to agent IP, closed under `always()` |
| RBAC-mode Key Vault | Role-based access, no access policies |
| Least-privilege role scoping | VM Contributor pinned to the single VM; Reader at RG scope |
| Remote state on locked-down storage | State holds the plaintext SSH key; encrypted, RBAC-scoped backend |

---

## Technologies

- **Terraform** — VM, networking, Key Vault, Automation, monitoring; `tls` provider for SSH key generation
- **Ansible** — agentless VM configuration over SSH, run from the pipeline; idempotent playbook
- **Azure DevOps Pipelines** — four-stage pipeline, artifact plan/apply, environment approval gates, dynamic NSG lifecycle
- **Azure Boards** — Scrum template, Epic → Feature → PBI → Task hierarchy, AB#N commit linking
- **Azure Virtual Machine** — Ubuntu 22.04, system-assigned identity, SSH key auth only
- **Azure Key Vault** — RBAC mode, stores the generated SSH private key
- **Azure Automation** — daily PowerShell health-check runbook, managed identity, two-plane access
- **Azure Monitor** — Log Analytics, metric alerts (CPU, availability), action group
- **TFLint** — Terraform static analysis
