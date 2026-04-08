# Chapter 14: Monitoring and Observability

Your database is running. Queries are flowing. Users aren't complaining — yet. But you have no idea if you're at 20% CPU or 95%, whether your storage is growing at a pace that'll hit limits next Tuesday, or if a query plan flipped three hours ago and doubled your response times. That's the difference between running a database and *operating* one.

This chapter gives you every tool Azure SQL provides for seeing what's happening inside your databases, from platform metrics and DMVs to Query Store, Extended Events, and the newer database watcher.

## The Azure SQL Monitoring Stack

Azure SQL monitoring divides into two layers: **platform-level monitoring** via Azure Monitor, and **engine-level monitoring** via SQL Server's built-in diagnostics — DMVs, Query Store, and Extended Events. You'll use both. Azure Monitor gives you the infrastructure view: CPU consumption, I/O percentages, connection counts. The engine gives you the query-level view: which statements are burning cycles, what's waiting, and why.

<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/monitoring-sql-database-azure-monitor.md -->

### Platform Metrics

Azure Monitor collects platform metrics automatically — no configuration required. Metrics land in a time-series database, sampled every minute, and they're lightweight enough for near-real-time alerting. Here are the metrics you'll reach for most often:

- **CPU percentage** (`cpu_percent`) — user workload CPU against the limit
- **SQL instance CPU %** (`sql_instance_cpu_percent`) — total CPU including system processes
- **Data IO percentage** (`physical_data_read_percent`) — data file I/O against the limit
- **Log IO percentage** (`log_write_percent`) — transaction log write throughput
- **Workers percentage** (`workers_percent`) — worker thread consumption
- **DTU percentage** (`dtu_consumption_percent`) — DTU-model composite metric
- **Sessions count** (`sessions_count`) — active sessions
- **Deadlocks** (`deadlock`) — deadlock count
- **Availability** (`availability`) — SLA-compliant availability

<!-- Source: reference/monitoring-data-reference/monitoring-sql-database-azure-monitor-reference.md -->

> **Tip:** `cpu_percent` measures CPU available to your *user* workload. `sql_instance_cpu_percent` includes system processes too. Don't compare them directly — they use different scales.

The **DTU percentage** metric is derived from the highest of CPU percentage, Data IO percentage, and Log IO percentage at any point in time. It's the single metric that matters most for DTU-model databases.

For **serverless databases**, three additional metrics track billing and consumption: `app_cpu_billed` (vCore-seconds billed), `app_cpu_percent`, and `app_memory_percent`. These tell you how close you are to your configured min/max vCore range.

**Elastic pool metrics** mirror the single-database metrics but report at the pool level. You'll also get `allocated_data_storage_percent` to see how much of the pool's storage budget is allocated (not just used) across member databases.

### The Availability Metric

The `availability` metric deserves its own mention because it's how Azure SQL reports SLA-compliant uptime. It's granular to one minute. The logic is straightforward:

- If at least one connection succeeds in a one-minute window, availability is 100%.
- If all connections fail due to *system* errors, availability is 0%.
- User errors (bad password, firewall blocks) don't count against availability.
- If there are no connection attempts, availability is 100%.

<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/monitoring-metrics-alerts.md -->

> **Gotcha:** The availability metric isn't currently supported for the serverless compute tier — it always shows 100%, even during auto-pause.

### Diagnostic Settings

Platform metrics are collected automatically, but **resource logs** require you to opt in. You create a **diagnostic setting** to stream telemetry to one or more destinations:

- **Log Analytics workspace** — query with KQL, integrate with Azure Monitor dashboards and SQL Analytics
- **Azure Event Hubs** — pipe to third-party SIEM or custom telemetry platforms
- **Azure Storage** — low-cost archival for compliance

<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/monitor-tune/metrics-diagnostic-telemetry-logging-streaming-export-configure.md -->

The categories you can export include Query Store runtime and wait statistics, errors, deadlocks, blocks, timeouts, database wait statistics, and automatic tuning events. For Managed Instance, Query Store statistics and errors are available, but database-level wait statistics and block/timeout categories are not.

> **Important:** Streaming export of diagnostic telemetry isn't enabled by default. You must create at least one diagnostic setting to start capturing resource logs.

### Activity Logs

Activity logs record subscription-level control plane operations — creating a database, scaling a tier, configuring firewall rules. They're separate from resource logs and are automatically available. Route them to Log Analytics if you need to correlate management operations with performance changes. For example, if CPU spikes right after someone scaled the database down, the activity log correlation shows the cause immediately instead of leaving you chasing phantom query regressions.

## Database Watcher (Preview)

Database watcher is a managed, agentless monitoring solution that collects data from more than 70 SQL catalog views and DMVs across your Azure SQL estate.

It targets the gap between basic platform metrics and full-blown third-party monitoring tools — giving you deep, query-level observability without installing agents or managing infrastructure.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/database-watcher-preview/database-watcher-overview.md -->

### Architecture

A **watcher** is an Azure resource you create in your subscription. You configure it with:

- A **data store**: either an Azure Data Explorer cluster or Real-Time Analytics in Microsoft Fabric
- One or more **SQL targets**: databases, elastic pools, or managed instances

The watcher connects to each target using T-SQL, collects monitoring data at periodic intervals (performance counters every 10 seconds, configuration data every 5 minutes), and streams it into the data store using streaming ingestion. Collected data typically becomes available for analysis in less than 10 seconds.

### What It Collects

Database watcher organizes data into **datasets** — each one mapping to a separate table in the data store. Dataset groups vary by target type, with 10 to 30 datasets per group. Key datasets include:

- Active sessions (from `sys.dm_exec_sessions`, `sys.dm_exec_requests`, and related views)
- Performance counters
- Query runtime and wait statistics (from Query Store)
- Index metadata and usage statistics
- Table metadata
- Backup history
- Geo-replication status
- Storage consumption

### Dashboards

Database watcher uses Azure Workbooks to render two dashboard tiers:

- **Estate dashboards** show CPU heatmaps, top queries, and resource consumption across all monitored targets. Filter by subscription, resource group, or resource name.
- **Resource dashboards** drill into a single database, pool, or instance with tabs for performance, sessions, storage, queries, and more.

You can brush a time range on any chart to zoom in, toggle between primary and HA secondary replicas, and jump to the Azure Data Explorer web UI for ad-hoc KQL queries against the raw data.

### Limits and Pricing

| Parameter | Limit |
|---|---|
| SQL targets per watcher | 100 |
| Watchers per subscription | 20 |

For most organizations, a single watcher covers the entire estate — the 100-target limit is generous.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/database-watcher-preview/database-watcher-overview.md -->

The watcher itself and its dashboards are free. You pay for the Azure Data Explorer cluster (or Fabric capacity), optional Key Vault for SQL authentication credentials, network bandwidth if the watcher and targets are in different regions, and Azure Monitor alerts.

> **Tip:** You can use a free Azure Data Explorer cluster for evaluation when an SLA isn't required. The free trial lasts one year and can be extended automatically.

### Alert Rule Templates

Database watcher includes built-in alert rule templates for common conditions — high CPU utilization, high worker utilization, failed connectivity probes, geo-replication lag, and low data storage. Each template creates a log search alert rule that queries the data store on a schedule. Once created, you manage these like any other Azure Monitor alert: email, SMS, webhooks, Logic Apps, and more.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/database-watcher-preview/database-watcher-alerts.md -->

### Impact on Workloads

Database watcher queries are resource-governed as an internal workload in Azure SQL Database. When resource contention is present, monitoring queries are limited to a small fraction of total resources, prioritizing your application. The watcher also uses short lock timeouts and low deadlock priority, so it won't block your production queries.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/database-watcher-preview/database-watcher-data.md -->

## Query Store

Query Store is the single most important monitoring feature built into the database engine. In Azure SQL Database it's on out of the box. It captures query text, plans, and runtime/wait statistics — and persists them across restarts. This gives you the historical record that DMVs can't: what happened yesterday, last week, or last month.

### What It Captures

Query Store captures three categories of data:

1. **Query text and plans** — every distinct query and every plan the optimizer chose for it
2. **Runtime statistics** — CPU time, duration, I/O, memory grants, and execution counts per plan, bucketed into configurable time intervals (default: one hour)
3. **Wait statistics** — what your queries waited on, categorized by wait type (CPU, I/O, locking, memory grants, etc.)

### Configuring Query Store

The default configuration works for most workloads, but you should understand the knobs:

```sql
-- Set capture mode to Auto (ignores infrequent/trivial queries)
ALTER DATABASE [YourDB]
SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO);

-- Set size-based cleanup to prevent running out of space
ALTER DATABASE [YourDB]
SET QUERY_STORE (SIZE_BASED_CLEANUP_MODE = AUTO);

-- Keep 30 days of history
ALTER DATABASE [YourDB]
SET QUERY_STORE (CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30));

-- Increase max storage if you have a heavy workload
ALTER DATABASE [YourDB]
SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 1024);
```

<!-- Source: azure-sql-database-sql-db/how-to/performance/query-performance-insight-use.md -->

The three capture modes are:

- **All** — captures every query. Thorough but space-hungry.
- **Auto** — ignores infrequent queries and queries with insignificant compile/execution duration. This is the default and the right choice for most workloads.
- **None** — stops capturing new queries but continues collecting stats for already-captured ones.

> **Gotcha:** If Query Store fills up and enters read-only mode, it stops collecting new data silently. You'll see a portal warning: "Query Store is not properly configured on this database." Either increase `MAX_STORAGE_SIZE_MB` or let `SIZE_BASED_CLEANUP_MODE = AUTO` do its job.

### Reading Query Store Data

You can query the Query Store catalog views directly. Here's how to find the top 15 CPU-consuming queries over the last two hours:

```sql
WITH AggregatedCPU AS (
    SELECT q.query_hash,
           SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_ms,
           SUM(count_executions * avg_cpu_time / 1000.0)
               / SUM(count_executions) AS avg_cpu_ms,
           MAX(rs.max_cpu_time / 1000.0) AS max_cpu_ms,
           SUM(count_executions) AS total_executions,
           MIN(qt.query_sql_text) AS sampled_query_text
    FROM sys.query_store_query_text AS qt
    INNER JOIN sys.query_store_query AS q
        ON qt.query_text_id = q.query_text_id
    INNER JOIN sys.query_store_plan AS p
        ON q.query_id = p.query_id
    INNER JOIN sys.query_store_runtime_stats AS rs
        ON rs.plan_id = p.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
    GROUP BY q.query_hash
)
SELECT TOP 15 *
FROM AggregatedCPU
ORDER BY total_cpu_ms DESC;
```

The key catalog views are:

- `sys.query_store_query_text` — the SQL text
- `sys.query_store_query` — query metadata and hash
- `sys.query_store_plan` — execution plans (one query can have many)
- `sys.query_store_runtime_stats` — aggregated runtime statistics per plan
- `sys.query_store_wait_stats` — aggregated wait statistics per plan

### Forced Plans

When you know a specific plan is good and don't want the optimizer to pick a different one, you can **force** it:

```sql
EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 17;
```

This pins the plan. If the optimizer can't reproduce it (because the underlying schema changed, for example), it falls back to normal optimization — it doesn't error out. You can unforce a plan with `sp_query_store_unforce_plan`.

### Query Store as a Foundation

Query Store isn't just a standalone tool. It's the data source behind three other Azure SQL features:

- **Automatic tuning** (Chapter 15) — uses Query Store data to detect plan regressions and automatically force the last known good plan
- **Query Performance Insight** — the portal dashboard covered in the next section
- **Deadlock analysis** — Query Store data helps identify the queries and plans involved in deadlocks captured by Extended Events

## Query Performance Insight

Query Performance Insight is a portal-based dashboard that visualizes Query Store data for Azure SQL Database. It shows your top resource-consuming queries by CPU, duration, or execution count, overlaid against overall DTU/CPU utilization.

<!-- Source: azure-sql-database-sql-db/how-to/performance/query-performance-insight-use.md -->

You'll find it under **Intelligent Performance > Query Performance Insight** in the portal. The dashboard has three views:

- **Top CPU-consuming queries** (default) — bar chart of CPU per query against a DTU utilization line
- **Top queries by duration** — longest-running queries that are candidates for optimization
- **Top queries by execution count** — "chatty" queries that generate excessive round trips

Select any query to drill into its details: CPU over time, duration over time, and execution count. You can adjust the time range, number of queries displayed, and aggregation function (sum, max, average).

> **Note:** Query Performance Insight shows only the top 5–20 queries depending on your selection. If you need broader visibility, use database watcher or query the Query Store views directly.

Performance recommendation annotations from Database Advisor appear as icons on the chart. Hover to see the recommendation; click to apply it.

> **Gotcha:** Query Performance Insight doesn't capture DDL queries. Some ad-hoc queries may also be missed. For comprehensive query tracking, go to Query Store directly.

## DMV-Based Diagnostics

Dynamic management views give you the real-time, in-the-moment view of your database. They're the tool you reach for during active incidents: "What's running right now? What's waiting? What's blocked?"

<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/monitoring-with-dmvs.md -->

### sys.dm_db_resource_stats

This is your first stop for current-state resource analysis. It records CPU, data I/O, log writes, memory usage, and worker percentage every **15 seconds**, retained for approximately **one hour**.

```sql
SELECT AVG(avg_cpu_percent) AS avg_cpu,
       MAX(avg_cpu_percent) AS max_cpu,
       AVG(avg_data_io_percent) AS avg_data_io,
       MAX(avg_data_io_percent) AS max_data_io,
       AVG(avg_log_write_percent) AS avg_log_write,
       MAX(avg_log_write_percent) AS max_log_write,
       MAX(max_worker_percent) AS max_workers
FROM sys.dm_db_resource_stats;
```

### sys.resource_stats

For longer-term trending, query `sys.resource_stats` in the `master` database. It aggregates data every **5 minutes** and retains it for approximately **14 days**. This is where you answer "What did resource consumption look like last week?"

```sql
SELECT *
FROM sys.resource_stats
WHERE database_name = 'MyProductionDB'
      AND start_time > DATEADD(day, -7, GETDATE())
ORDER BY start_time DESC;
```

> **Note:** You must connect to the `master` database to query `sys.resource_stats`.

### Concurrent Requests, Sessions, and Workers

A quick snapshot of current concurrency:

```sql
-- Active requests right now
SELECT COUNT(*) AS concurrent_requests
FROM sys.dm_exec_requests;

-- Active user sessions
SELECT COUNT(*) AS active_sessions
FROM sys.dm_exec_sessions
WHERE is_user_process = 1;
```

For historical concurrency data, `sys.dm_resource_governor_workload_groups_history_ex` provides snapshots of active requests, workers, and sessions over time:

```sql
SELECT rg.database_name,
       wg.snapshot_time,
       wg.active_request_count,
       wg.active_worker_count,
       wg.active_session_count
FROM sys.dm_resource_governor_workload_groups_history_ex AS wg
INNER JOIN sys.dm_user_db_resource_governance AS rg
    ON wg.name = CONCAT('UserPrimaryGroup.DBId', rg.database_id)
ORDER BY snapshot_time DESC;
```

### CPU, I/O, and Tempdb Diagnostics

When CPU is high, you need to know which queries are consuming it *right now*:

```sql
SELECT TOP 10
    req.session_id,
    req.start_time,
    req.cpu_time AS cpu_time_ms,
    SUBSTRING(ST.text, (req.statement_start_offset / 2) + 1, 256) AS statement_text
FROM sys.dm_exec_requests AS req
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST
ORDER BY req.cpu_time DESC;
```

For I/O issues, check the current data and log utilization from `sys.dm_db_resource_stats`, then correlate with wait types. The key I/O waits are `PAGEIOLATCH_*` (data file I/O) and `WRITELOG` (transaction log I/O).

For tempdb contention, look for `PAGELATCH_*` waits (without the "IO") where the `wait_resource` starts with `2:` — database ID 2 is `tempdb`.

### Memory Grants, Blocking, and Long-Running Transactions

When queries can't get the memory they need to start executing, they wait on `RESOURCE_SEMAPHORE`. Check if it's a top wait:

```sql
SELECT wait_type,
       SUM(wait_time) AS total_wait_time_ms
FROM sys.dm_exec_requests AS req
INNER JOIN sys.dm_exec_sessions AS sess
    ON req.session_id = sess.session_id
WHERE is_user_process = 1
GROUP BY wait_type
ORDER BY SUM(wait_time) DESC;
```

For blocking chains, `sys.dm_exec_requests` shows the `blocking_session_id`. For long-running transactions that prevent version store cleanup (important with accelerated database recovery), join `sys.dm_tran_active_transactions` with `sys.dm_tran_database_transactions` and `sys.dm_tran_session_transactions`.

### Elastic Pool Resource Stats

Two pool-specific views round out the DMV picture:

- `sys.dm_elastic_pool_resource_stats` — granular, recent data (like `sys.dm_db_resource_stats` but at the pool level). Query it from any database in the pool.
- `sys.elastic_pool_resource_stats` — historical data in `master`, retained for 14 days (like `sys.resource_stats`).

<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/monitoring-with-dmvs.md -->

## Extended Events

Extended Events (XEvents) is SQL Server's lightweight event tracing framework, and it works in Azure SQL Database and Managed Instance with a few important differences from on-premises SQL Server.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/extended-events/xevent-db-diff-from-svr.md -->

### Key Differences in Azure SQL

- In **Azure SQL Database**, event sessions are always **database-scoped**. You use `ON DATABASE` instead of `ON SERVER`. One database can't collect events from another.
- In **Azure SQL Managed Instance**, you can create both server-scoped and database-scoped sessions. Server-scoped is recommended for most scenarios.
- The `event_file` target always writes to **Azure Blob Storage** — there's no local disk option.

### Ring Buffer Target

The ring buffer is perfect for ad-hoc troubleshooting — quick, in-memory, no storage setup required. Here's a minimal session that captures batch starts:

```sql
CREATE EVENT SESSION [quick_trace] ON DATABASE
ADD EVENT sqlserver.sql_batch_starting
ADD TARGET package0.ring_buffer(SET max_memory = (1024))
WITH (STARTUP_STATE = OFF);
GO

ALTER EVENT SESSION [quick_trace] ON DATABASE STATE = START;
```

Read the buffer with:

```sql
SELECT name AS session_name,
       total_buffer_size + total_target_memory AS total_session_memory
FROM sys.dm_xe_database_sessions;
```

> **Tip:** Keep ring buffer memory at 1 MB or less and the event count low (default 1,000). The ring buffer discards older events when full — it's a sliding window, not a persistent store.

### Event File Target with Azure Blob Storage

For persistent capture, use the `event_file` target. This requires an Azure Storage container and a credential. The recommended approach is to use managed identity:

1. Assign the **Storage Blob Data Contributor** RBAC role to your server's managed identity on the storage container.
2. Create a database-scoped credential (SQL Database) or server-scoped credential (Managed Instance) with `IDENTITY = 'MANAGED IDENTITY'`.
3. Create the event session pointing to the blob container URL.

You can also use a SAS token instead of managed identity if Microsoft Entra authentication isn't configured.

> **Important:** Use a storage account in the same region as your database. Match the redundancy (LRS/ZRS) to your database's availability configuration. Don't use Cool or Archive tiers. Don't enable hierarchical namespace (Data Lake Storage).

### Resource Governance for Extended Events

Azure SQL Database limits extended event session memory:

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/extended-events/xevent-db-diff-from-svr.md -->

| Scope | Memory Limit |
|---|---|
| Single database | 128 MB total |
| Elastic pool | 512 MB total across all databases |

If you exceed the memory limit, the `CREATE EVENT SESSION` or `ALTER EVENT SESSION` statement fails with an error — so you'll know immediately, not at runtime.

The maximum number of started sessions is **100 per database** (or 100 database-scoped sessions per elastic pool).

> **Warning:** In Azure SQL Database, don't read deadlock events from the built-in `dl` event session using `sys.fn_xe_file_target_read_file()`. With large numbers of deadlock events, this can cause out-of-memory errors in the `master` database and affect login processing.

For continuously running sessions that should survive failovers and maintenance events, set `STARTUP_STATE = ON`. For ad-hoc troubleshooting sessions, leave it `OFF`.

## Alerting

Azure Monitor supports three types of alerts relevant to Azure SQL:

- **Metric alerts** — trigger when a metric crosses a threshold. Example: CPU percentage > 80% sustained for 5 minutes. You can use static thresholds or dynamic thresholds (machine-learning-based baselines).
- **Activity log alerts** — trigger on control plane events. Example: a database was scaled or a failover group failed over.
- **Resource health alerts** — trigger when the resource health status changes.

<!-- Source: azure-sql-database-sql-db/how-to/performance/alerts-create.md -->

For alert actions, you can send email, SMS, voice calls, push notifications, call webhooks, run Azure Functions, trigger Logic Apps, create ITSM tickets, or start automation runbooks.

> **Tip:** Start with these four metric alerts on every production database: CPU percentage > 80%, Workers percentage > 70%, Data space used percent > 85%, and Availability < 100%. These cover the most common "I wish I'd known sooner" scenarios.

You can scope alert rules to an individual database or broaden them to all databases in a resource group, on a logical server, or across a subscription. Broad scoping reduces alert sprawl significantly.

## Azure Resource Health

Resource Health tells you whether your Azure SQL resource is up or having issues. It's not a performance tool — it's a connectivity health check, updated every 1–2 minutes based on login success and failure patterns.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/resource-health-to-troubleshoot-connectivity.md -->

The four states are:

| State | Meaning |
|---|---|
| **Available** | No system login failures detected |
| **Degraded** | Majority of logins succeed, but some fail (likely transient) |
| **Unavailable** | Consistent login failures — contact support if sustained |
| **Unknown** | No health data for 10+ minutes |

Resource Health tracks **system errors only** — user errors (wrong password, firewall blocks) don't affect the health status.

The **Health history** section shows up to 30 days of history with downtime reasons when available. Common reasons include planned maintenance, reconfiguration events, and hardware failures. Downtime granularity is two minutes, though actual downtime is typically under a minute (average: 8 seconds).

> **Tip:** Pair Resource Health alerts with your retry logic. If your app properly retries on transient errors (as it should — see Chapter 4), most Degraded states will be invisible to your users.

## Monitoring Managed Instance

Managed Instance shares the same Azure Monitor and Query Store capabilities as SQL Database, but its fuller SQL Server surface area gives you additional monitoring options.

### Instance-Level Metrics and Resource Logs

Managed Instance exposes similar platform metrics to SQL Database — CPU percentage, I/O, storage, sessions — but at the instance level rather than the database level. Diagnostic settings stream the same resource log categories: Query Store runtime/wait statistics, errors, and SQL Insights.

### Backup Monitoring

Since Managed Instance exposes `msdb`, you can query backup history directly — something SQL Database doesn't allow:

```sql
SELECT TOP 20
    DB_NAME(DB_ID(bs.database_name)) AS database_name,
    CONVERT(BIGINT, bs.backup_size / 1048576) AS uncompressed_mb,
    CONVERT(BIGINT, bs.compressed_backup_size / 1048576) AS compressed_mb,
    DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS duration_sec,
    bs.backup_finish_date
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS bmf
    ON bs.media_set_id = bmf.media_set_id
WHERE bs.[type] = 'D'
ORDER BY bs.backup_finish_date DESC;
```

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/backup-restore/backup-activity-monitor.md -->

You can also track backup progress in real time with Extended Events. The `backup_restore_progress_trace` event captures start/finish times, backup type, bytes processed, and completion percentage. Use a ring buffer for quick checks or write to an event file in Azure Blob Storage for a persistent audit trail.

```sql
CREATE EVENT SESSION [Basic backup trace] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace (
    WHERE operation_type = 0
    AND trace_message LIKE '%100 percent%'
)
ADD TARGET package0.ring_buffer
WITH (STARTUP_STATE = ON);
GO

ALTER EVENT SESSION [Basic backup trace] ON SERVER STATE = START;
```

## Monitoring SQL Server on Azure VMs

SQL Server on Azure VMs gives you full control — and full responsibility for monitoring. Two portal features help bridge the gap between Azure infrastructure metrics and SQL Server diagnostics.

### SQL Best Practices Assessment

The **SQL best practices assessment** feature scans your SQL Server instance and databases against a rich ruleset provided by the SQL Assessment API. It checks configuration, indexes, deprecated features, trace flags, and more. Results upload to a Log Analytics workspace via Azure Monitor Agent.

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/optimize-performance/sql-assessment-for-sql-vm.md -->

Prerequisites are minimal: register the VM with the SQL Server IaaS extension, point to a Log Analytics workspace, and run SQL Server 2012 or later. You can schedule assessments weekly or monthly, or run them on demand. Expect 5–10% CPU impact during the assessment run.

### I/O Performance Analysis

The **Storage** pane on the SQL virtual machines resource in the portal provides I/O throttling detection. It monitors six Azure VM and disk metrics for sustained periods at 95%+ utilization alongside disk latency exceeding 500 ms over consecutive 5-minute windows.

The analysis distinguishes between:

- **VM-level throttling** — the VM size's IOPS or bandwidth ceiling has been reached. Remedy: resize the VM.
- **Disk-level throttling** — individual data disk IOPS or bandwidth limits hit. Remedy: adjust the storage pool configuration or use higher-performance disks.

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/optimize-performance/storage-performance-analysis.md -->

All six metrics share the same throttling threshold: **≥ 95% sustained utilization**. The metrics are:

- VM Cached IOPS Consumed %
- VM Cached Bandwidth Consumed %
- VM Uncached IOPS Consumed %
- VM Uncached Bandwidth Consumed %
- Data Disk IOPS Consumed %
- Data Disk Bandwidth Consumed %

> **Tip:** I/O throttling at the VM level is relatively easy to fix — resize the VM. Disk-level throttling is harder because modifying storage pools after deployment is more disruptive. Get the storage configuration right during initial provisioning.

In Chapter 15, you'll put these tools to work — using the data they collect to identify performance bottlenecks and tune your way out of them.
