# Chapter 2: Core Concepts and Terminology

Azure SQL has its own vocabulary. Some of it overlaps with on-premises SQL Server, some of it doesn't, and some of it looks familiar but means something subtly different. Before you provision anything or write a single query, you need a shared language for the concepts you'll use throughout this book — and throughout your career with the platform.

This chapter gives you that language. We'll define the key terms, explain the two purchasing models, walk through service tiers and compute tiers, and cover the resource governance system that enforces limits behind the scenes. By the end, you'll be able to read any Azure SQL documentation or configuration screen and know exactly what every setting means.

## The Azure SQL Glossary

If you're coming from on-premises SQL Server, some Azure SQL terminology will trip you up. A few terms are borrowed but redefined. Others are entirely new. Here's what you need to know upfront.

### Terms That Shift Meaning

**Instance** in on-premises SQL Server means a running copy of the database engine with its own memory, tempdb, and system databases. In Azure SQL, the word "instance" only applies to **Azure SQL Managed Instance**, which deliberately mirrors that on-premises concept. Azure SQL Database doesn't have instances — it has **logical servers** and **databases**. Confusing them leads to wrong architecture decisions.

**Server** on-premises means a physical or virtual machine running SQL Server. In Azure SQL Database, a **logical server** is an administrative construct — not a machine, not an instance. It's a management boundary for logins, firewall rules, and auditing policies. We'll cover this in detail shortly.

**Database** means roughly the same thing everywhere, but in Azure SQL Database, each database is an isolated unit with its own dedicated resources (or a share of pooled resources). There's no `USE [OtherDatabase]` to hop between databases on the same logical server the way you'd switch context in an on-premises instance.

**Failover** on-premises usually means an Always On availability group replica taking over. In Azure SQL Database, failover happens automatically and transparently as part of the platform's high-availability architecture. You don't configure it — but you do need to handle the brief connection drops it causes.

### Purchasing Models

Azure SQL Database offers two fundamentally different ways to buy compute and storage: the **vCore model** and the **DTU model**. Every database uses one or the other. Your choice affects which service tiers are available, how billing works, and how much control you have over hardware.

<!-- Source: purchasing-models/purchasing-models.md -->

| Concept | vCore Model | DTU Model |
|---|---|---|
| Unit | Virtual cores | Database Transaction Units |
| Bundled? | No — compute, storage, backup billed separately | Yes — CPU, memory, I/O, storage bundled |
| Service tiers | General Purpose, Business Critical, Hyperscale | Basic, Standard, Premium |
| Compute tiers | Provisioned or Serverless | Provisioned only |
| Hardware choice | Yes | No |
| Best for | Flexibility, cost transparency, advanced features | Simplicity, predictable budgets |

We'll dig deep into each model later in this chapter.

### Service Tiers

A **service tier** determines the underlying architecture, performance characteristics, storage type, and high-availability design for your database. The vCore model offers General Purpose, Business Critical, and Hyperscale. The DTU model offers Basic, Standard, and Premium. We cover each tier's architecture in detail under The vCore Purchasing Model and The DTU Purchasing Model later in this chapter.

<!-- Source: purchasing-models/service-tiers-sql-database-vcore.md, purchasing-models/service-tiers-dtu.md -->

### Compute Tiers

Within the vCore model, you choose between two **compute tiers**: provisioned (fixed vCores, billed per hour) and serverless (autoscaling, billed per second). The DTU model only offers provisioned compute. We cover provisioned and serverless in detail under The vCore Purchasing Model.

### Deployment Models

Azure SQL Database supports two deployment models:

- **Single database** — an isolated database with its own dedicated resources
- **Elastic pool** — a group of databases sharing a common set of resources

Azure SQL Managed Instance and SQL Server on Azure VMs are separate products, not deployment models within SQL Database.

## The Logical Server

The **logical server** is one of the most misunderstood concepts in Azure SQL Database. If you're coming from on-premises SQL Server, you need to reset your mental model completely.

### What a Logical Server Is (and Isn't)

A logical server is a management container. It provides a connection endpoint (`<yourserver>.database.windows.net`), a namespace for databases, and a scope for policies. That's it. It's not a running SQL Server instance. It's not a machine. You can't SSH into it, you can't see its operating system, and there's no shared tempdb across databases.

<!-- Source: azure-sql-database-sql-db/concepts/logical-servers.md -->

When you create a logical server, you're creating:

- A **connection endpoint** for all databases on that server
- A **master database** that holds server-level logins and metadata
- A **management boundary** for firewall rules, auditing, threat detection, and failover groups
- A **quota scope** — each logical server can hold up to 5,000 databases

> **Important:** Deleting a logical server deletes every database, elastic pool, and dedicated SQL pool it contains. It's a strong lifetime binding — not a loose grouping.

### The Management Boundary

Here's what you configure at the logical server level:

- **Logins.** The server admin login you create during provisioning has access to the master database and administrative rights on all databases. SQL authentication and Microsoft Entra authentication are both supported.
- **Firewall rules.** IP-based allow rules apply to all databases on the server.
- **Auditing.** Server-level auditing captures events across all databases.
- **Threat detection.** Advanced Threat Protection policies apply server-wide.
- **Failover groups.** Geo-replication failover groups are configured at the server level.

> **Gotcha:** The default collation for all databases created on a logical server is `SQL_LATIN1_GENERAL_CP1_CI_AS`. You can't change the server's default collation after creation, though you can specify a different collation for each individual database at creation time.

### How Logical Servers Differ from SQL Server Instances

On-premises, if you have three databases on one instance, they share memory, tempdb, and CPU. You can cross-database query freely. You manage them as a unit.

With a logical server, each database is an independent resource allocation. Databases on the same logical server don't share compute or memory. Cross-database queries work only in limited scenarios (elastic queries). You can't create user objects (tables, views, stored procedures) in the server's master database.

> **Note:** A logical server can live in a different region than its resource group. All databases on a logical server are created in the same region as the server. By default, Azure subscriptions can have up to 250 logical servers per region.

<!-- Source: azure-sql-database-sql-db/concepts/logical-servers.md -->

## Single Databases and Elastic Pools

These are the two deployment models within Azure SQL Database. The core question: does this database need its own dedicated resources, or can it share with others?

### Single Database: Isolated, Dedicated Resources

A **single database** is the simplest deployment model. You create one database, assign it a service tier and compute size, and it gets its own dedicated resources. It runs on its own database engine instance, isolated from every other database.

Single databases are the right choice when:

- Your database has predictable, steady resource requirements
- You need full control over the resource allocation for a specific workload
- The workload doesn't benefit from sharing resources with other databases

You can change the service tier or compute size at any time — scale up or down — with minimal downtime. A single database can also be moved into or out of an elastic pool without downtime (aside from a brief connection drop at the end of the operation).

<!-- Source: azure-sql-database-sql-db/concepts/single-database-overview.md -->

### Elastic Pools: Shared Resources for Variable Workloads

An **elastic pool** lets multiple databases share a common set of compute and storage resources. The databases in a pool all live on a single logical server and share a set number of resources (eDTUs or vCores) at a set price.

The concept is simple: you allocate resources to the pool, not to individual databases. Each database in the pool autoscales within the pool's shared resources:

- The pool holds a fixed total of eDTUs or vCores.
- Each database has a configurable **minimum** (guaranteed floor) and **maximum** (burst ceiling).
- A database under heavy load draws more from the pool; an idle database draws little or nothing.

<!-- Source: azure-sql-database-sql-db/concepts/elastic-pool-overview.md -->

> **Important:** There's no per-database charge for elastic pools. You're billed for each hour the pool exists at its configured eDTU or vCore level, regardless of how much or how little individual databases use.

#### When to Pool

Pools work best when you have databases with **low average utilization and infrequent spikes**, especially when those spikes don't overlap in time. The classic scenario is a SaaS application with a database per tenant, where each tenant's activity is unpredictable but the aggregate is smooth.

Here's the decision framework:

| Factor | Pool | Single Database |
|---|---|---|
| Usage pattern | Bursty, variable | Steady, predictable |
| Peak overlap | Low | N/A |
| Number of databases | Many (2+) | One |
| Budget priority | Shared cost savings | Dedicated performance |
| Workload profiles | Similar tier needs | N/A |

#### When Not to Pool

Not every collection of databases belongs in a pool. Watch for these anti-patterns:

- **Persistently hot databases.** If one database consistently uses a large share of the pool's resources, it starves the others. Move it out to a single database.
- **Incompatible workload profiles.** Databases with wildly different service tier needs (one needs Business Critical latency, another is fine with General Purpose) can't share a pool effectively — pools are configured at a single service tier.
- **Approaching the database limit.** As the number of databases in a pool approaches the maximum, resource management becomes increasingly complex. Dense pools require careful capacity planning.

> **Tip:** In the vCore model, the per-vCore price for elastic pools is the same as for single databases. The savings come from sharing — you buy fewer total vCores than you'd need if every database had its own dedicated allocation. In the DTU model, the per-eDTU price is 1.5× the per-DTU price for single databases, but fewer total eDTUs are needed.

<!-- Source: azure-sql-database-sql-db/concepts/elastic-pool-overview.md -->

## The vCore Purchasing Model

The vCore (virtual core) model is Microsoft's recommended purchasing model for Azure SQL Database. It gives you independent control over compute, storage, and backup — each billed separately. It's the only model that supports Hyperscale, serverless compute, and hardware selection.

### How Billing Works

In the vCore model, you pay for four things independently:

1. **Compute** — the number of vCores and their service tier. Provisioned compute bills per hour; serverless bills per second.
2. **Data storage** — you're charged for the maximum data size you configure (General Purpose and Business Critical) or actual allocated storage (Hyperscale). The default max data size is 32 GB. When you configure a max data size, an additional 30% is automatically added for log file space.
3. **Backup storage** — automated backups use separate storage. You get backup storage equal to 100% of your configured max data size at no extra charge. Retention is configurable from 1 to 35 days (default 7). Long-term retention (up to 10 years) costs extra.
4. **Additional replicas** (Hyperscale only) — each additional HA replica incurs compute charges.

<!-- Source: purchasing-models/service-tiers-sql-database-vcore.md -->

> **Note:** In the Business Critical tier, the price is approximately 2.7× higher than General Purpose for the same vCore count. This reflects the three additional HA replicas and local SSD storage that Business Critical provides automatically.

### Hardware Generations and Configuration

Unlike the DTU model (where the platform picks your hardware), the vCore model lets you choose a **hardware configuration**:

- **Standard-series (Gen5)** — Broadwell through Emerald Rapids CPUs, 5.1 GB/vCore, up to 128 vCores
- **Premium-series** — faster CPUs, higher max vCores, Hyperscale only
- **Premium-series memory optimized** — 10.2 GB/vCore (2× standard), Hyperscale only
- **DC-series** — Intel SGX enclaves, up to 8 physical cores, for Always Encrypted with secure enclaves

<!-- Source: purchasing-models/service-tiers-sql-database-vcore.md -->

Serverless compute is only available on Standard-series (Gen5) hardware.

> **Gotcha:** A database can be moved to different hardware behind the scenes — during scale operations, when infrastructure approaches capacity, or when hardware is decommissioned. Resource limits stay the same for a given service objective regardless of CPU type, but real-world workload performance can vary slightly across CPU generations.

### Service Tiers Under vCore

#### General Purpose

The workhorse tier. It uses a **separation of compute and storage**: a stateless compute node running `sqlservr.exe` connects to database files stored in Azure Blob storage. If the node fails, Azure Service Fabric spins up a new one and reattaches the storage. You get enterprise-class availability, but with the trade-off of 5–10 ms I/O latency from remote storage.

<!-- Source: purchasing-models/service-tiers-sql-database-vcore.md -->

Key specs:

- 2 to 128 vCores
- 1 GB to 4 TB storage
- 320 IOPS per vCore, 16,000 max IOPS
- Remote Azure Blob storage
- One replica, no built-in read scale-out
- Zone-redundant HA available

#### Business Critical

Built on an **Always On availability group** architecture with four nodes — one primary and three secondaries. Data and log files live on local SSD, which delivers 1–2 ms I/O latency. One secondary replica is automatically available for read-only workloads at no extra charge.

Key specs:

- 2 to 128 vCores
- 1 GB to 4 TB storage
- 4,000 IOPS per vCore, 327,680 max IOPS
- Local SSD storage
- Three HA replicas, one readable
- In-Memory OLTP support
- Zone-redundant HA available

<!-- Source: purchasing-models/service-tiers-sql-database-vcore.md -->

> **Tip:** Business Critical is the only tier in the vCore model (besides Hyperscale with premium-series hardware) that supports In-Memory OLTP tables. If your workload needs in-memory capabilities, this narrows your choices.

#### Hyperscale

Hyperscale is a fundamentally different architecture. It decouples compute, log, and storage into independent services that scale independently. Storage can grow up to 128 TB. You control the number of HA replicas (0 to 4), and you can create up to 30 named read-only replicas for scale-out scenarios.

Key specs:

- 2 to 128 vCores (up to 192 on premium-series, currently in preview)
- 10 GB to 128 TB storage (auto-growing, billed on actual allocation)
- Multi-tiered storage with local SSD cache
- 0 to 4 configurable HA replicas
- Serverless and provisioned compute
- Near-instant backups (snapshot-based, regardless of database size)

<!-- Source: hyperscale/service-tier-hyperscale.md -->

Hyperscale doesn't support durable or non-durable memory-optimized tables. It does support a subset of In-Memory OLTP objects — memory-optimized table types, table variables, and natively compiled modules. Hyperscale is worth evaluating first for workloads that need large storage, fast scaling, or rapid backup and restore.

<!-- Source: hyperscale/service-tier-hyperscale.md, in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

### Provisioned vs. Serverless Compute

**Provisioned compute** gives you a fixed number of vCores, always running, billed per hour. The database is always warm. Performance is immediate and consistent.

**Serverless compute** autoscales between a configurable min and max vCore range. You pay per second for the compute you actually use. In the General Purpose tier, the database can auto-pause after a configurable inactivity delay, dropping compute cost to zero — only storage is billed. When activity resumes, the database auto-resumes (with a brief warm-up delay).

<!-- Source: azure-sql-database-sql-db/concepts/serverless-tier-overview.md -->

| Aspect | Provisioned | Serverless |
|---|---|---|
| Scaling | Manual | Automatic |
| Billing | Per hour | Per second |
| Auto-pause | No | Yes (GP only) |
| Cold start | No | Yes, after pause |
| Best for | Steady workloads | Intermittent, unpredictable |

> **Note:** Auto-pause and auto-resume are currently supported only in the General Purpose service tier. Hyperscale serverless supports autoscaling but not auto-pause.

> **Gotcha:** Serverless databases reclaim memory more aggressively than provisioned databases. When CPU or cache utilization drops, the SQL cache shrinks to control costs. This can cause performance variability after quiet periods as the cache rewarms. If your workload can't tolerate that, provisioned is the safer choice.

## The DTU Purchasing Model

The **DTU (Database Transaction Unit)** model bundles compute, memory, I/O, and storage into a single unit. You pick a tier and a DTU level, and you're done. It's simpler than vCore but less flexible.

### What a DTU Actually Measures

A DTU is a blended measure of CPU, memory, reads, and writes, calibrated against a specific OLTP benchmark workload. Doubling your DTUs roughly doubles the resources available to your database. A Premium P11 database with 1,750 DTUs has about 350× the compute power of a Basic database with 5 DTUs.

<!-- Source: purchasing-models/service-tiers-dtu.md, reference/dtu-benchmark.md -->

The benchmark runs nine transaction types against a six-table schema. Transaction types include reads (lite, medium, heavy), updates, inserts, deletes, and a CPU-heavy operation. The workload mix is roughly 2:1 read-to-write, with transactions selected randomly from a weighted distribution. Each simulated user generates about one transaction per second.

The database size, user count, and maximum throughput all scale proportionally through a scale factor. Response time targets vary by tier:

- **Premium** measures transactions per second at a 95th-percentile response of 0.5 seconds
- **Standard** measures per minute at 1.0 second
- **Basic** measures per hour at 2.0 seconds

But here's the thing: your workload isn't the benchmark. If your workload is CPU-heavy but light on I/O, or vice versa, a DTU rating won't tell you exactly how it'll perform.

> **Tip:** You can calculate your current DTU utilization with this formula: `DTU% = MAX(avg_cpu_percent, avg_data_io_percent, avg_log_write_percent)`. The inputs come from `sys.dm_db_resource_stats`. Whichever resource dimension is highest becomes the binding constraint.

### The Bundled Model

Everything is included in the DTU price:

- **Compute** — CPU, memory, and I/O capacity scale with the DTU count
- **Storage** — included in the bundle (Basic: 2 GB max, Standard: 1 TB max, Premium: 4 TB max). Standard and Premium tiers allow purchasing extra storage.
- **Backup storage** — retention is 1–7 days for Basic, 1–35 days for Standard and Premium (default 7). Long-term retention up to 10 years is available but billed separately.

### Service Tiers Under DTU

**Basic** — 5 DTUs max, 2 GB storage, HDD-based. Meant for light dev/test workloads. No columnstore, no In-Memory OLTP.

**Standard** — up to 3,000 DTUs, up to 1 TB storage. I/O latency is ~5 ms read, ~10 ms write. Columnstore is available at S3 and above. Lower tiers (S0, S1) still use HDD; S3+ uses SSD.

**Premium** — up to 4,000 DTUs, up to 4 TB storage, local SSD with ~2 ms read/write latency. Supports columnstore and In-Memory OLTP. Over 25 IOPS per DTU.

<!-- Source: purchasing-models/service-tiers-dtu.md -->

> **Important:** Basic, S0, and S1 service objectives provide less than one vCore of CPU. For CPU-intensive workloads, S3 or higher is recommended. Basic, S0, and S1 use HDD-based storage — fine for dev/test, not great for production.

### eDTUs for Elastic Pools

When databases share an elastic pool under the DTU model, the pool's resources are measured in **eDTUs** (elastic Database Transaction Units). An eDTU is functionally identical to a DTU — the "e" just signifies that the resources are pooled rather than dedicated.

You configure a total number of eDTUs for the pool, then set per-database min and max eDTU limits. Individual databases autoscale within those bounds. The pool guarantees that no single database can consume all the resources — every database gets at least its configured minimum.

Pool limits by tier:

- **Basic** — up to 1,600 eDTUs, 500 databases, 156 GB storage
- **Standard** — up to 3,000 eDTUs, 500 databases, 4 TB storage
- **Premium** — up to 4,000 eDTUs, 100 databases, 4 TB storage

<!-- Source: purchasing-models/service-tiers-dtu.md -->

### When DTU Still Makes Sense

The DTU model isn't obsolete. It's simpler, and for workloads that match the bundled profile, it can be cost-effective. Here's where it fits:

- **Dev/test environments** where you want a cheap, simple database and don't care about hardware specifics
- **Small production workloads** with predictable resource needs that fit neatly into a DTU tier
- **Legacy applications** that were originally configured on DTU and work fine — migration has cost but limited benefit

Here's where you should move to vCore:

- You need Hyperscale or serverless
- You want to choose your hardware generation
- You want Azure Hybrid Benefit savings (vCore only)
- You need reserved instance pricing (vCore only)
- You need higher resource limits than DTU provides
- You need independent control over compute and storage

## Migrating Between Purchasing Models

Switching from DTU to vCore (or back) is an online operation. No downtime for your application — it's similar to scaling between tiers. You can do it from the portal, PowerShell, Azure CLI, or T-SQL.

<!-- Source: how-to/migrate/migrate-dtu-to-vcore.md -->

### DTU-to-vCore Mapping

The rough conversion rules:

- Basic and Standard DTU tiers → **General Purpose** vCore tier
- Premium DTU tier → **Business Critical** vCore tier (or Hyperscale, depending on requirements)
- Every 100 DTUs in Basic/Standard ≈ at least 1 vCore
- Every 125 DTUs in Premium ≈ at least 1 vCore

These are approximations. For a precise mapping, query `sys.dm_user_db_resource_governance` in the context of your DTU database to see the actual hardware and vCore count being used under the hood:

```sql
SELECT
    dso.elastic_pool_name,
    dso.edition,
    dso.service_objective,
    rg.slo_name,
    rg.max_cpu,
    rg.cap_cpu,
    rg.max_db_memory
FROM sys.dm_user_db_resource_governance AS rg
CROSS JOIN sys.database_service_objectives AS dso
WHERE dso.database_id = DB_ID();
```

> **Gotcha:** If you migrate an existing Azure SQL Database to Hyperscale, you can reverse migrate back to General Purpose — but only within 45 days of the original migration. After that window closes, the move is permanent. If you need Business Critical, you must first reverse migrate to General Purpose, then change tiers. Plan accordingly.

<!-- Source: hyperscale/service-tier-hyperscale.md -->

## Resource Limits and Governance

Every Azure SQL Database operates within hard resource limits. Understanding what those limits are, how they're enforced, and what happens when you hit them is fundamental to running production workloads.

### What Gets Limited

The platform enforces limits on:

- **CPU** — measured as a percentage of the allocated compute
- **Memory** — total memory available to the database engine
- **Data I/O (IOPS and throughput)** — reads and writes against data files
- **Transaction log rate** — MB/s of log generation
- **Storage** — maximum data size, log size, and tempdb size
- **Sessions and workers** — concurrent connections and execution threads
- **Tempdb** — size limits vary by tier and compute size

<!-- Source: resource-limits/resource-limits-logical-server.md -->

### What Happens When You Hit a Limit

Each resource type responds differently to saturation:

| Resource | Behavior at Limit |
|---|---|
| CPU | Queries queue and slow down; possible timeouts |
| Memory | Cache shrinks; out-of-memory errors in extreme cases |
| Data I/O | Requests throttled to stay within IOPS/throughput caps |
| Log rate | Writes delayed; `LOG_RATE_GOVERNOR` wait type appears |
| Storage | Inserts/updates fail; SELECTs and DELETEs still work |
| Sessions/workers | New requests rejected with error 10928 |

> **Gotcha:** Hitting the session/worker limit is one of the most common surprises in production. The error message mentions a "request limit," but the actual constraint is the number of concurrent **workers** (threads). If your queries use parallel execution plans (MAXDOP > 1), each query consumes multiple workers. You can hit the worker limit long before you hit the session limit.

### Resource Governor Internals

Behind the scenes, Azure SQL Database uses a customized version of SQL Server's **Resource Governor** to enforce limits. Here's how the architecture works:

1. **Resource pools** — containers with CPU, memory, and I/O limits. User workloads go to the `SloSharedPool1` pool; internal workloads (backups, replication, monitoring) go to separate pools.
2. **Workload groups** — within each pool, workloads are classified into groups. Your database's user workload runs in a group named `UserPrimaryGroup.DBId[N]`, where `N` is the database ID.
3. **OS-level governance** — Windows Job Objects enforce process-level CPU and memory limits. File Server Resource Manager (FSRM) enforces storage quotas.

<!-- Source: resource-limits/resource-limits-logical-server.md -->

The governance is hierarchical: OS limits → resource pool limits → workload group limits. The tightest constraint at any level wins.

> **Tip:** You can see the actual resource governance limits in effect for your database by querying `sys.dm_user_db_resource_governance`. This view shows the real caps — max CPU, max IOPS, max log rate, max workers, max memory — regardless of what the published documentation tables say.

```sql
SELECT *
FROM sys.dm_user_db_resource_governance
WHERE database_id = DB_ID();
```

### Log Rate Governance

Log rate governance deserves special attention because it catches people off guard. Azure SQL Database enforces a maximum rate of transaction log generation (in MB/s). This limit exists to ensure log backups stay within SLA targets and to prevent one database from overwhelming the replication pipeline.

You'll feel log rate governance during bulk operations: `INSERT INTO ... SELECT`, bulk inserts, index rebuilds. The engine doesn't throttle physical I/O to the log file — instead, it delays log record *generation* at the subsecond level.

<!-- Source: resource-limits/resource-limits-logical-server.md -->

When you're being throttled, you'll see these wait types:

| Wait Type | Meaning |
|---|---|
| `LOG_RATE_GOVERNOR` | Database-level log rate limit |
| `POOL_LOG_RATE_GOVERNOR` | Pool-level log rate limit |
| `INSTANCE_LOG_RATE_GOVERNOR` | Instance-level log rate limit |
| `HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE` | HA replication can't keep up |
| `HADR_THROTTLE_LOG_RATE_LOG_SIZE` | Approaching log space limits |

Your options when log rate governance is your bottleneck:

- **Scale up** to a higher compute size or service tier
- **Use Hyperscale**, which offers the highest log rates — 100 MiB/s per database on standard-series hardware, 150 MiB/s on premium-series and memory-optimized premium-series
- **Load transient data into tempdb** instead of user tables (tempdb is minimally logged)
- **Use columnstore or data compression** to reduce the volume of log records generated

### Tempdb Sizing

Tempdb in Azure SQL Database is backed by local SSD, and its size limits depend on your service tier and compute size. In General Purpose and Business Critical, tempdb space is included in the vCore price. In Hyperscale, tempdb uses local SSD on the compute replica.

Tempdb sizing is documented per service objective in the resource limit tables (→ see Appendix A). The key point: tempdb space is finite, shared with data and log files in Business Critical (where everything is on local SSD), and can cause out-of-space errors if your workload generates large temp tables or uses heavy spooling.

> **Warning:** In Premium and Business Critical tiers, if the combined local storage consumption by data files, transaction log files, and tempdb exceeds the maximum local storage limit, you'll get an out-of-space error — even if the data file hasn't hit its maximum configured size. The constraint is the physical local SSD, not the logical file limit.

### Reading the Limit Tables

The official documentation publishes detailed resource limit tables for every combination of purchasing model, service tier, and compute size. They cover max data size, max log rate, max IOPS, max workers, max sessions, and tempdb limits.

These tables are essential reference material, but they're dense. You'll find the complete tables in Appendix A. Here's how to read them effectively:

1. **Start with your purchasing model** (vCore or DTU).
2. **Pick your service tier** (General Purpose, Business Critical, Hyperscale for vCore; Basic, Standard, Premium for DTU).
3. **Find your compute size** (number of vCores or DTUs).
4. **Read across** to find the specific limit you care about.

Remember that the published limits are *maximums*. Actual performance depends on your workload pattern, data distribution, and whether Resource Governor feedback mechanisms are applying additional back-pressure.

## The Feature Comparison Matrix

Not every SQL Server feature is available in every Azure SQL deployment option. Azure SQL Database, Managed Instance, and SQL Server on Azure VMs each support a different subset of the SQL Server feature set.

The full matrix is in Appendix B, but here's the high-level picture:

| Feature Area | SQL Database | Managed Instance | SQL on VMs |
|---|---|---|---|
| T-SQL surface area | ~95% | ~99% | 100% |
| Cross-database queries | Via elastic query | Yes | Yes |
| SQL Server Agent | No (use Elastic Jobs) | Yes | Yes |
| CLR | No | Yes | Yes |
| Service Broker | No | Within same instance | Yes |
| Linked servers | No | Yes | Yes |
| Database Mail | No | Yes | Yes |
| Filestream/FileTable | No | No | Yes |
| In-Memory OLTP | BC and Premium tiers | Yes | Yes |

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, hyperscale/service-tier-hyperscale.md -->

The pattern is clear: **SQL Server on VMs** gives you 100% feature compatibility because it's the full product. **Managed Instance** covers nearly everything, missing only OS-level features like Filestream. **SQL Database** is the most constrained but also the most managed — the trade-off for a fully PaaS experience is a reduced feature surface.

> **Note:** The T-SQL differences between SQL Database and on-premises SQL Server are documented in detail in the docs mirror. Most gaps involve server-level features (cross-database queries, CLR, Service Broker) that don't apply in a fully managed, multi-tenant architecture. For a comprehensive list, see the T-SQL differences documentation and the full feature matrix in Appendix B.

When you're choosing a deployment option, start with the feature matrix. If your application depends on CLR assemblies, Service Broker, or cross-database queries, SQL Database won't work without refactoring. If you need full control of the OS, only VMs will do. For everything else, the question is how much management overhead you want to take on — and that's where the service tiers, purchasing models, and resource governance we've covered in this chapter become your decision-making tools.

Chapter 3 puts all of these concepts into practice: you'll provision your first Azure SQL resources and see exactly how these settings map to real infrastructure.
