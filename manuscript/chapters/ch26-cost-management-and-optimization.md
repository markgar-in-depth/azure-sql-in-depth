# Chapter 26: Cost Management and Optimization

The fastest way to blow your Azure budget isn't a runaway query — it's a misconfigured billing model. Azure SQL gives you a dozen levers to control cost, but each one has fine print. This chapter walks through every billing dimension, every discount mechanism, and the monitoring tools that keep surprises off your invoice.

## Understanding Azure SQL Billing

Before you can optimize, you need to understand what you're paying for. Azure SQL billing isn't a single line item — it's a stack of meters that vary by deployment option, purchasing model, and compute tier.

### vCore vs. DTU Cost Structures

The purchasing model you choose determines how costs are calculated and what levers you have available.
<!-- Source: azure-sql-database-sql-db/how-to/cost-management.md -->

**DTU-based pricing** bundles compute, memory, and I/O into a single unit. You pick a service tier (Basic, Standard, or Premium) and a DTU level, and you get a fixed allocation of resources at a flat hourly rate.

Storage and backup are partially included. The DTU model provides an initial set of data and backup storage at no extra charge, with the amount depending on the tier. Extra storage beyond the included amount is billed separately in the Standard and Premium tiers.

**vCore-based pricing** unbundles the bill into discrete components:

| Meter | What it covers |
|---|---|
| Compute | vCores and memory, per hour |
| License | SQL Server license, per month |
| Storage | Data stored, per GB/month |
| Backup | PITR and LTR storage, per GB/month |

This separation matters because each component can be optimized independently. You can bring your own license to eliminate the license meter. You can reserve compute to cut that meter. You can tune retention policies to control backup storage.

> **Tip:** If you're on DTU and want access to Azure Hybrid Benefit, reserved capacity, or serverless compute, you need the vCore model. Those discounts don't apply to DTU-based resources.

### Provisioned vs. Serverless Metering
<!-- Source: azure-sql-database-sql-db/concepts/serverless-tier-overview.md -->

In the vCore model, **provisioned compute** bills at a flat hourly rate. If your database is active for less than one hour, you're still billed for the highest tier selected during that hour, regardless of usage.

**Serverless compute** bills per second, based on actual resource consumption. The formula is:

```
Billed amount = vCore unit price × max(min vCores, vCores used, min memory GB × 1/3, memory GB used × 1/3)
```

Memory is normalized into vCore units at 3 GB per vCore for billing purposes. When the database is paused, the compute bill drops to zero — you pay only for storage.

The billing granularity difference is significant:

| Dimension | Provisioned | Serverless |
|---|---|---|
| Billing unit | Per hour | Per second |
| Minimum charge | Full hour | Min vCores × seconds |
| Paused state | N/A — not supported | Zero compute cost |
| Autoscaling | Manual | Automatic |

Serverless is available in General Purpose and Hyperscale tiers on standard-series (Gen5) hardware only — DC-series and premium-series don't support the serverless compute model. Auto-pause and auto-resume are currently supported only in General Purpose.

> **Gotcha:** Serverless bills for at least the minimum vCores you configure, even when actual usage is lower. Set your minimum vCores as low as your workload allows — the default minimum is 0.5 vCores.

### Storage and Backup Billing
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/automated-backups-overview.md, azure-sql-managed-instance-sql-mi/concepts/service-tiers-managed-instance-vcore.md -->

Data storage and backup storage are billed separately from compute across all deployment options.

**Data storage** in the vCore model is billed per GB per month. In the DTU model, each tier includes a base allocation — extra storage costs additional per GB.

**Backup storage** has two components:

- **Point-in-time restore (PITR):** Billed per GB per month. For SQL Managed Instance, backup storage equal to the configured maximum data size is included at no extra charge. For SQL Database in the vCore model, backup storage beyond the allocated amount is billed.
- **Long-term retention (LTR):** Billed separately based on the redundancy tier you choose — LRS, ZRS, GRS, or GZRS.

Backup storage redundancy is a meaningful cost factor. Locally redundant storage (LRS) is the cheapest option, while geo-redundant storage (GRS) — the default for SQL Database — costs substantially more. For non-production databases or workloads where geo-restore isn't needed, switching to LRS can save real money.

> **Tip:** When creating databases, the Azure portal defaults production workloads to GRS backup redundancy. For dev/test environments, explicitly select LRS to avoid unnecessary geo-replication costs.

### Elastic Pool Cost Sharing

Elastic pools let multiple databases share a single compute allocation, which is the whole point — cost efficiency through resource consolidation. Instead of provisioning each database for its peak, you provision the pool for the aggregate peak, which is typically much lower.

Pool billing follows the same vCore or DTU meter structure as single databases, but applied to the pool as a whole. In the vCore model, you pay for the pool's configured vCores, license, and storage. Individual databases within the pool don't have separate compute meters.

The cost benefit is straightforward: if you have 20 databases that each spike to 4 vCores but never all at once, a pool with 16 vCores serves them all at a fraction of the standalone cost. The more varied the usage patterns across databases, the greater the savings.

## Saving Money

Azure SQL offers a stack of discount mechanisms. Some are mutually exclusive, some compound. Here's how each one works and when to use it.

### Azure Hybrid Benefit: License Portability
<!-- Source: shared-sql-db-sql-mi-docs/billing-options/azure-hybrid-benefit.md -->

**Azure Hybrid Benefit (AHB)** lets you apply existing SQL Server licenses with active Software Assurance to Azure SQL, eliminating the license component of your bill. Microsoft estimates savings of up to 30 percent or more on SQL Database and SQL Managed Instance — use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) to model your specific scenario.

The exchange rates differ by edition:

| On-prem license | GP | BC |
|---|---|---|
| Enterprise (per core) | 4 vCores | 1 vCore |
| Standard (per core) | 1 vCore | 4 cores → 1 vCore |

Enterprise Edition customers get the best deal in General Purpose — one on-premises core covers four Azure vCores. That 4:1 ratio exists because General Purpose doesn't provide the same resource isolation as Business Critical.

AHB applies to:

- **SQL Database** — vCore model, provisioned compute only. Not available on DTU or serverless.
- **SQL Managed Instance** — all vCore tiers.
- **SQL Server on Azure VMs** — all editions via the SQL IaaS Agent extension.

You enable AHB by setting the license type to `BasePrice` when creating or updating a resource. No downtime required for the switch.

> **Important:** AHB includes a 180-day dual-use migration allowance. During migration, you can run the same license on-premises and in Azure simultaneously. After 180 days, the license must be used exclusively on Azure.

For SQL Server on Azure VMs, AHB also unlocks a free passive secondary replica for HA and one for DR — cutting the licensing cost of an Always On availability group deployment by more than half.
<!-- Source: sql-server-on-azure-vms/windows/concepts/management/pricing-guidance.md -->

### Azure Reservations: 1- and 3-Year Compute Commitments
<!-- Source: shared-sql-db-sql-mi-docs/billing-options/reservations-discount-overview.md -->

**Azure Reservations** (also called reserved capacity) give you a significant discount on compute costs in exchange for a one-year or three-year commitment. You're committing to a quantity of vCores in a specific region and service tier — not to a specific database or instance.

Key characteristics:

- Reservations cover compute charges only — not storage, networking, or license fees.
- They apply automatically to matching resources. No assignment needed.
- They support both primary and billable secondary replicas.
- vCore size flexibility lets you scale within a tier without losing the reservation benefit.
- You can pay upfront or monthly.
- Reservations cannot be purchased for DTU-based resources.

**Zone-redundant reservations** require separate purchases. Standard compute and the zone-redundancy add-on are billed as distinct meters, so you need both a **vCore** reservation and a **vCore ZR** reservation to fully cover zone-redundant resources. If you buy only the compute reservation, the zone-redundancy meter keeps billing at pay-as-you-go rates — a common source of unexpected charges.

> **Tip:** Reservations support vCore size flexibility. If you reserve 16 vCores in General Purpose, that reservation covers any combination of databases in that region and tier totaling up to 16 vCores — a single 16-vCore database, two 8-vCore databases, or four 4-vCore databases.

Reservations pair well with the Managed Instance stop/start feature. Because reservation discounts redirect automatically to other matching instances, you can overprovision your reservation count and rotate stopped/started instances against it.

### Serverless Auto-Pause: Paying Only When Active
<!-- Source: azure-sql-database-sql-db/concepts/serverless-tier-overview.md -->

Serverless auto-pause is the most aggressive cost optimization for intermittent workloads. When a database has no active sessions and zero CPU usage in the user resource pool for the configured delay period, Azure pauses the database. Paused databases incur zero compute cost.

The auto-pause delay is configurable:

| Parameter | Range |
|---|---|
| Minimum delay | 15 minutes |
| Maximum delay | 10,080 minutes (7 days) |
| Default | 60 minutes |
| Disable | Set to -1 |

Auto-resume happens automatically on the next connection attempt. The first connection after a pause returns error 40613 ("database unavailable") while the resume completes — typically around one minute. Applications with proper retry logic (→ see Chapter 4) handle this transparently.

Several features block auto-pausing:

- Active geo-replication and failover groups
- Long-term backup retention (LTR)
- SQL Data Sync (for the sync database)
- DNS aliases on the logical server
- Elastic Jobs (when the database is the job database)

> **Gotcha:** The most common reason a serverless database won't auto-pause is open sessions — even idle ones. Monitoring tools, connection pools that hold persistent connections, and SSMS versions before 18.1 can all prevent auto-pause. Use the `sys.dm_exec_sessions` DMV joined to `sys.dm_resource_governor_workload_groups` to identify blocking sessions.

### License-Free Standby Replicas
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/standby-replica-how-to-configure.md, azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/failover-groups/failover-group-standby-replica-how-to-configure.md -->

If your geo-replica or failover group secondary exists solely for disaster recovery — no read workloads, no applications connected — you can designate it as a **standby replica** and eliminate its SQL Server licensing cost entirely. You still pay for compute and storage, but the license meter goes to zero.

This works for both SQL Database and SQL Managed Instance:

- **SQL Database:** Supported in General Purpose and Business Critical, provisioned compute, vCore model. Not supported for Hyperscale, serverless, elastic pools, or DTU.
- **SQL Managed Instance:** Supported via failover groups. The secondary instance's licensing cost is waived.

The mechanics differ by billing model:

- **Pay-as-you-go customers:** The vCore license discount appears directly on the invoice.
- **Azure Hybrid Benefit customers:** The vCores are returned to your license pool for use elsewhere.

Only one secondary can be designated as standby. The standby must be used exclusively for DR — permitted activities are limited to backups, DBCC checks, monitoring connections, and disaster recovery drills.

During failover, roles swap automatically: the old standby becomes the active primary and starts incurring license costs, while the old primary becomes the new standby and stops incurring them.

### VM Pricing: Pay-As-You-Go, AHB, Free Editions, and Auto-Shutdown
<!-- Source: sql-server-on-azure-vms/windows/concepts/management/pricing-guidance.md -->

SQL Server on Azure VMs has the most pricing options because you control the full stack.

**Free editions** eliminate the SQL Server license cost entirely:

- **Developer Edition:** Full Enterprise feature set, but production use is prohibited. Zero SQL Server cost — you pay only for the VM.
- **Express Edition:** Freely licensed for lightweight production workloads — the product hard caps are 4 cores, 1 GB memory, and 10 GB storage per database. Zero SQL Server cost; you pay only for the VM.

**Pay-as-you-go** includes the SQL Server license in the per-second VM cost. The rate varies by edition (Web, Standard, Enterprise) and scales with vCPU count. Best for temporary, unpredictable, or short-lived workloads.

**Azure Hybrid Benefit** applies to VMs the same way it does to PaaS (see the AHB section earlier in this chapter). For continuous workloads with known scale, this is almost always the right choice.

**Auto-shutdown** prevents costs from accruing on idle VMs. You can configure a daily shutdown time in the portal or use Azure Automation for more complex schedules.

> **Warning:** Simply stopping a VM from within the OS does *not* stop billing. You must **deallocate** the VM through the Azure portal, CLI, or API to stop compute charges. The auto-shutdown feature handles this correctly — it deallocates, not just power-offs.

### Dedicated Hosts for License-Dense Deployments
<!-- Source: sql-server-on-azure-vms/windows/concepts/management/dedicated-host.md -->

**Azure Dedicated Host** provides a physical server dedicated to your subscription. For SQL Server licensing, the key benefit is **unlimited virtualization**: license the host's physical cores once, then run as many SQL Server VMs as the hardware supports.

With SQL Server Enterprise Edition and Software Assurance, you can license the entire dedicated host and deploy VMs at a 1:2 virtualization ratio — if the host has 64 physical cores, you can configure 128 vCores of VM capacity while licensing only 64 cores. This makes dedicated hosts cost-effective when you need to run many SQL Server VMs densely.

Dedicated host licensing options:

- **Host-level licensing:** Bundle SQL Server licenses at the host level with AHB. License all physical cores, get unlimited virtualization.
- **Per-VM licensing:** License individual VMs as you would on shared infrastructure.

Dedicated hosts also provide workload isolation, which some compliance frameworks require.

### Extended Security Updates: Free on Azure VMs
<!-- Source: sql-server-on-azure-vms/windows/concepts/management/sql-server-extend-end-of-support.md -->

SQL Server versions that have reached end of support — like SQL Server 2014 — receive **Extended Security Updates (ESUs) at no additional cost** when running on Azure VMs. On-premises, ESUs require a paid subscription. This makes Azure VMs the most cost-effective landing zone for legacy SQL Server instances that can't be upgraded immediately.

ESUs are delivered automatically through Windows Update when the SQL IaaS Agent extension is installed. Automated patching applies them during your configured maintenance window.

> **Note:** ESUs cover security patches only — no new features, no non-security fixes. They buy time for modernization, not a permanent solution. For the full migration and modernization picture, see Part VII of this book.

### Right-Sizing: Using Metrics to Downsize Over-Provisioned Resources

The cheapest optimization is often the simplest: use less. Over-provisioned databases waste money every hour they run.

Start with the monitoring metrics covered in Chapter 14:

- **CPU utilization** consistently below 20%? You're over-provisioned on compute.
- **Data IO percentage** never cracking 30%? You might be in a higher tier than you need.
- **DTU consumption** flat at 15% of capacity? Drop a tier.

For serverless databases, check `app_cpu_billed` against `app_cpu_percent` — if you're consistently billing near the minimum vCores, your minimum might be set higher than necessary.

For VMs, SQL Server licensing scales linearly with vCPUs. A VM with 16 vCPUs costs twice the license of an 8-vCPU VM. Right-sizing the VM directly cuts the most expensive component of the bill.

Use Azure Advisor recommendations as a starting point — it flags consistently underutilized resources. But validate with your own workload data before downsizing, especially if you have seasonal peaks.

### Anti-Patterns: Over-Provisioning "Just in Case"

The most expensive mistake in cloud cost management is treating capacity like on-premises hardware — buying for peak and leaving it idle.

Common anti-patterns:

- **Provisioning Business Critical when General Purpose suffices.** BC costs roughly 3× GP. Unless you need local SSD storage, zone-redundant HA, or read-scale replicas for read workloads, GP handles most production workloads. <!-- TODO: source needed for "BC costs roughly 3× GP" -->
- **Keeping Dev/Test on the same tier as production.** Non-production databases rarely need the same compute class. Use serverless with auto-pause, or Developer/Express editions on VMs.
- **Ignoring elastic pools for multi-database workloads.** If you have 10+ databases with variable usage, a pool almost always costs less than individual provisioning.
- **Defaulting to GRS backup redundancy everywhere.** LRS is appropriate for non-production and for workloads that don't need geo-restore. The cost difference adds up across many databases.
- **Running always-on VMs for batch workloads.** If a VM runs nightly ETL and sits idle 20 hours a day, auto-shutdown or Azure Automation schedules eliminate 80% of the compute cost.
- **Leaving Managed Instances running around the clock.** For off-hours savings on MI, use the stop/start feature covered in Chapter 25.

## Budget Monitoring and Alerts

### Azure Cost Management Integration

Azure Cost Management is your primary tool for tracking and controlling Azure SQL spending. It works across all deployment options — SQL Database, Managed Instance, and SQL Server on VMs.

**Cost analysis** lets you slice spending by service, resource group, tag, or meter category. For Azure SQL, filter by service name to isolate database costs from the rest of your Azure bill. Drill down into individual meters — compute, license, storage, backup — to see exactly where the money goes.

**Budgets** set spending thresholds with automated alerts. The workflow:

- Scope the budget to a subscription or resource group.
- Set a monthly dollar amount.
- Configure alert thresholds — typically at 50%, 80%, and 100%.
- Route alerts to email distribution lists or trigger Action Groups for automated responses.

```json
{
  "properties": {
    "category": "Cost",
    "amount": 5000,
    "timeGrain": "Monthly",
    "timePeriod": {
      "startDate": "2025-01-01T00:00:00Z",
      "endDate": "2025-12-31T00:00:00Z"
    },
    "notifications": {
      "Actual_GreaterThan_80_Percent": {
        "enabled": true,
        "operator": "GreaterThan",
        "threshold": 80,
        "contactEmails": ["dba-team@contoso.com"],
        "thresholdType": "Actual"
      },
      "Forecasted_GreaterThan_100_Percent": {
        "enabled": true,
        "operator": "GreaterThan",
        "threshold": 100,
        "contactEmails": ["dba-team@contoso.com"],
        "thresholdType": "Forecasted"
      }
    }
  }
}
```

The forecasted alert is the one that matters most. It fires when Azure projects you'll exceed your budget based on current spend trends — giving you time to act before the threshold hits.

**Cost export** pushes spending data to a storage account on a daily, weekly, or monthly schedule for analysis in Excel, Power BI, or a custom pipeline. This is the right approach for teams that need to allocate costs across projects or departments.

> **Tip:** Tag your Azure SQL resources with cost-center, environment, and project tags. Cost Management can group and filter by tags, making chargeback and showback reporting straightforward. Enforce tagging policies with Azure Policy to prevent untagged resources from slipping through.

**The Azure pricing calculator** is your pre-deployment tool. Before provisioning, model different configurations — vCore counts, tiers, reservation terms, AHB — to estimate monthly costs. Compare a provisioned GP database with AHB and a 3-year reservation against a serverless database to see where the break-even point falls for your workload pattern.

The next chapter shifts from managing your bill to managing your Managed Instance's most advanced features — the MI Link, data virtualization, and in-database machine learning.
