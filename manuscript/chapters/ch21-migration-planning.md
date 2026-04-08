# Chapter 21: Migration Planning

Every migration starts with the same question: *where are we going?* Not "to Azure" — that's already decided. The real question is which Azure SQL deployment option, which SKU, which migration method, and what's going to break on the way. Get this wrong and you'll spend months undoing a hasty choice. Get it right and the actual migration becomes the boring part.

This chapter is the planning playbook. You'll build a decision framework for choosing your target, run pre-migration assessments to surface compatibility blockers before they surface themselves, and map out the migration methods available for each target. Chapters 22–24 cover the execution details for each deployment option. This chapter tells you how to pick which chapter you need.

## The Migration Decision Framework

Choosing between SQL Database, Managed Instance, and SQL Server on Azure VMs is the highest-stakes decision in your migration. Chapter 1 introduced the deployment options. Now you're making that decision for real, with a production workload attached.

### Choosing the Right Target

The decision comes down to three forces: **compatibility**, **control**, and **cost**.

<!-- Source: migrate-from-sql-server/_summary.md -->

**Compatibility** is the gatekeeper. SQL Database is a database-scoped PaaS service — it doesn't support instance-level features like SQL Agent, cross-database queries, CLR assemblies, Service Broker, or linked servers. If your workload depends on any of these, SQL Database isn't an option without refactoring. Managed Instance supports nearly all of them. SQL Server on Azure VMs supports everything — it's the same engine you're running today.

**Control** determines your operational ceiling. SQL Database gives you the least administrative surface but the most automation. Managed Instance gives you instance-level control within a PaaS envelope. Azure VMs hand you the OS, the instance, and every maintenance task.

**Cost** shapes the long-term picture. PaaS options eliminate the operational overhead of patching, backups, and HA configuration — but you pay for the managed service. VMs can be cheaper at the license level (especially with Azure Hybrid Benefit), but you absorb the hidden costs of OS management, patching windows, and backup infrastructure.

Here's how to think through the decision:

| Factor | SQL Database | Managed Instance | SQL Server on VM |
|---|---|---|---|
| Instance features | No | Yes | Yes |
| OS access | No | No | Yes |
| Version control | No | No | Yes |
| PaaS automation | Full | Full | Partial (IaaS Agent) |
| Max DB size | 128 TB (Hyperscale) | 16 TB (32 TB next-gen GP) | Storage limit |
| Migration complexity | Moderate | Moderate | Low (lift-and-shift) |

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, azure-sql-managed-instance-sql-mi/concepts/service-tiers-managed-instance-vcore.md -->

> **Important:** Chapter 1 covers the full deployment-option decision tree. Use that framework first, then return here for migration-specific considerations like assessment rules, tooling, and method selection.

### Workload Assessment and Compatibility Analysis

Before you commit to a target, you need data — not opinions. A compatibility assessment scans your source SQL Server instance and tells you exactly which features, T-SQL constructs, and configurations will or won't work on each target.

The assessment answers three questions:

1. **Can this workload run on the target?** The assessment flags blocking issues — features that flat-out don't exist on the target platform. Cross-database queries on SQL Database, for example.
2. **What needs to change?** Some features have workarounds. Linked servers on SQL Database don't work, but elastic queries might solve the same problem. The assessment flags these as warnings.
3. **What's the effort?** The number and severity of issues tells you whether you're looking at a weekend migration or a three-month refactoring project.

Assessment tools categorize findings into three buckets:

| Category | Meaning | Action |
|---|---|---|
| **Ready** | No compatibility issues | Proceed to migration |
| **Conditionally ready** | Minor issues with known fixes | Remediate, then proceed |
| **Not ready** | Blocking issues, no workaround | Choose a different target |

<!-- Source: migrate-from-sql-server/to-azure-sql-database/_summary.md, migrate-from-sql-server/to-azure-sql-managed-instance/_summary.md -->

> **Tip:** Run assessments against *all three targets* simultaneously. You might assume Managed Instance is the right fit, only to discover your workload is actually clean enough for SQL Database — which is cheaper and simpler to operate.

### SKU Recommendations and Right-Sizing

Assessment tools don't just check compatibility — they also recommend a target SKU. This is critical. Overprovision and you waste money. Underprovision and you hit performance cliffs on day one.

SKU recommendations work in two modes:

**Performance-based sizing** collects actual workload metrics from your source — CPU utilization, memory usage, IOPS, throughput, and storage consumption — over a configurable collection period. The tool then maps those metrics to the smallest Azure SQL configuration that can handle the observed load. This is the mode you want for production workloads.

**As-on-premises sizing** maps your current SQL Server configuration (cores, memory, storage) directly to an Azure equivalent. This is faster but less accurate — it doesn't account for workloads that are overprovisioned or underutilized on-premises.

> **Gotcha:** Performance-based recommendations are only as good as the data they collect. If you capture metrics during a low-traffic week and miss your monthly batch processing spike, the recommended SKU will be too small. Collect data for at least one full business cycle — ideally 30 days.

### Cost Estimation

Once you have a target SKU, you can model costs. Three levers matter most:

**Azure Hybrid Benefit** lets you apply existing SQL Server licenses with Software Assurance to Azure SQL Database, Managed Instance, and SQL Server on Azure VMs. You get a significant discount on the SQL Server license component of the cost. The benefit applies to the vCore-based purchasing model.

<!-- Source: azure-sql/modernization.md -->

**Reserved capacity** commits you to a one-year or three-year term in exchange for a discount on compute costs. Combined with Azure Hybrid Benefit and extended security updates, total savings can reach up to 85% compared to pay-as-you-go pricing.

**Licensing models** vary by target. SQL Database and Managed Instance use the vCore model (with a DTU option for SQL Database). Azure VMs give you the choice of pay-as-you-go licensing or bring-your-own-license via Azure Hybrid Benefit. If you're running Enterprise Edition on-premises but only need Standard Edition features, you might save significantly by right-sizing the edition during migration.

> **Tip:** Azure Migrate includes cost estimates in its assessment reports. It factors in Azure Hybrid Benefit and reserved capacity automatically, so you can compare scenarios side by side without building spreadsheets.

## Pre-Migration Assessment

Planning without assessment is guessing. Azure provides a layered set of tools for discovering, assessing, and right-sizing your SQL Server estate before you touch a single database.

### Azure Migrate and the Azure SQL Migration Extension

**Azure Migrate** is the central hub for migration assessment at scale. For SQL Server workloads, it discovers instances running on VMware, Hyper-V, or physical servers, then evaluates them against all three Azure SQL targets simultaneously.

The assessment workflow looks like this:

1. **Discover.** Deploy the Azure Migrate appliance in your environment. It scans the network, discovers SQL Server instances, and inventories databases.
2. **Collect performance data.** The appliance captures CPU, memory, IOPS, and throughput metrics over time. More data means better SKU recommendations.
3. **Assess.** Azure Migrate runs compatibility checks and generates per-database readiness ratings for SQL Database, Managed Instance, and SQL Server on Azure VMs.
4. **Review recommendations.** Each assessment includes a recommended target, SKU sizing, monthly cost estimate, and a list of compatibility issues with remediation guidance.

**The Azure SQL Migration extension for Azure Data Studio** provides a more hands-on assessment experience. You connect directly to a source SQL Server instance, run an assessment, and get immediate results — readiness status, blocking issues, and SKU recommendations — without deploying an appliance. This extension supersedes the older Data Migration Assistant (DMA), so if you encounter DMA references in older documentation, know that the Migration extension is the current tool.

For environments with **SQL Server enabled by Azure Arc**, migration readiness assessments are built in. Arc-enabled SQL Servers report compatibility data directly to the Azure portal, giving you a centralized view without additional tooling. This is most useful when you've already enrolled your SQL Server estate in Arc for management purposes — you get migration readiness data for free.

> **Note:** Azure Migrate and the Azure SQL Migration extension both generate SKU recommendations. Azure Migrate is better for large estates (dozens or hundreds of instances). The Migration extension is better for targeted assessment of individual instances.

### Assessment Rules: What They Check

Assessment rules evaluate your source databases against target-specific compatibility requirements. The rules fall into two categories:

**Blocking issues** are features or configurations that prevent migration entirely:

- **SQL Database blockers:** Cross-database queries, CLR assemblies, Service Broker, SQL Agent jobs, linked servers, FILESTREAM, multiple log files per database, distributed transactions (without elastic transactions).
- **Managed Instance blockers:** Far fewer — FILESTREAM and multiple log files. Most SQL Server features are supported.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->
- **Azure VM blockers:** Effectively none for same-version migrations. Cross-version migrations may hit deprecated feature issues.

**Warnings** are issues that require attention but have workarounds:

- T-SQL syntax differences (e.g., `BACKUP TO DISK` doesn't work on SQL Database)
- Deprecated features that still work but should be updated
- Configuration differences (e.g., collation defaults, compatibility level, buffer pool extension on MI)

> **Gotcha:** Assessment tools check the *database schema and configuration* — they don't execute your application. A database might pass every assessment rule and still have runtime issues if your app uses unsupported features through dynamic SQL or ORM-generated queries. Always run integration tests against the target after migration.

### Performance Baselining

Before you migrate, capture a performance baseline on your source system. After migration, you'll compare the same metrics on the target to verify that performance meets expectations.

Capture these metrics at minimum:

- **CPU utilization** — average and peak, over a full business cycle
- **Memory usage** — buffer pool size, page life expectancy
- **I/O throughput** — read/write IOPS, latency per drive
- **Query performance** — top queries by duration, CPU, and reads (use Query Store or a DMV snapshot)
- **Wait statistics** — the dominant wait types tell you where the engine spends time waiting

<!-- Source: migrate-from-sql-server/to-azure-sql-managed-instance/_summary.md -->

Store this data somewhere you can access it after migration. Query Store is ideal for query-level metrics because it persists across backup/restore. For instance-level metrics, export DMV data to a table or file.

> **Tip:** Enable Query Store on the source before migration if it isn't already enabled. SQL Database and Managed Instance have it on by default, so you'll have pre-migration query data available for comparison immediately after cutover.

## Migration Methods Overview

Every migration ultimately moves schema and data from point A to point B. The difference is in how much downtime you can tolerate, how large your databases are, and what your source version supports. Here's the landscape.

### The Methods

| Method | Targets | Online? |
|---|---|---|
| Azure DMS | All three | Yes (online mode) |
| Backup/restore | MI, VM | Offline |
| Log Replay Service | MI | Near-online |
| MI Link | MI | Online |
| BACPAC import | SQL DB | Offline |
| Transactional replication | SQL DB | Online |
| Log shipping | VM | Near-online |
| Detach/attach | VM | Offline |
| VHD upload | VM | Offline |
| Azure Migrate | VM | Offline |

> **Note:** "Online" means the source database remains available for reads and writes during migration. "Near-online" means the source is available until cutover, but there's a brief window of downtime during the final switchover.

### Lift-and-Shift vs. Modernize

Two migration strategies compete for your attention:

**Lift-and-shift** moves the workload as-is. You take what you have — same SQL Server version, same configuration, same application — and move it to Azure. This is the fastest path with the lowest risk. It's also only possible with Azure VMs (and sometimes Managed Instance, depending on compatibility).

**Modernize** means changing the target. You move from SQL Server 2016 on-premises to SQL Database or Managed Instance, accepting that you'll need to refactor incompatible features in exchange for PaaS benefits. This takes longer but pays off in reduced operational overhead.

The right choice depends on your timeline and tolerance for change:

- **End-of-support deadline** — Lift-and-shift to an Azure VM. It's the fastest path out of your data center.
- **Need PaaS with low compatibility issues** — Modernize to SQL Database. Cheaper, simpler ops.
- **Need PaaS with high compatibility needs** — Modernize to Managed Instance. Near-full SQL Server feature support.
- **Large estate, phased approach** — Lift-and-shift to VMs first, then modernize to PaaS later. See the Tip below.
- **Already on SQL Server 2019+** — Modernize to Managed Instance. The compatibility gap is minimal.

> **Tip:** The phased approach — lift-and-shift to Azure VMs first, then modernize to PaaS later — is underrated. It gets you out of your data center quickly, often under deadline pressure, and gives you time to plan the modernization without the ticking clock of end-of-support.

### Choosing a Method for Each Target

Chapters 22–24 dive deep into each target's migration paths. Here's the quick reference for which methods apply where:

**Azure SQL Database (→ Chapter 22):**
- Azure Database Migration Service (online and offline)
- BACPAC import via SqlPackage or Azure portal
- Transactional replication for ongoing sync

**Azure SQL Managed Instance (→ Chapter 23):**
- Log Replay Service (free, log-shipping-based)
- Managed Instance Link (online, Always On-based replication)
- Azure Database Migration Service
- Native backup/restore from Azure Blob Storage

**SQL Server on Azure VMs (→ Chapter 24):**
- Azure Migrate (full-server lift-and-shift)
- Backup/restore, log shipping, detach/attach
- Distributed availability group migration (near-zero downtime)
- Azure Database Migration Service
- VHD conversion and upload

## Migrating from Non-Microsoft Databases

Not every migration starts from SQL Server. If you're coming from Oracle, MySQL, Access, Db2, or SAP ASE, the path runs through **SQL Server Migration Assistant (SSMA)**.

### What SSMA Does

SSMA is a free, downloadable tool that handles three things:

1. **Schema conversion.** SSMA reads the source database schema — tables, views, stored procedures, triggers, functions — and converts it to T-SQL equivalents. It handles data type mapping (Oracle's `NUMBER` to SQL Server's `decimal`, MySQL's `ENUM` to a check constraint, and so on) and flags constructs that can't be automatically converted.

2. **Assessment.** Before converting anything, SSMA generates a report showing conversion complexity — what converts cleanly, what needs manual intervention, and what won't convert at all. Use this report to estimate effort.

3. **Data migration.** After schema conversion, SSMA migrates the actual data from the source to the target. It handles type coercions, character set conversions, and identity column seeding.

### Supported Sources

| Source | SSMA Version | Target Support |
|---|---|---|
| Microsoft Access | SSMA for Access | SQL Server, SQL DB, MI |
| IBM Db2 | SSMA for Db2 | SQL Server, SQL DB, MI |
| MySQL | SSMA for MySQL | SQL Server, SQL DB, MI |
| Oracle | SSMA for Oracle | SQL Server, SQL DB, MI, Synapse |
| SAP ASE (Sybase) | SSMA for SAP ASE | SQL Server, SQL DB, MI |

<!-- TODO: source needed for "SSMA supported sources table" — no SSMA documentation found in docs mirror. Writer must add SSMA docs to the mirror or provide a direct reference. -->

> **Gotcha:** SSMA handles *schema and data* migration but doesn't migrate application code. Stored procedures with Oracle PL/SQL or MySQL-specific syntax get converted to T-SQL, but your application's SQL queries — embedded in Java, C#, Python, or whatever you're running — need manual review and testing. Budget time for this.

### The Migration Lifecycle

A non-Microsoft database migration follows a different rhythm than a SQL Server migration:

1. **Assess with SSMA.** Connect to the source, generate the assessment report, and review conversion complexity. If 95% of objects convert cleanly, you're in good shape. If 60% do, budget significant development time.

2. **Convert the schema.** Run SSMA's conversion. Review every object it flags for manual intervention. Pay special attention to stored procedures — they're where the most platform-specific logic lives.

3. **Validate data type mappings.** SSMA provides default type mappings, but they're not always right for your data. Oracle's `VARCHAR2(4000)` maps to SQL Server's `nvarchar(4000)` by default, but if your data is ASCII-only, `varchar(4000)` saves half the storage. Review and adjust before migration.

4. **Migrate data.** SSMA handles this, but for large tables, consider using SSIS or bcp for better performance and control.

5. **Test everything.** Run your application's full test suite against the target. SSMA conversion isn't perfect — edge cases in date handling, null semantics, and implicit type conversions will surface during testing.

> **Important:** SSMA is the right tool for non-Microsoft sources migrating to Azure SQL. Don't confuse it with Azure Database Migration Service, which handles SQL Server-to-Azure SQL migrations. They're complementary tools for different source platforms.

The next three chapters walk you through execution — one chapter per target. If you've done the planning work in this chapter, you know your target, your method, and your blockers. Now it's time to move the data.
