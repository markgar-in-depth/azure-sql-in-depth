# Chapter 10: The Hyperscale Service Tier

General Purpose gives you a solid workhorse. Business Critical gives you speed and local redundancy. But both share a fundamental constraint: compute and storage are bolted together. When your database outgrows the box it lives on, scaling means waiting for data to move — and eventually, you hit a ceiling where no box is big enough. Hyperscale throws that entire model out and replaces it with something radically different.

This chapter takes you inside the Hyperscale architecture — what it is, how its components work together, and why it behaves differently from the other tiers. You'll learn how replicas, elastic pools, serverless, and migration work in Hyperscale, and when this tier is (and isn't) the right choice.

## Hyperscale Architecture

Understanding these distributed, independently scalable components is the key to understanding everything else Hyperscale does.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-architecture.md -->

### The Four Components

A Hyperscale database consists of four types of components: **compute nodes**, **page servers**, the **log service**, and **Azure Storage**. All communication between them runs over Azure's internal network.

**Compute nodes** are where the relational engine lives — query processing, transaction management, and language interpretation all happen here. The primary compute node handles read-write workloads. Secondary compute nodes (HA replicas, named replicas, geo-replicas) handle read-only traffic.

Each compute node maintains a local SSD cache called the **Resilient Buffer Pool Extension (RBPEX)**. RBPEX keeps frequently accessed pages close to the engine, minimizing round-trips to page servers. Its size scales with compute — more vCores means a larger RBPEX cache, which is one of the primary levers for tuning read performance in Hyperscale.

**Page servers** are a scaled-out storage engine. Each page server owns a subset of the database's pages, serves them to compute nodes on demand, and keeps them current by replaying transaction log records received from the log service. Each page server manages up to 128 GB of data and maintains its own SSD cache. As the database grows, Hyperscale adds more page servers automatically.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-architecture.md -->

**The log service** is the coordination backbone. It accepts transaction log records from the primary compute replica and fans them out to page servers and secondary compute replicas. Log records are also pushed to Azure Storage for long-term durability. Because log durability is handled by the log service rather than by writing to local disk, the common causes of log growth in traditional SQL Server — missed log backups, slow replication — don't apply here.

**Azure Storage** holds all data files and provides the durability layer. Page servers keep their files in Azure Storage. Backups use storage snapshots, which is why they're nearly instantaneous regardless of database size. When you create a Hyperscale database, you choose a storage redundancy option — LRS, ZRS, RA-GRS, or RA-GZRS — and that choice applies for the lifetime of the database, covering both data and backups.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-architecture.md, azure-sql-database-sql-db/concepts/hyperscale/hyperscale-automated-backups-overview.md -->

> **Important:** Storage redundancy for a Hyperscale database can only be set at creation time. You can't change it afterward. If you need to change redundancy on an existing database, you'll need to create a new database via active geo-replication or database copy.

### How Hyperscale Differs from General Purpose and Business Critical

The table below captures the structural differences that matter most in practice. GP = General Purpose, BC = Business Critical.

| Aspect | GP | BC | Hyperscale |
|---|---|---|---|
| Max storage | 4 TB | 4 TB | 128 TB |
| Storage type | Remote | Local SSD | Page servers + SSD cache |
| Max vCores | 128 | 128 | 128 GA (160/192 preview) |
| Read replicas | None | 1 built-in | Up to 4 HA + 30 named |
| Log throughput | Governed | Governed | Up to 100–150 MiB/s per DB¹ |
| Backup mechanism | File-based | File-based | Storage snapshots |
| Restore speed | Size-dependent | Size-dependent | Minutes (snapshot-based) |

<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md -->

¹ Elastic pool limits differ: 150 MiB/s for premium-series pools, 125 MiB/s for other hardware. See the Performance Diagnostics section for the full breakdown.

The most important conceptual shift: in General Purpose and Business Critical, storage is attached to a compute instance. In Hyperscale, storage is a separate tier of independently managed components. This decoupling is what drives Hyperscale's fast scaling, fast backup, massive capacity, and elastic read scale-out.

### The Scaling Model

Hyperscale databases don't have a max size you configure. Storage starts at 10 GB and grows automatically in 10 GB increments, up to 128 TB for standalone databases or 100 TB per database in an elastic pool. You pay for allocated storage, not provisioned capacity.

Compute scaling is equally flexible. Scaling up or down is a constant-time operation because you're not moving data — you're just pointing a new compute node at the same page servers. This takes minutes for provisioned compute and under a second for serverless.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-frequently-asked-questions-faq.md -->

> **Tip:** Because storage auto-grows and can't be hard-capped, monitor your allocated storage to avoid surprise costs. There's no way to set a storage ceiling on a Hyperscale database.

### Continuous Priming

When a new HA replica comes online — whether after scaling, failover, or maintenance — it starts with cold caches. On traditional tiers, the only way to warm the cache is to run the actual workload, which means degraded performance until the working set is back in memory.

Hyperscale addresses this with **continuous priming**. The system continuously tracks the hottest pages across all compute replicas, and new HA secondaries use this information to proactively fill their buffer pool and RBPEX cache. The result: more consistent performance across failovers. Continuous priming is available on **premium-series and memory-optimized premium-series hardware** in the Hyperscale provisioned compute tier. It's not available on standard-series (Gen5) hardware or on serverless.

> **Note:** Named replicas do not benefit from continuous priming. Only HA secondary replicas on supported hardware participate.

<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-frequently-asked-questions-faq.md -->

## Hyperscale Replicas

Hyperscale supports three types of secondary replicas, each with a distinct purpose. You can use them independently or combine all three.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-replicas.md -->

### HA Replicas

**High-availability (HA) replicas** are hot standbys. They share the same page servers as the primary — no data copy needed — and are always ready for automatic failover. You can have zero to four HA replicas per primary.

HA replicas use the same server name, database name, and service level objective as the primary. They're not visible as separate resources in the portal or APIs. You manage the count through the usual management tools when creating or updating the database.

When you connect with `ApplicationIntent=ReadOnly`, the connection routes to an available HA replica. If multiple HA replicas exist, read-only connections are distributed arbitrarily across them. Each replica may have slightly different data latency relative to the primary, because log records are applied asynchronously.

```csharp
// Connection string routing to a read-only HA replica
Server=tcp:myserver.database.windows.net;Database=mydb;
ApplicationIntent=ReadOnly;User ID=mylogin;Password=***;
Encrypt=True;
```

> **Gotcha:** If no HA replicas exist, a `ReadOnly` connection still succeeds — it just routes to the primary. Your app won't get an error, but it won't get read scale-out either.

The cost model is straightforward: each HA replica is billed at the same compute rate as the primary. No additional storage cost applies because HA replicas share page servers with the primary.

For mission-critical workloads, provision at least one HA replica. Without one, failover requires creating a new replica from scratch, which can take a minute or two and leaves you with cold caches. With an HA replica, failover takes seconds.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-replicas.md -->

### Named Replicas

**Named replicas** are the primary mechanism for read scale-out. Unlike HA replicas, named replicas are first-class database resources — they appear in the portal, have their own server name and database name, and can have a different service level objective from the primary.

You can create up to 30 named replicas per primary database. Each named replica can itself have up to four HA replicas. They share page servers with the primary (no data copy), but because they have independent compute, scaling a named replica doesn't affect the primary or other replicas.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-replicas.md -->

Key capabilities:

- **Independent compute sizing.** A named replica serving Power BI dashboards might need 16 vCores, while one feeding a data science pipeline might need 40. Size each independently.
- **Security isolation.** Each named replica can have different logins and permissions. Grant analysts access to a named replica without exposing the primary.
- **Workload-dependent routing.** Group named replicas by consumer — four replicas for the mobile app, two for the web app — and tune performance and cost per group.
- **Named replicas must be in the same region as the primary.** They can be on a different logical server, but the server must be in the same region.

Named replicas also support zone redundancy, provided the primary database is zone-redundant. This distributes the named replica's compute nodes across availability zones for higher resilience.

> **Note:** Named replicas can't be placed in a Hyperscale elastic pool. They must be created as standalone Hyperscale databases.

### Geo-Replicas

**Geo-replicas** provide cross-region disaster recovery through active geo-replication. Unlike HA and named replicas, a geo-replica has its own set of page servers — it's a full copy of the data in a separate region.

Current limitations to know:

- Only one geo-replica per primary database (the ability to create multiple geo-replicas is in preview).
- Point-in-time restore of the geo-replica isn't supported.
- Geo-replica chaining (geo-replica of a geo-replica) isn't supported.

Geo-replicas can be placed in elastic pools and can serve read-only workloads in the secondary region. Data replication is asynchronous, so there's some replication lag.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-replicas.md -->

### Identifying Replicas

When you're verifying that a scaling operation added the expected HA replicas, confirming geo-replica status during a DR drill, or troubleshooting replication lag, you need to see all replicas and their roles. Query them from the primary using the `sys.dm_hs_database_replicas` DMV:

```sql
SELECT replica_role_desc, replica_server_name, replica_id
FROM sys.dm_hs_database_replicas(DB_ID(N'Contosodb'));
```

## Hyperscale Elastic Pools

Hyperscale elastic pools bring the pooling model to Hyperscale databases — shared compute and log resources across a group of databases, with independent page servers per database.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-elastic-pool-overview.md -->

### How Pooling Works in Hyperscale

The architecture mirrors standalone Hyperscale, but with shared resources:

- A **primary pool** hosts primary Hyperscale databases. All databases in the pool share the SQL Server compute process, vCores, memory, SSD cache, and log service.
- **HA pools** (up to four) contain read-only replicas for the databases in the primary pool. Each HA pool shares its own set of compute and cache resources.
- **Page servers remain per-database.** Each database in the pool has its own set of page servers. This is the key architectural distinction from compute and log, which are shared.

Adding a non-Hyperscale database to a Hyperscale elastic pool automatically converts it to the Hyperscale tier. There's no in-place conversion of an existing non-Hyperscale elastic pool to Hyperscale — you create a new Hyperscale pool and move databases into it.

### Creating and Scaling Hyperscale Elastic Pools

You manage Hyperscale elastic pools with the same commands as other pooled databases. Specify `Hyperscale` as the edition when creating the pool.

```sql
-- Convert General Purpose databases into a Hyperscale elastic pool
ALTER DATABASE gpdb1 MODIFY (SERVICE_OBJECTIVE = ELASTIC_POOL(NAME = [hsep1]))
ALTER DATABASE gpdb2 MODIFY (SERVICE_OBJECTIVE = ELASTIC_POOL(NAME = [hsep1]))
```

Each `ALTER DATABASE` starts a background conversion. You can run multiple conversions in parallel and monitor progress via `sys.dm_operation_status`.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-elastic-pool-overview.md -->

To adjust the number of HA replicas on a pool:

```powershell
# PowerShell
Set-AzSqlElasticPool -ResourceGroupName "myRG" -ServerName "myServer" `
    -ElasticPoolName "hsep1" -HighAvailabilityReplicaCount 2
```

```azurecli
# Azure CLI
az sql elastic-pool update -g myRG -s myServer -n hsep1 --ha-replicas 2
```

### Limitations

A few constraints to keep in mind:

- You can't convert an existing non-Hyperscale elastic pool to Hyperscale (or vice versa). Move databases individually.
- Named replicas can't be placed in a Hyperscale elastic pool.
- To reverse-migrate a database from a Hyperscale pool, remove it from the pool first, then reverse-migrate the standalone database.
- Zone redundancy on a Hyperscale elastic pool can only be set at creation time.
- Only databases with zone-redundant storage (ZRS or GZRS) can be added to a zone-redundant Hyperscale elastic pool.

## Migrating To and From Hyperscale

### Converting to Hyperscale

You can convert any existing Azure SQL Database (except Basic tier — first move to General Purpose) to Hyperscale using the portal, CLI, PowerShell, or T-SQL. The conversion is an online operation with two stages:
<!-- Source: azure-sql-database-sql-db/how-to/hyperscale-databases/convert-to-hyperscale.md -->

1. **Data copy.** The system copies data to the Hyperscale storage layer while the source database remains online and writable. Duration is proportional to database size plus the volume of changes during the copy.
2. **Cutover.** A brief downtime (typically under a minute) as connections switch to the new Hyperscale database. You can choose automatic cutover or manual cutover to control the timing.

```sql
-- Convert with manual cutover for controlled timing
ALTER DATABASE [OrdersDb]
    MODIFY (EDITION = 'Hyperscale', SERVICE_OBJECTIVE = 'HS_Gen5_8')
    WITH MANUAL_CUTOVER;

-- When ready (within 24 hours):
ALTER DATABASE [OrdersDb] PERFORM_CUTOVER;
```

If the database uses geo-replication, start the conversion on the primary. The geo-secondary converts automatically. Reduce chained geo-replicas to one before starting.

> **Gotcha:** Converting from Premium or Business Critical disconnects existing client connections during the first phase. Make sure your applications have retry logic.

### Reverse Migration to General Purpose

Hyperscale offers a 45-day escape hatch. If you converted a database from another tier to Hyperscale, you can reverse-migrate back to General Purpose within 45 days of the original conversion.
<!-- Source: azure-sql-database-sql-db/how-to/hyperscale-databases/reverse-migrate-from-hyperscale.md -->

Important constraints:

- **45-day window only.** After 45 days, the migration is permanent.
- **Databases created in Hyperscale can't reverse-migrate.** The option only applies to databases that were converted to Hyperscale from another tier.
- **General Purpose only.** You can't reverse-migrate directly to Business Critical. Go to General Purpose first, then change tiers.
- **Standalone databases only.** You can't reverse-migrate directly from or to an elastic pool.
- **Size-of-data operation.** Unlike most Hyperscale scaling, reverse migration is proportional to database size because it moves data between architectures. Expect downtime during the final cutover.

```azurecli
# Reverse migrate to General Purpose
az sql db update -g myResourceGroup -s myServer -n myDb \
    --edition GeneralPurpose --service-objective GP_Gen5_4 \
    --compute-model Provisioned
```

> **Warning:** Backups from tiers older than the immediately previous one become unavailable as soon as a reverse migration starts. If you've bounced between tiers multiple times, only backups from the current and once-previous tier are recoverable.

## Hyperscale Serverless

Hyperscale serverless combines the distributed Hyperscale architecture with auto-scaling compute. Instead of provisioning a fixed vCore count, you set a minimum and maximum vCores range, and the system scales automatically based on workload demand. Billing is per-second based on actual usage.
<!-- Source: azure-sql-database-sql-db/concepts/serverless-tier-overview.md -->

Serverless is available on Hyperscale with Standard-series (Gen5) hardware. Premium-series hardware doesn't currently support serverless.

Key behaviors in Hyperscale serverless:

- **Compute auto-scaling.** The primary replica and any named or HA replicas each autoscale independently. Named replicas have their own min/max vCores configuration. HA replicas inherit the primary's configuration.
- **RBPEX cache auto-scaling.** In Hyperscale serverless, the local SSD cache (RBPEX) grows and shrinks with workload demand, up to three times the maximum memory configured.
- **Memory reclamation.** Serverless databases reclaim memory from the SQL cache more aggressively than provisioned databases. This keeps costs down but can cause more frequent cache misses under bursty workloads.

> **Gotcha:** Auto-pause is General Purpose serverless only. Hyperscale serverless doesn't support it — the database stays online and scales down to minimum vCores during idle periods. If you're moving to Hyperscale serverless expecting your database to pause and stop billing for compute, it won't. Compute bills at the minimum vCores rate even when idle.

## Hyperscale Performance Diagnostics

Hyperscale's distributed architecture introduces diagnostic patterns you won't see in other tiers. Standard SQL performance tuning still applies — Query Store, execution plans, wait stats — but you'll need additional tools to understand the distributed components.
<!-- Source: azure-sql-database-sql-db/how-to/hyperscale-databases/hyperscale-performance-diagnostics.md -->

### Log Rate Waits

Every Azure SQL Database has log rate governance, but Hyperscale has additional log rate reduction scenarios. When a page server, HA replica, or named replica falls behind in applying log records, the log service throttles the primary's log generation rate to maintain recoverability SLAs.

The wait types that signal this throttling:

| Wait Type | Cause |
|---|---|
| `RBIO_RG_STORAGE` | Page server behind |
| `RBIO_RG_REPLICA` | HA or named replica behind |
| `RBIO_RG_GEOREPLICA` | Geo-replica behind |
| `RBIO_RG_DESTAGE` | Log service falling behind |

Query `sys.dm_os_wait_stats` to detect these waits. For deeper detail, `sys.dm_hs_database_log_rate()` tells you which specific replica is behind and how much unapplied log has accumulated.

Maximum log rates by hardware:

- **Standard-series (Gen5):** 100 MiB/s per database
- **Premium-series / Premium-series memory optimized:** 150 MiB/s per database
- **Elastic pools (premium-series):** 150 MiB/s per pool
- **Elastic pools (other hardware):** 125 MiB/s per pool

<!-- Source: azure-sql-database-sql-db/how-to/hyperscale-databases/hyperscale-performance-diagnostics.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-frequently-asked-questions-faq.md -->

### Page Server Reads

In Hyperscale, a read that misses both the buffer pool and the local RBPEX cache must fetch the page from a remote page server. This is slower than a local read, and understanding the ratio of remote to local reads is critical for diagnosing I/O performance.

Several DMVs expose page server read counts alongside total reads:

- `sys.dm_exec_requests` — for in-flight queries
- `sys.dm_exec_query_stats` — for completed queries
- `sys.query_store_runtime_stats` — for Query Store history

In execution plan XML, look for the `ActualPageServerReads` and `ActualPageServerReadAheads` attributes on the `RunTimeCountersPerThread` element. These tell you exactly how many pages came from remote page servers.

If your page server read ratio is high, it means your working set exceeds the local RBPEX cache. The fix is usually to scale up compute (which increases RBPEX size) or to optimize queries to access less data.

### Local SSD Cache Analysis

The local SSD cache (RBPEX) has its own I/O statistics in `sys.dm_io_virtual_file_stats`. Rows with `database_id = 0` represent the local SSD cache.

```sql
-- RBPEX cache I/O since startup
SELECT *
FROM sys.dm_io_virtual_file_stats(0, NULL);
```

The **RBPEX cache hit ratio** is available in `sys.dm_os_performance_counters`:

```sql
SELECT *
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('RBPEX cache hit ratio', 'RBPEX cache hit ratio base');
```

A high hit ratio (above 95%) means most reads are served locally. A low ratio means your compute size may be too small for your working set, or you have scan-heavy queries touching cold data. If the ratio drops below 90%, that's your signal to investigate — look at the page server read counts (previous section) to confirm, and then either scale up compute to get a larger RBPEX cache or tune the queries driving the scans.
<!-- Source: azure-sql-database-sql-db/how-to/hyperscale-databases/hyperscale-performance-diagnostics.md -->

### Virtual File Stats in Hyperscale

`sys.dm_io_virtual_file_stats` behaves differently in Hyperscale. Here's how to read it:

- **`database_id = current DB`, `file_id ≠ 2`** — I/O against page servers. Each row typically corresponds to one page server.
- **`database_id = current DB`, `file_id = 2`** — Transaction log I/O.
- **`database_id = 0`** — Local SSD cache (RBPEX) I/O.

> **Gotcha:** Write IOPS shown for page server file IDs on the compute replica are simulated — compute never writes directly to page servers. The primary writes to the log service, and page servers replay those log records. Don't use compute-side write stats for page server performance analysis.

The `avg_data_io_percent` metric in `sys.dm_db_resource_stats` and Azure Monitor only reflects local SSD I/O in Hyperscale, not page server I/O. A 100% value means local storage IOPS governance is limiting you — scale up compute to raise the limit.

### Putting It Together: A Diagnostic Flow

When the primary is slow and you need to figure out which layer of the Hyperscale architecture is the bottleneck, work through the diagnostics in order:

1. **Check `sys.dm_os_wait_stats` for log rate waits.** If you see `RBIO_RG_STORAGE`, `RBIO_RG_REPLICA`, or `RBIO_RG_GEOREPLICA`, a downstream component is behind and throttling the primary's writes. Use `sys.dm_hs_database_log_rate()` to identify which replica or page server is lagging and how much unapplied log has accumulated.
2. **Check page server read ratios.** Query `sys.dm_exec_query_stats` or Query Store for `ActualPageServerReads` versus total reads. If the ratio is high, your working set exceeds the RBPEX cache — the slow queries are waiting on remote page server round-trips.
3. **Check the RBPEX cache hit ratio** in `sys.dm_os_performance_counters`. A ratio below 90% confirms the cache is undersized for the workload. Scale up compute to get a larger cache, or identify the scan-heavy queries driving the misses.
4. **Check `sys.dm_io_virtual_file_stats`** to see whether the bottleneck is local SSD I/O (database_id = 0) or page server I/O (database_id = current DB). High local SSD latency means IOPS governance is limiting you; high page server latency means network round-trips are the problem.

This flow narrows the problem from "the database is slow" to "page server X is behind on log replay" or "the working set is 2× the RBPEX cache size" — specific enough to act on.

## When to Choose Hyperscale

Hyperscale offers the widest range of scaling options in Azure SQL Database, but that doesn't mean it's always the right answer. Here's a framework for the decision.

### Strong Signals for Hyperscale

**Your database exceeds 4 TB (or will soon).** This is the most obvious case. General Purpose and Business Critical top out at 4 TB. Hyperscale supports up to 128 TB.

**You need read scale-out.** If your workload splits naturally into write-heavy and read-heavy streams — OLTP writes on the primary, analytics or reporting on replicas — Hyperscale's named replicas give you up to 30 independently sized read endpoints with security isolation.

**You need fast backup and restore regardless of database size.** Hyperscale backups are snapshot-based and nearly instantaneous. Restores within the same region complete in minutes, even for multi-terabyte databases.

**You need high log throughput.** At 100–150 MiB/s depending on hardware, Hyperscale offers significantly higher sustained log throughput than other tiers.

**Your workload's I/O pattern favors the page-server architecture.** Hyperscale's distributed page servers excel at workloads with large data volumes and random read patterns — the RBPEX cache absorbs the hot pages while page servers handle the long tail. Write-heavy workloads benefit from the high log throughput. But if your workload is dominated by sequential scans over cold data (large ETL passes, full-table analytics), those reads will consistently miss the RBPEX cache and hit remote page servers, adding network latency to every page fetch. For scan-heavy workloads on smaller databases, Business Critical's fully local SSD storage may actually deliver lower read latency.

**You want elastic compute scaling.** Compute scales in constant time without moving data. Serverless gives you per-second billing with auto-scaling vCores.

### What You Give Up

- **DBCC CHECKDB** isn't supported. Use `DBCC CHECKTABLE WITH TABLOCK` or `DBCC CHECKFILEGROUP WITH TABLOCK` as workarounds.
- **In-Memory OLTP tables** (durable and non-durable) must be converted to disk tables. Memory-optimized table types, table variables, and natively compiled modules are supported.
- **Reverse migration has a time limit.** See the 45-day window described in the Migrating To and From Hyperscale section. Databases created in Hyperscale (not converted to it) can never be moved to another tier except via export/import.
- **Storage redundancy is permanent.** Choose carefully at creation time.
- **Hyperscale is SQL Database only** — it's not available for Managed Instance.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md -->

### Decision Criteria at a Glance

| Criterion | Hyperscale | GP or BC |
|---|---|---|
| Database > 4 TB | ✅ Only option | ❌ |
| Read scale-out (> 1 replica) | ✅ Up to 30 named | BC: 1 built-in |
| Fast PITR for large DBs | ✅ Minutes | ⏳ Hours |
| Low-latency local storage | Named/HA replicas have RBPEX | BC: full local SSD |
| DBCC CHECKDB | ❌ | ✅ |
| In-Memory OLTP tables | ❌ | BC: ✅ |
| Auto-pause (zero compute cost) | ❌ | GP serverless: ✅ |

### Anti-Patterns

**Don't choose Hyperscale for small databases just because it sounds powerful.** A 10 GB database running standard OLTP doesn't benefit from distributed page servers. General Purpose (or even a DTU tier) is simpler and often cheaper.

**Don't assume Hyperscale serverless replaces General Purpose serverless.** As noted in the Hyperscale Serverless section above, auto-pause isn't available on Hyperscale serverless. If zero-compute idle billing matters, stay on General Purpose serverless.

**Don't treat reverse migration as a safety net you can use indefinitely.** The 45-day clock described earlier starts when you convert. Test thoroughly before converting production databases.

Hyperscale is the right tier when your workload genuinely needs what the distributed architecture provides — scale, speed, or read fanout. For the rest, the simpler tiers do the job just fine. In the next chapter, we'll look at how Hyperscale's backup model (and the backup model across all tiers) keeps your data recoverable.
