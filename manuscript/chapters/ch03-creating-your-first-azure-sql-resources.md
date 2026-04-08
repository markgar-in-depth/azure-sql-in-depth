# Chapter 3: Creating Your First Azure SQL Resources

You've picked your deployment model. You know the difference between DTUs and vCores, between General Purpose and Business Critical. Now it's time to actually create something. This chapter walks you through provisioning each of the three Azure SQL deployment options — SQL Database, Managed Instance, and SQL Server on an Azure VM — and then sets up your local development environment so you can iterate without burning cloud hours.

## Provisioning an Azure SQL Database

Azure SQL Database is the quickest of the three deployment options to get running. You can have a fully managed, queryable endpoint in under five minutes. Let's start with the portal to build the mental model, then move to code.

### Portal Walkthrough: Server, Database, Firewall

Every Azure SQL Database lives inside a **logical server**. The logical server isn't a VM or a physical box — it's a management boundary that holds your databases, logins, firewall rules, and auditing configuration. You create the server first, then the database inside it.
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-quickstart.md -->

Here's the portal flow:

1. Go to the **Azure SQL hub** at `aka.ms/azuresqlhub`. Under **Azure SQL Database**, select **SQL databases**, then **+ Create** → **SQL database**.

2. **Project details.** Pick your subscription and resource group. If you're experimenting, create a dedicated resource group — it makes cleanup a one-click operation.

3. **Server.** Select **Create new**. Server names are globally unique across all of Azure, so you'll need something distinctive. Pick a region close to your application. For authentication, you can choose SQL authentication (username/password) or Microsoft Entra — Entra is the better choice for anything beyond quick experiments.

4. **Database name.** Give it something meaningful. You can optionally load the AdventureWorksLT sample data from the **Additional settings** tab.

5. **Compute + storage.** The portal pre-selects a configuration based on your **Workload environment** choice:
   - **Development** defaults to General Purpose serverless with 1 vCore, locally redundant backup storage, and a one-hour auto-pause delay.
   - **Production** defaults to General Purpose provisioned with 2 vCores, 32 GB storage, and geo-redundant backup storage.

   You can override everything by selecting **Configure database**. For a first database, serverless General Purpose is the right call — you only pay for what you use, and it auto-pauses when idle.

6. **Networking.** Select **Public endpoint** so you can connect from your machine. Enable **Add current client IP address** to create a firewall rule automatically. Leave **Allow Azure services and resources to access this server** set to **No** — you can always add specific rules later.

7. **Review + create.** Check the summary and deploy. The database is typically available within a couple of minutes.

> **Tip:** The portal's **Workload environment** selector only affects defaults on the creation form. It doesn't tag or label your database in any way. You can override every setting it pre-fills.

### The Free-Tier Offer

Azure SQL Database has a genuinely useful free tier — no credit card tricks, no countdown timer. Each Azure subscription gets up to 10 free General Purpose databases with the following monthly allowance per database:
<!-- Source: azure-sql-database-sql-db/overview/free-offer.md -->

| Resource | Monthly Free Allowance |
|---|---|
| Compute | 100,000 vCore seconds |
| Data storage | 32 GB max |
| Backup storage | 32 GB |

These are serverless databases. When the monthly vCore seconds run out, you choose what happens: auto-pause until next month (no charges), or keep running and pay standard serverless rates for the overage. The free amount renews at the start of each calendar month.

To create a free database, go to the Azure SQL hub and select **Start free** in the **Create a database** pane. The portal applies the free offer automatically — you'll see a "Free offer applied!" banner and an estimated monthly cost of zero.

> **Gotcha:** Free databases have constraints. Max 4 vCores and 32 GB storage. No long-term backup retention — PITR is limited to 7 days with locally redundant storage only. Free databases can't join elastic pools or failover groups. If you enable the "continue using for additional charges" option, you can't revert back to auto-pause.

> **Tip:** Disconnect query tools (SSMS, VS Code) when you're done. Open connections prevent auto-pause, which burns through your 100,000 vCore seconds faster than you'd expect.

### Choosing a Service Tier and Compute Size

For your first database, start small and scale later. Here's a quick decision guide:

| Scenario | Recommended Starting Point |
|---|---|
| Learning / experimenting | Free tier (serverless) |
| Dev/test workload | General Purpose serverless, 1–2 vCores |
| Small production app | General Purpose provisioned, 2–4 vCores |
| Latency-sensitive production | Business Critical provisioned, 4+ vCores |

Serverless is ideal for intermittent workloads because it scales compute automatically within the range you set and pauses when idle. Provisioned makes sense when you need predictable performance — you're paying for always-on compute, but there's no cold-start latency after idle periods.

Don't overthink this decision. You can change service tiers and compute sizes at any time with near-zero downtime. Chapter 2 covered the details of each tier — refer back there if you need a refresher.

## Provisioning with Infrastructure as Code

The portal is fine for learning. It's not fine for production. If you're creating databases by clicking through a UI, you've got no audit trail, no repeatability, and no way to spin up identical environments. Infrastructure as Code solves all three.

### ARM Templates, Bicep, and Terraform

Azure SQL Database resources are defined by two resource types: `Microsoft.Sql/servers` (the logical server) and `Microsoft.Sql/servers/databases` (the database itself). All three IaC tools target these same resources — they differ in syntax, not capability.

**Bicep** is the most concise option and the natural choice if you're already in the Azure ecosystem:
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-bicep-quickstart.md -->

```bicep
@description('The name of the SQL logical server.')
param serverName string = uniqueString('sql', resourceGroup().id)

@description('The administrator username of the SQL logical server.')
param administratorLogin string

@secure()
@description('The administrator password of the SQL logical server.')
param administratorLoginPassword string

param location string = resourceGroup().location

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
  }
}

resource sqlDB 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: 'AppDb'
  location: location
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
  }
}
```

Deploy it:

```bash
az group create --name myapp-rg --location eastus
az deployment group create \
  --resource-group myapp-rg \
  --template-file main.bicep \
  --parameters administratorLogin=appadmin
```

**Terraform** uses the `azurerm_mssql_server` and `azurerm_mssql_database` resources:
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-terraform-quickstart.md -->

```terraform
resource "azurerm_mssql_server" "server" {
  name                         = "myapp-sql-server"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  administrator_login          = var.admin_username
  administrator_login_password = local.admin_password
  version                      = "12.0"
}

resource "azurerm_mssql_database" "db" {
  name      = "AppDb"
  server_id = azurerm_mssql_server.server.id
}
```

**ARM templates** are the raw JSON underneath Bicep. You'll encounter them in older documentation and existing deployments. They define the same `Microsoft.Sql/servers` and `Microsoft.Sql/servers/databases` resources but in verbose JSON. If you're starting fresh, use Bicep — it compiles to ARM templates anyway, and the authoring experience is dramatically better.
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-arm-template-quickstart.md -->

### When to Use IaC vs. Portal

Always IaC for production. Full stop.

The portal is a learning tool and an emergency escape hatch. For everything else — dev, staging, production — define your infrastructure in code, check it into source control, and deploy through a pipeline. You get:

- **Repeatability.** Spin up identical environments on demand.
- **Audit trail.** Every change is a commit with a diff.
- **Drift detection.** Terraform's `plan` command shows you exactly what will change before it happens.
- **Review process.** Infrastructure changes go through the same pull request workflow as application code.

> **Important:** Never hard-code passwords in IaC files. Use Azure Key Vault references, Bicep `@secure()` parameters, or Terraform's `sensitive` variable flag. Your CI/CD pipeline should inject secrets at deploy time.

## Provisioning an Azure SQL Managed Instance

Managed Instance is a different beast. Where SQL Database gives you a single database (or a pool of databases) behind a logical server, Managed Instance gives you a near-complete SQL Server instance — with all the compatibility that implies. The trade-off is complexity: MI lives inside your virtual network and takes significantly longer to provision.

### VNet and Subnet Requirements

A Managed Instance must be deployed into a **dedicated subnet** within an Azure virtual network. This isn't optional — it's the core of MI's architecture. The instance runs on isolated VMs inside a virtual cluster that Azure manages within your subnet.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/vnet-subnet-determine-size.md -->

The subnet must meet these requirements:

- **Delegated to `Microsoft.Sql/managedInstances`.** This tells Azure the subnet is reserved for MI. No other resources can be deployed into a delegated subnet.
- **No existing resources.** The subnet must be empty when you create the first instance (unless it already hosts other MIs).
- **Minimum /27 CIDR range** (32 IP addresses) for a single instance. In practice, plan larger.

**Sizing the subnet matters.** Azure reserves IP addresses for internal plumbing, and each instance consumes addresses based on its service tier:

| Component | IP Addresses |
|---|---|
| Azure platform reserved | 5 |
| Per VM group | 8 |
| Per General Purpose instance | 2 |
| Per Business Critical instance | 5 |

For multiple instances, use this formula:

`5 + (gp × 4) + (bc × 10) + (bc_zr × 2) + (vmg × 8)`

where `gp` = General Purpose instances, `bc` = Business Critical instances, `bc_zr` = zone-redundant BC instances, and `vmg` = number of distinct VM groups.

The factor of 4 per GP instance (not 2) accounts for scaling operations that temporarily double address usage.

> **Important:** You can't resize a subnet after deploying resources into it. Always size larger than your current needs. A /24 (256 addresses) is a reasonable starting point for most deployments.

You also need a **network security group (NSG)** associated with the subnet. The portal can configure this automatically when you create the instance, or you can set it up in advance. Route tables may be required depending on your network topology, but for a straightforward deployment the portal handles the defaults.

### Instance Creation

You can create a Managed Instance through the portal, CLI, PowerShell, or IaC.
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/instance-create-quickstart.md -->

**Portal flow:**

1. Go to the **Azure SQL hub**. Under **Azure SQL Managed Instance**, select **SQL managed instances**, then **+ Create** → **SQL managed instance**.

2. **Basics.** Pick your subscription, resource group, instance name, and region. Choose your authentication method — SQL authentication works for getting started, but Microsoft Entra is recommended for production.

3. **Compute + storage.** Select **Configure Managed Instance** to choose:
   - **Service tier:** General Purpose (default) or Business Critical.
   - **Hardware:** Standard-series (Gen5) is the default.
   - **vCores:** 8 is the default. Adjust based on your workload.
   - **Storage:** Size based on expected data volume.
   - **Backup redundancy:** Geo-redundant is default and recommended.

4. **Networking.** Select an existing VNet/subnet or create new ones. The portal validates subnet requirements and can configure delegation, NSGs, and routes automatically. Set the connection type and decide whether to enable the public endpoint.

5. **Review + create.** Deploy. Then wait.

**CLI alternative:**

```bash
az sql mi create \
  --name myapp-mi \
  --resource-group myapp-rg \
  --location eastus \
  --admin-user miadmin \
  --admin-password '{your-password}' \
  --subnet /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet} \
  --capacity 8 \
  --tier GeneralPurpose \
  --family Gen5 \
  --storage 256 \
  --license-type LicenseIncluded
```

IaC options include Bicep templates, ARM templates, and Terraform — all following the same pattern as SQL Database but targeting the `Microsoft.Sql/managedInstances` resource type.
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/create-bicep-quickstart.md, azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/instance-create-terraform.md -->

### The Free-Tier MI Offer

Managed Instance also has a free trial. Each Azure subscription gets one free General Purpose instance for 12 months with these limits:
<!-- Source: azure-sql-managed-instance-sql-mi/overview/free-offer.md -->

| Resource | Free Allowance |
|---|---|
| vCore hours | 720/month |
| vCores | 4 or 8 |
| Storage | 64 GB |
| Databases | 100 (GP) / 500 (Next-gen GP) |
| Backup retention | 1–7 days, locally redundant |
| Instances per subscription | 1 |

The instance comes with a **default workday schedule** — on from 9 AM to 5 PM Monday through Friday in the timezone you configure at creation. This conserves your 720 monthly vCore hours. You can modify the schedule, but choose your timezone carefully — it can't be changed after creation.

When you exhaust the monthly vCore hours, the instance stops automatically. Credits renew on the same date each month. After 12 months, the instance stops permanently — if you don't upgrade to a paid instance within 30 days, it's deleted along with all databases.

> **Gotcha:** If you delete a free instance and create a new one, your credits don't reset. The remaining hours for the current month carry over to the new instance.

To create a free instance, select **SQL managed instance (Free offer)** from the create dropdown in the portal, or pass `--pricing-model Freemium` in the CLI.

### Instance Pools: When Shared VMs Make Sense

If you need multiple small Managed Instances — say, one per customer in a multi-tenant architecture — **instance pools** let you share the underlying VM infrastructure across instances. Instead of each instance getting its own dedicated VM group, pooled instances share a pre-provisioned set of VMs.
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/instance-pools-configure.md -->

The benefits:

- **Faster provisioning.** Creating an instance inside an existing pool is significantly faster than standalone (see the duration table below).
- **Cost efficiency.** Multiple small instances share compute instead of each paying the overhead of dedicated VMs.
- **Consolidated management.** The pool is the billing and licensing unit.

The constraints:

- Only General Purpose tier on standard-series (Gen5) or premium-series hardware.
- The pool itself typically takes about 30 minutes to create (95% of operations), though it can take up to 4.5 hours in the worst case — it's provisioning the VM group.
- Maximum 40 instances per pool.
- License type is set at the pool level.

Instance pools make sense when you have many small, independent workloads that don't individually justify a full MI. If you have one or two instances, the overhead of creating and managing a pool isn't worth it.

### Why MI Provisioning Takes Longer

If you've provisioned a SQL Database in two minutes and then waited 30 minutes for a Managed Instance, you might wonder what's happening. The answer: Azure is building real infrastructure.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-overview.md, azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-duration.md -->

When you create a Managed Instance, Azure:

1. **Validates your request** — checks the subnet, SKU, and parameters.
2. **Creates a virtual cluster** — a dedicated set of isolated VMs deployed into your subnet. This is the long pole. Azure is provisioning physical compute, configuring networking, and setting up the VM group that will host your instance.
3. **Deploys the SQL Database Engine** — starts the SQL Server process on the allocated VMs.

For SQL Database, none of this happens. Your database runs on shared, pre-provisioned infrastructure behind a lightweight metadata endpoint.

Here's what the timelines look like in practice:

| Operation | General Purpose | Business Critical |
|---|---|---|
| Create instance | ~30 min | ~30 min |
| Create (zone-redundant) | ~4 hours | ~4 hours |
| Create inside pool | <10 min | N/A (GP only) |
| Scale compute | ~60 min | ~60 min + seeding |
| Delete (not last) | ~1 min | ~1 min |
| Delete (last in subnet) | ~90 min | ~90 min |

Business Critical uses local SSD storage with Always On availability groups under the hood. Create times are comparable to General Purpose, but update and scaling operations take longer because they involve seeding data across replicas.

The last-instance delete is slow for a different reason: Azure synchronously tears down the entire virtual cluster when the final instance in a subnet is removed.

> **Tip:** If you know you'll need MI, start the provisioning early. Don't wait until the sprint demo to discover it takes 30 minutes. For CI/CD pipelines, use instance pools or keep a persistent dev instance rather than creating and destroying instances per test run.

## Provisioning SQL Server on an Azure VM

Sometimes you need the full SQL Server engine with complete control. Maybe you need a feature that Managed Instance doesn't support, or you're running a third-party application that requires direct OS access, or your compliance requirements mandate it. SQL Server on an Azure VM gives you exactly what you'd get on-premises — it's your VM, your SQL Server, your responsibility.

### Marketplace Images

The Azure Marketplace provides pre-built VM images with SQL Server already installed and configured. You don't need to install SQL Server yourself — just pick an image that matches your requirements.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/create-sql-server-vm/create-sql-vm-portal.md -->

Available combinations include:

- **SQL Server versions:** 2017, 2019, 2022, 2025 (images are periodically updated; older versions out of mainstream support are removed)
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/create-sql-server-vm/create-sql-vm-portal.md, sql-server-on-azure-vms/windows/overview/sql-server-on-azure-vm-iaas-what-is-overview.md -->
- **Editions:** Enterprise, Standard, Web, Developer (free for dev/test), Express (free for lightweight workloads)
- **Operating systems:** Windows Server 2019, 2022, 2025, and several Linux distributions (RHEL, Ubuntu, SUSE)

To browse images: go to the **Azure SQL hub**, select **SQL Server on Azure VMs**, then **+ Create**. The dropdown shows available image offers. Select **See all images** to filter by SQL version, edition, OS, and security type.

> **Note:** Licensing costs for SQL Server are bundled into the VM's per-second pricing (pay-as-you-go). Developer edition is free for non-production use. You can also bring your own license via Azure Hybrid Benefit to pay only for the VM compute.

### VM Sizing for SQL Server

SQL Server is memory-hungry. The general guidance is to use **memory-optimized VM series** — specifically the **Edsv5** or **Ebdsv5** families — which provide a high memory-to-vCore ratio.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/create-sql-server-vm/create-sql-vm-portal.md -->

A minimum recommended VM for SQL Server on Azure is the **E4ds_v5** (4 vCores, 32 GB RAM). For production workloads, start at 8 vCores or higher and benchmark from there.

Key sizing considerations:

- **Memory:** SQL Server's buffer pool wants as much RAM as possible. Undersizing memory is the single most common performance mistake on Azure VMs.
- **Storage:** Use Premium SSD or Ultra Disk for data and log files. Never put production data on standard HDD. Separate data, log, and tempdb onto different disks.
- **Compute:** Match vCores to your workload's parallelism needs. Don't pay for 64 cores if your queries are single-threaded.

> **Tip:** Start with a Development workload in a smaller VM for testing, then right-size for production based on actual performance data. You can resize the VM later, though it requires a brief restart.

### The SQL IaaS Agent Extension

When you deploy a SQL Server VM from a Marketplace image, Azure automatically registers it with the **SQL Server IaaS Agent extension** (`SqlIaasExtension`). This extension is free and bridges the gap between "it's your VM" and "Azure can still help."
<!-- Source: sql-server-on-azure-vms/windows/overview/sql-server-iaas-agent-extension-automate-management.md -->

What the extension provides:

- **Portal management** — manage SQL VMs in the Azure portal alongside your PaaS databases
- **Automated backup** — schedule backups without configuring maintenance plans
- **Automated patching** — apply security updates during your maintenance window
- **Azure Key Vault integration** — automatically configure AKV on the VM
- **Flexible licensing** — switch between pay-as-you-go and Azure Hybrid Benefit without redeploying
- **SQL best practices assessment** — catch misconfigurations before they cause production issues
- **tempdb configuration** — tune file count, size, and location from the portal without remoting into the VM
- **Extended security updates** — receive security patches up to 3 years after end-of-support

The extension uses a **least-privilege permission model** by default (for VMs provisioned since October 2022). Each feature gets only the SQL Server permissions it needs — no blanket `sysadmin` access.

> **Important:** If you install SQL Server manually on a VM (instead of using a Marketplace image), you should still register with the extension. It's free and unlocks all of the above. Use `az sql vm create` to register an existing VM.

### Confidential VMs for SQL Server

If you're handling sensitive data and need hardware-enforced memory encryption, Azure confidential VMs provide an extra protection layer. These VMs use **AMD SEV-SNP technology** to encrypt the VM's memory using processor-generated keys, protecting data in use from the host OS.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/create-sql-server-vm/sql-vm-create-confidential-vm-how-to.md -->

Confidential VMs are available in several series:

| Series | Type | Memory-to-vCore Ratio |
|---|---|---|
| ECadsv5 | Memory-optimized | ~8:1 |
| DCadsv5 | General-purpose | ~4:1 |
| DCadsv6 | General-purpose (Genoa) | ~4:1 |

To use one, select **Confidential virtual machines** as the security type during VM creation, then choose a compatible SQL Server image.
<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/performance-guidelines-best-practices-vm-size.md -->

The OS disk can also be encrypted with keys bound to the VM's TPM chip, reinforcing data-at-rest protection beyond standard Azure disk encryption.

Pre-built confidential SQL Server images are available for SQL Server 2022, 2019, and 2017 on Windows Server. If you need a different combination, deploy any confidential VM image and install SQL Server yourself.

> **Note:** Confidential VMs aren't available in all Azure regions. Check the `ECadsv5-series`, `DCadsv5-series`, or `DCadsv6-series` availability in your target region before planning a deployment.

## Setting Up a Local Development Environment

Cloud databases are great for running your application. They're terrible for rapid iteration. Every schema change that requires a round-trip to Azure adds latency to your inner development loop. The local development experience for Azure SQL Database eliminates that bottleneck.
<!-- Source: azure-sql-database-sql-db/concepts/local-development/local-dev-experience-overview.md -->

### Dev Containers for Azure SQL Database

**Dev Container Templates** for Azure SQL Database give you a preconfigured, containerized development environment with a local SQL Database instance that's compatible with Azure SQL Database. You get a real database engine running locally — not a mock, not an emulator.
<!-- Source: azure-sql-database-sql-db/concepts/local-development/local-dev-experience-dev-containers.md -->

These containers work with:

- **VS Code** using the Dev Containers extension
- **GitHub Codespaces** for cloud-based development

Each template comes preloaded with:

- A local SQL Database engine (the `library` database, validated for Azure SQL Database compatibility)
- Your preferred application framework (.NET, Node.js, Python, .NET Aspire)
- Azure CLI and Azure Developer CLI
- VS Code extensions for SQL Server connectivity, database projects, and GitHub Copilot

To get started:

1. Install Docker Desktop and the VS Code Dev Containers extension.
2. Clone a Dev Container template from `https://aka.ms/azuresql-devcontainers-repo`.
3. Open the folder in VS Code and select **Reopen in Container** when prompted.

The container builds, starts the local database, and you're ready to code — no Azure subscription required for local work.

> **Tip:** Dev Containers aren't just for local machines. The same `devcontainer.json` configuration works in GitHub Codespaces, so your entire team gets an identical environment. You can also reuse it in CI pipelines using the `devcontainers/ci` GitHub Action.

### SQL Database Projects in VS Code

The **SQL Database Projects extension** for VS Code lets you manage your database schema as code. You define tables, views, stored procedures, and other objects as `.sql` files in a project, and the extension handles building, validating, and publishing the schema.
<!-- Source: azure-sql-database-sql-db/how-to/develop-locally/local-dev-experience-create-database-project.md -->

Key operations:

- **Create a new project** from scratch or import an existing schema from a live database.
- **Edit schema objects** with IntelliSense and validation.
- **Build** to check for errors without deploying.
- **Publish** to a local container database (inner loop) or to Azure SQL Database (outer loop).

This is a declarative model: you define the desired state, and the tooling generates the migration scripts. No hand-rolled `ALTER TABLE` chains.

### The Inner-Loop / Outer-Loop Lifecycle

The local development experience follows a two-loop model:

**Inner loop** (local, fast):
1. Edit schema files in your SQL Database Project.
2. Build to validate.
3. Publish to the local containerized database.
4. Run and test your application against the local database.
5. Iterate.

**Outer loop** (cloud, CI/CD):
1. Push schema changes to your Git repository.
2. A GitHub Actions workflow (or Azure DevOps pipeline) builds the project.
3. The pipeline publishes the schema to a staging Azure SQL Database.
4. Integration tests run against the cloud database.
5. On success, deploy to production.

The inner loop gives you sub-second feedback. The outer loop gives you confidence that what works locally works in Azure. Together, they eliminate the "works on my machine" problem for database development.

This local development workflow applies specifically to Azure SQL Database. Managed Instance and SQL Server on VMs use traditional SQL Server development tools — SSMS, SSDT, sqlcmd — since they run the full SQL Server engine and don't need a local compatibility layer.

With your resources provisioned and your development environment set up, you're ready to connect and start running queries. That's where Chapter 4 picks up — connection architecture, authentication, and the tools you'll use every day.
