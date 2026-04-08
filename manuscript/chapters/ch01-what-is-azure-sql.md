# Chapter 1: What Is Azure SQL?

You've run SQL Server for years. You know `tempdb` contention, you've survived a failover cluster rebuild at 2 a.m., and you've got opinions about index maintenance. Now someone — maybe your CTO, maybe a cloud architect, maybe the calendar on your end-of-support SQL Server — is pushing you toward Azure. The question isn't whether SQL Server works. It's whether you're still getting the best deal on running it yourself.

Azure SQL is Microsoft's answer: three products, very different management surfaces. This chapter maps the landscape so you can stop guessing and start choosing.

## The SQL Server Family in the Cloud

Azure SQL isn't a single product. It's a family of three:

- **Azure SQL Database** — a fully managed platform-as-a-service (PaaS) database. You get a database (or a pool of databases); Microsoft handles the OS, patching, backups, and high availability.
- **Azure SQL Managed Instance** — also PaaS, but scoped at the *instance* level. Near-100% feature compatibility with on-premises SQL Server, including SQL Agent, CLR, cross-database queries, and linked servers.
- **SQL Server on Azure VMs** — infrastructure-as-a-service (IaaS). A full SQL Server installation on a Windows or Linux VM that you control. Every version and edition is available.

<!-- Source: azure-sql/azure-sql-iaas-vs-paas-what-is-overview.md -->

All three share the same T-SQL surface, the same query optimizer, and the same storage engine at their core. The differences are in *what Microsoft manages for you* and *what you manage yourself*.

### The Spectrum from Managed to Manual

Think of it as a dial. On the left: SQL Database, where Microsoft handles patching, backups, high availability, and even some performance tuning automatically. On the right: SQL Server on Azure VMs, where you own the OS, the SQL Server instance, and every maintenance task that comes with them. Managed Instance sits in the middle — PaaS convenience with instance-level compatibility.

The further left you go, the less operational work you do. The further right, the more control you get. Neither end is inherently better. The right position depends on what your workload actually needs.

### What "Managed" Actually Means

When Microsoft says a service is "managed," they mean specific things:

- **Patching and upgrades.** SQL Database and Managed Instance run on the latest stable SQL Server engine. Microsoft applies security patches and cumulative updates automatically. On a VM, you schedule and apply updates yourself (though the SQL IaaS Agent extension can automate Windows and SQL Server security updates for you).
- **Backups.** PaaS services take automated backups — full, differential, and transaction log — with configurable retention. On a VM, you configure your own backup strategy (Azure Backup can help, but you're in the driver's seat).
- **High availability.** SQL Database and Managed Instance include built-in HA with an enterprise-class SLA. On a VM, you build HA yourself with Always On availability groups or failover cluster instances.
- **OS management.** PaaS services abstract the OS entirely. On a VM, you manage Windows Update, disk configuration, antivirus, and everything else that comes with running a server.

<!-- Source: azure-sql/azure-sql-iaas-vs-paas-what-is-overview.md -->

## IaaS vs. PaaS: The Real Trade-offs

The IaaS-vs.-PaaS decision is the first fork in the road, and it's worth getting right because switching later means a migration project.

### When Full Control Matters

SQL Server on Azure VMs is the right call when you genuinely need things PaaS can't give you:

- **OS-level access.** You need to install third-party software on the same machine, configure specific OS settings, or access the file system directly.
- **A specific SQL Server version.** You're running SQL Server 2016 or 2019 and can't move forward yet. PaaS services run a recent engine version — SQL Server 2022 or later for Managed Instance (depending on update policy), latest stable for SQL Database — so you can't pin to an older release.
- **Full feature parity.** Your workload depends on features that Managed Instance doesn't support — FILESTREAM, certain distributed transaction patterns, or deeply customized configurations.
- **Regulatory or compliance requirements** that mandate you control the full stack.

For everything else, think hard about whether full control is buying you anything beyond familiarity.

### The Hidden Cost of "Just Run It Yourself"

Running SQL Server on a VM in Azure eliminates the physical hardware, but it doesn't eliminate the work. You still own:

- OS patching and security hardening
- SQL Server cumulative updates and service packs
- Backup strategy, testing, and restore validation
- High availability configuration, monitoring, and failover testing
- Storage configuration and performance tuning at the VM level
- Capacity planning and right-sizing

That's a significant time investment, and time has a cost. The PaaS pricing for SQL Database and Managed Instance includes all of that work. When you compare costs, don't just compare the Azure bill — compare the total cost including the engineering hours you spend keeping the lights on.

### Compliance, Regulatory, and Feature-Parity Considerations

Compliance requirements don't automatically push you to IaaS. Both SQL Database and Managed Instance are certified against a broad set of compliance standards — the same ones available across Azure. The real question is whether your specific compliance framework requires OS-level audit trails, specific encryption configurations, or other controls that only an IaaS deployment can satisfy.

Feature parity is a more concrete concern. SQL Database is deliberately scoped to database-level features — no SQL Agent, no CLR, no cross-database queries, no linked servers. Managed Instance fills most of those gaps. If your workload depends on instance-scoped features, Managed Instance is often the PaaS path forward.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

## A Brief Tour of Each Deployment Option

### Azure SQL Database

SQL Database is the most fully managed option. You provision a database (or an elastic pool of databases) and connect your application. Microsoft handles everything underneath.

Key characteristics:

- **Deployment models:** single database or elastic pool. Single databases get dedicated resources. Elastic pools let multiple databases share a resource budget — ideal for SaaS patterns with variable per-tenant workloads.
- **Purchasing models:** vCore (choose your compute, storage, and backup independently) or DTU (a bundled unit of compute, memory, and I/O). Chapter 2 covers both in detail.
- **Service tiers:** General Purpose, Business Critical, and Hyperscale under the vCore model. Basic, Standard, and Premium under the DTU model.
- **Serverless compute:** available in the General Purpose and Hyperscale tiers. The database auto-scales compute based on workload activity and bills per second of actual usage.
- **Auto-pause:** in the General Purpose tier, serverless databases can auto-pause during inactivity, dropping compute costs to zero. Hyperscale serverless supports auto-scaling but not auto-pause.
- **Storage:** up to 128 TB in the Hyperscale tier. General Purpose and Business Critical tiers have lower limits depending on configuration.
- **Early access to new engine features.** New SQL Server engine capabilities typically ship to SQL Database before the other products, so you get access to the latest T-SQL features sooner.

<!-- Source: azure-sql-database-sql-db/overview/sql-database-paas-overview.md -->

SQL Database is optimized for new cloud applications and SaaS architectures. If you're building something new and don't need instance-level features, start here.

### Azure SQL Managed Instance

Managed Instance is PaaS with near-complete SQL Server compatibility. It's scoped at the instance level, not just the database level, which means it supports features that SQL Database doesn't:

- **SQL Agent jobs** for scheduling and automation
- **CLR integration** for .NET code inside the database engine
- **Cross-database queries** within the same instance
- **Linked servers** for querying external data sources
- **Native virtual network (VNet) integration** — Managed Instance deploys directly into your VNet with a private IP address
- **Database Mail** and Service Broker

The service tier options are General Purpose and Business Critical (no Hyperscale tier for Managed Instance). Maximum instance storage reaches up to 32 TB in the Next-gen General Purpose tier, and up to 16 TB in Business Critical depending on configuration and region.

<!-- Source: azure-sql-managed-instance-sql-mi/overview/sql-managed-instance-paas-overview.md, azure-sql-managed-instance-sql-mi/concepts/architecture/resource-limits.md, azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

Managed Instance supports backward compatibility down to SQL Server 2008 databases. It's the primary PaaS migration target for existing SQL Server workloads — especially those with instance-scoped dependencies.

> **Tip:** Managed Instance supports native backup and restore from Azure Blob Storage, and you can restore Managed Instance backups to SQL Server 2022 or SQL Server 2025 (depending on the instance's update policy). This gives you a migration path that doesn't require specialized tooling.

### SQL Server on Azure VMs

This is the full SQL Server engine running on an Azure virtual machine. You pick the version (2016, 2017, 2019, 2022, 2025), the edition (Developer, Express, Web, Standard, Enterprise), and the OS (Windows or Linux).

What makes it different from just spinning up a VM and installing SQL Server manually? The **SQL IaaS Agent extension**. When you register your VM with this extension (it's free), you unlock:

- **Portal management** — manage SQL Server settings directly from the Azure portal
- **Automated backup** — schedule backups for all databases automatically
- **Automated patching** — apply Windows and SQL Server security updates on a maintenance schedule
- **Azure Key Vault integration** for managing encryption keys
- **Extended security updates** — receive security patches up to three years past end-of-support
- **Flexible licensing** — switch between Azure Hybrid Benefit and pay-as-you-go without redeploying

<!-- Source: sql-server-on-azure-vms/windows/overview/sql-server-on-azure-vm-iaas-what-is-overview.md -->

Storage capacity is limited only by the VM — SQL Server instances can support up to 256 TB across as many databases as you need.

For high availability, you implement Always On availability groups or failover cluster instances yourself. Azure provides the infrastructure (availability sets, availability zones), but you configure and manage the SQL Server HA layer.

## When to Use What: The Decision Framework

Choosing a deployment option isn't about which product is "best." It's about which one matches your workload's actual requirements with the least operational overhead.

### The Service Selection Decision Tree

Start with these questions, in order:

**1. Do you need OS-level control, file system access, or a specific SQL Server version?**

If yes → **SQL Server on Azure VMs.** No PaaS option gives you OS access, and PaaS services run a recent engine version you can't downgrade.

**2. Does your workload require CLR, SQL Agent, cross-database queries, or linked servers?**

If yes → **Azure SQL Managed Instance.** These are instance-scoped features that SQL Database doesn't support.

**3. Do you need the ability to migrate the database back to on-premises or cross-cloud?**

If yes → **Azure SQL Managed Instance.** It supports native backup/restore to SQL Server and can synchronize with on-premises instances through availability groups via the Managed Instance link.

**4. Will the database stay under 4 TB?**

If yes → **Azure SQL Database** (General Purpose or Business Critical) handles this well. For SaaS multi-tenant workloads, use elastic pools.

**5. Will the database grow beyond 4 TB but stay under 32 TB?**

Both Managed Instance and SQL Database Hyperscale work. Choose based on whether you need instance-level features.

**6. Will the database exceed 32 TB?**

**Azure SQL Database Hyperscale** supports up to 128 TB. SQL Server on Azure VMs supports up to 256 TB.

<!-- Source: azure-sql/azure-sql-decision-tree.md, azure-sql/azure-sql-iaas-vs-paas-what-is-overview.md -->

### Walking Through the Decision Tree

The questions above are abstract. Let's make them concrete with two real scenarios.

**Scenario A: SaaS with per-tenant databases.** You're building a multi-tenant SaaS application. Each customer gets their own database — 200 databases today, growing to 500. Individual databases stay under 50 GB and spike at different times. No SQL Agent jobs, no CLR, no cross-database queries.

Walk the tree: no OS-level access needed (skip VMs), no instance-scoped features (skip MI), no need to migrate back on-premises. Each database is well under 4 TB. **Answer: SQL Database with elastic pools.** The databases share a resource budget, you don't pay for peak capacity on each one, and Microsoft handles all the operational work.

**Scenario B: Lift-and-shift from on-premises SQL Server.** You're migrating a line-of-business application that uses SQL Agent for nightly ETL jobs, CLR stored procedures for custom business logic, and cross-database queries to join data from three databases on the same instance. Walk the tree: no OS-level access or specific version needed (skip VMs). Instance-scoped features — SQL Agent, CLR, cross-database queries? Yes to all three. **Answer: Managed Instance.** It supports all of those features in a PaaS model, so you get the migration without inheriting the patching and HA burden of a VM.

### Workload Characteristics That Push You Toward Each Option

| Workload characteristic | Best fit |
|---|---|
| New cloud-native app | SQL Database |
| SaaS with many tenants | SQL Database (elastic pools) |
| Variable/unpredictable usage | SQL Database (serverless) |
| Migrating existing SQL Server | Managed Instance |
| Instance-scoped features needed | Managed Instance |
| OS access or custom software | SQL Server on Azure VMs |
| Specific SQL Server version | SQL Server on Azure VMs |
| Database > 32 TB | Hyperscale or VM |

### Common Mistakes in Choosing a Deployment Model

**Choosing VMs because "it's what we know."** This is the most expensive anti-pattern. If your workload runs fine on Managed Instance, the VM choice costs you hundreds of engineering hours per year in patching, backup management, and HA configuration. That's work PaaS handles automatically.

**Choosing SQL Database when you need instance features.** Teams pick SQL Database for its simplicity, then discover they need SQL Agent, CLR, or cross-database queries. Migrating from SQL Database to Managed Instance is possible but disruptive. Assess your feature dependencies *before* you deploy.

**Over-provisioning "just in case."** All three options support scaling up or down. Start with what you need now; scale when the data tells you to.

**Ignoring elastic pools for multi-database workloads.** If you're running 50 databases that each spike at different times, provisioning each one individually wastes money. Elastic pools let them share resources.

> **Gotcha:** Once you deploy to a specific option, switching to another requires a migration. Moving from SQL Database to Managed Instance, or from either PaaS option to a VM, isn't a settings change — it's a project. Get the decision right early.

## Modernization and Migration at a Glance

If you're reading this book, there's a good chance you're migrating existing SQL Server workloads rather than building from scratch. A few things to know before you dive into the details in Part VII.

### Cost Optimization Paths

**Azure Hybrid Benefit** lets you apply existing SQL Server licenses with Software Assurance to Azure SQL Database, Managed Instance, or SQL Server on Azure VMs. Combined with reserved capacity pricing, savings can reach up to 85% compared to pay-as-you-go rates. The benefit applies to the vCore-based purchasing model for SQL Database and Managed Instance, and to SQL Server licensing on VMs.

<!-- Source: shared-sql-db-sql-mi-docs/billing-options/azure-hybrid-benefit.md, azure-sql/modernization.md -->

**Reserved capacity** lets you commit to a one-year or three-year term for predictable discounts on vCore-based SQL Database, Managed Instance, or VM compute.

**Dev/Test pricing** offers reduced rates for non-production workloads.

### End-of-Support SQL Server: Your Options

When a SQL Server version reaches end of support, security updates stop — unless you take action. Your paths:

- **Migrate to Managed Instance or SQL Database.** PaaS services run on the latest stable engine with evergreen updates. End-of-support becomes someone else's problem.
- **Migrate to SQL Server on Azure VMs.** You get free extended security updates for up to three years past the end-of-support date, delivered automatically through the SQL IaaS Agent extension.
- **Upgrade in place.** Move to a supported SQL Server version on-premises or on your existing VM.

<!-- Source: sql-server-on-azure-vms/windows/concepts/management/sql-server-extend-end-of-support.md, azure-sql/modernization.md -->

> **Important:** Extended security updates on Azure VMs are free — the same updates cost real money on-premises. If you're running end-of-support SQL Server, moving to an Azure VM is the lowest-friction way to stay patched.

### Where Migration Guidance Lives in This Book

Part VII covers migration planning, assessment, and execution in depth — tool selection, pre-migration testing, cutover strategies, and post-migration validation. This chapter gives you the mental model for *which target to pick*. Part VII tells you *how to get there*.

The next chapter digs into the terminology and concepts you'll encounter throughout the rest of the book: purchasing models, service tiers, compute tiers, logical servers, and resource limits. If Azure SQL is the map, Chapter 2 is the legend.
