# Chapter 25: Day-to-Day Administration

You've designed your schema, tuned your queries, and set up monitoring. Now you need to keep everything running. This chapter covers the routine admin tasks across all three Azure SQL deployment options — the knobs you'll actually turn week to week.

Each deployment option has its own operational surface. SQL Database gives you the least to manage (and the fewest knobs). Managed Instance layers on SQL Server compatibility and the management operations that come with it. SQL Server on Azure VMs hands you the full engine — and full responsibility. We'll walk through each in turn.

## SQL Database Administration

### Creating, Scaling, and Configuring Single Databases

Creating a single database is straightforward: pick a logical server, choose a service tier and compute size, and go. You can do it through the Azure portal, PowerShell (`New-AzSqlDatabase`), Azure CLI (`az sql db create`), T-SQL (`CREATE DATABASE` against the `master` database), or the REST API.

Scaling is where things get interesting. You can scale a database up or down dynamically without downtime — the service creates a new compute instance, copies your data if needed, then switches connections over. That switch causes a brief interruption, typically under 30 seconds. Long-running transactions at the moment of switchover get aborted, so make sure your applications have retry logic in place.
<!-- Source: azure-sql-database-sql-db/how-to/manage/single-database-scale.md -->

The latency of a scaling operation depends on what you're changing:

| From → To | Latency |
|---|---|
| Within GP or Standard | Constant, ~5 min |
| GP → BC (or reverse) | ~1 min/GB used |
| Any → Hyperscale | ~1 min/GB used |
| Within Hyperscale | Constant, ~2 min |

> **Tip:** You can monitor and cancel in-progress scaling operations. Use `Get-AzSqlDatabaseActivity` in PowerShell, `az sql db op list` in the CLI, or the `sys.dm_operation_status` DMV in T-SQL.

> **Gotcha:** When you scale down, the pool or database used space must fit within the target tier's max data size. If it doesn't, the operation fails. Shrink your data files first if needed.

### Elastic Pool Lifecycle

Elastic pools let you share compute across multiple databases. The lifecycle is: create the pool, add databases, monitor utilization, resize as needed, and move databases between pools or out to standalone.

All pool settings live in a single **Configure pool** pane in the portal. From there you can change the service tier, scale DTUs or vCores, adjust storage, set per-database min/max resource limits, and add or remove databases — all in one batch.
<!-- Source: azure-sql-database-sql-db/how-to/manage/elastic-pool-manage.md -->

Moving databases between pools is a common operation. You have several options:

- **PowerShell:** `Set-AzSqlDatabase` with the `-ElasticPoolName` parameter
- **T-SQL:** `ALTER DATABASE ... MODIFY (SERVICE_OBJECTIVE = ELASTIC_POOL(name = ...))`
- **Portal:** drag-and-drop in the Configure pool pane

Latency depends on whether the pool uses Premium File Share (PFS) storage — if it does, moves are proportional to database size.

> **Important:** You can't create, update, or delete an elastic pool using T-SQL. You can only add or remove databases from a pool using `ALTER DATABASE`.

### Dense Elastic Pools and Noisy-Neighbor Mitigation

A **dense** elastic pool packs many databases into a single pool with moderate compute — the whole point of cost optimization. But when too many databases get active at once, you get resource contention. The "noisy neighbor" problem.
<!-- Source: azure-sql-database-sql-db/how-to/manage/elastic-pool-resource-management.md -->

Monitor these metrics to catch contention early:

| Metric | Target |
|---|---|
| `avg_instance_cpu_percent` | Below 70% |
| `max_worker_percent` | Below 80% |
| `avg_data_io_percent` | Below 80% |
| `avg_log_write_percent` | Below 90% |
| `oom_per_second` | 0 |
| `tempdb_log_used_percent` | Below 50% |

When contention hits, you have three levers:

1. **Tune the workload** — reduce resource consumption per query, spread work over time.
2. **Reduce density** — move databases to another pool or make them standalone.
3. **Scale up** — give the pool more compute.

> **Gotcha:** Don't move "hot" databases out of a contended pool while they're under heavy load. The move operation itself consumes resources and makes things worse. Wait for load to subside, or move *less*-utilized databases out first to relieve pressure.

#### Finding the Noisy Neighbor

Pool-level metrics tell you *that* contention exists, but not *which* database is causing it. To find the culprit, query `sys.dm_db_resource_stats` in each database — or, more practically, query `sys.resource_stats` from the `master` database, which tracks all databases on the server:

```sql
SELECT database_name, end_time,
       avg_cpu_percent, avg_data_io_percent,
       avg_log_write_percent
FROM sys.resource_stats
WHERE start_time > DATEADD(mi, -30, SYSUTCDATETIME())
ORDER BY avg_cpu_percent DESC;
```

The database with the highest sustained resource usage is your noisy neighbor.

#### Per-Database Resource Governance

You can also constrain individual databases using the pool's per-database min/max settings. Setting a non-zero **min vCores** (or min DTUs) guarantees a baseline for each database — but it implicitly limits how many databases fit in the pool, because the sum of minimums can't exceed the pool's total. Setting a **max vCores** cap prevents any single database from monopolizing the pool.

To see the effective governance settings for a database in the pool, query `sys.dm_user_db_resource_governance`:

```sql
SELECT * FROM sys.dm_user_db_resource_governance
WHERE database_id = DB_ID();
```
<!-- Source: azure-sql-database-sql-db/how-to/manage/elastic-pool-resource-management.md -->

> **Tip:** For tenant-per-database patterns where you add databases frequently, consider a **quarantine pool** — a separate pool with ample headroom where new databases land first. Once you know a database's resource pattern (a week or a month of data), move it to the appropriate production pool. This prevents unknown workloads from surprising your existing tenants.

> **Tip:** Add the `##MS_ServerStateReader##` server role to your monitoring principal so it can query the resource governance DMVs (`sys.dm_resource_governor_resource_pools_history_ex`, `sys.dm_user_db_resource_governance`, etc.).

### File Space Management

Azure SQL Database data files grow automatically but never shrink on their own. After large deletes or data migrations, you can end up with significant allocated-but-unused space. This matters because you're billed on allocated space for elastic pools, and the allocated total counts against the pool's max size.
<!-- Source: azure-sql-database-sql-db/how-to/manage/file-space-manage.md -->

To check allocated vs. used space in a single database:

```sql
SELECT file_id, type_desc,
       CAST(FILEPROPERTY(name, 'SpaceUsed') AS decimal(19,4)) * 8 / 1024. AS space_used_mb,
       CAST(size/128.0 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0 
            AS decimal(19,4)) AS space_unused_mb,
       CAST(size AS decimal(19,4)) * 8 / 1024. AS space_allocated_mb
FROM sys.database_files;
```

If you need to reclaim space, use `DBCC SHRINKFILE` or `DBCC SHRINKDATABASE`. But treat shrinking as an exception, not routine maintenance — it causes index fragmentation and the files will just grow again if the workload hasn't changed.

> **Warning:** Shrinking data files fragments your indexes. If you shrink, plan to rebuild indexes afterward. Don't shrink as a scheduled task.

### Database Restart

Sometimes a database just needs a fresh start — a connection pool fills up with stale connections, or a transient issue lingers. Azure SQL Database offers a restart feature (currently in preview) that triggers a failover of your database or elastic pool.
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/restart-database.md -->

You'll find it under **Settings → Maintenance** in the portal. The restart briefly takes the database offline, then brings it back. Only one failover call is allowed every 15 minutes per database or pool.

> **Important:** Restarting an elastic pool restarts *all* databases in the pool. Before triggering a restart, check Azure Service Health — if there's a widespread service issue, a restart won't help.

### Quota Management

Azure SQL Database enforces per-subscription quotas on vCores (regardless of whether you use DTU or vCore purchasing). If you hit the limit, new deployments fail.

To request an increase, open a support request with the **Service and subscription limits (quotas)** issue type. Choose the **SQL Database** quota type and select **vCores per subscription**. If you use DTUs, convert to vCores using the rough formula: 1 vCore ≈ 100–125 DTU.
<!-- Source: resources/troubleshoot/quota-increase-request.md -->

You can also request **Region access** (to deploy in a region your subscription doesn't have access to) or **Zone Redundant Access** (to enable availability zones in a specific region).

> **Tip:** Build quota checks into your capacity planning. Before provisioning a batch of new databases, verify your subscription has headroom. A quota increase request goes through Azure support and isn't instant.

## Managed Instance Administration

Managed Instance administration is a different beast. Unlike SQL Database, where most operations complete in seconds, Managed Instance operations involve infrastructure changes — creating or resizing VM groups, seeding databases, and performing failovers. Understanding these operations is key to planning your maintenance windows.

### Management Operations: Create, Update, Delete

Every Managed Instance lifecycle event — create, update, delete — triggers a **management operation** on the backend. These operations follow a predictable pattern:

1. **Validate** the request parameters.
2. **Create or resize the VM group** (the infrastructure that hosts your instance).
3. **Seed databases** (copy data to new compute, if required).
4. **Fail over** traffic to the new SQL Database Engine process.
5. **Clean up** old resources.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-overview.md -->

Your instance stays available through all of this except the final failover — up to 2 minutes in General Purpose, up to 20 seconds in Business Critical. On the **Next-gen General Purpose** tier (which supports up to 500 databases per instance), failover duration scales with the number of databases and can reach up to 10 minutes — the instance itself comes online after about 2 minutes, but individual databases may lag behind.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-overview.md -->

Here are the durations you should plan for:

| Operation (General Purpose) | Duration |
|---|---|
| Create new instance | 95% finish in 30 min |
| Scale storage | 99% finish in 5 min |
| Scale vCores | 95% finish in 60 min |
| Change to Business Critical | 60 min + seeding time |
| Delete (non-last instance) | 95% finish in 1 min |
| Delete (last in subnet) | 95% finish in 90 min |

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-duration.md -->

Business Critical operations take longer because storage scaling, vCore scaling, and hardware or maintenance-window changes all require seeding data to local storage across all 4 replicas. Seeding speed averages about 220 GB per hour per database. The platform seeds up to 8 databases concurrently — as one finishes, the next available database takes its channel.

> **Gotcha:** Don't scale compute or storage while long-running transactions (imports, index rebuilds) are active. The failover at the end of the operation cancels all ongoing transactions.

> **Important:** Management operations in the same subnet can block each other. A long-running restore holds up create and scale operations. Operations submitted within a 1-minute window get batched and run in parallel, but anything arriving later waits for the VM group resize to finish.

### Operation Cancellation and Monitoring

You can cancel most in-progress operations — instance creation, vCore scaling, and service tier changes all support cancellation. Storage scaling in General Purpose and instance deletion are *not* cancelable.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-cancel.md -->

| Operation | Cancelable? |
|---|---|
| Instance creation | Yes |
| vCore scaling (GP/BC) | Yes |
| Storage scaling (GP) | No |
| Storage scaling (BC) | Yes |
| Service tier change | Yes |
| Instance deletion | No |

When you cancel, 90% of cancellations complete in 5 minutes. A canceled creation leaves the instance in a **FailedToCreate** state — it won't be charged and doesn't count toward quotas, but you should delete the resource to keep your portal clean.

Monitor operation progress in the portal (the **Notification** box on the Overview pane), with PowerShell (`Get-AzSqlInstanceOperation`), or with the CLI (`az sql mi op list`).

### Instance Stop/Start for Cost Savings

If you have General Purpose instances that sit idle — dev/test environments, batch processing that runs on a schedule — you can stop them. A stopped instance doesn't bill for compute or licensing. You still pay for data and backup storage.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/instance-stop-start-how-to.md -->

Stopping takes about 5 minutes. Starting takes about 20 minutes. You can trigger stop/start manually or set up a schedule — for example, start every weekday at 7:40 AM so the instance is ready by 8:00 AM, stop at 5 PM.

Schedule rules to know:

- Each scheduled item needs both a stop and start time — you can't schedule one without the other.
- At least 1 hour must separate successive actions.
- If a conflicting operation (like a vCore scale) is running when a scheduled stop fires, it retries after 10 minutes, then skips if still blocked.
- Billing is per started hour — stop at 12:01 and you still pay for that hour.

> **Important:** Azure can start a stopped instance for urgent maintenance (compliance patches, security fixes). You'll be billed for compute while it's online. Azure stops the instance again when maintenance completes.

### Database Copy and Move Across Instances

Managed Instance supports online database copy and move operations between instances — even across subscriptions within the same tenant. Under the hood, it uses Always On availability group technology to replicate data asynchronously.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/database-copy-move-how-to.md -->

The workflow:

1. Start the copy or move operation. The database is seeded to the destination instance.
2. When seeding finishes, the operation enters a **ready for completion** state. All ongoing changes continue replicating.
3. You manually complete the operation within 24 hours — after that, it auto-cancels.
4. **Copy** leaves the source online. **Move** drops the source after completion.

A move guarantees no data loss: the source stops accepting workloads before the final transaction log is replicated, the destination comes online, and only then is the source dropped.

> **Gotcha:** When you move a database, existing point-in-time restore (PITR) backups don't transfer. A new backup chain starts on the destination. Plan accordingly if you need historical restore points.

Prerequisites include network connectivity between the source and destination VNets (if different), with ports 5022 and 11000–11999 open in both directions.

### File Space Management

File space management in Managed Instance follows the same principles as SQL Database — allocated space grows automatically but doesn't shrink. The same `sys.database_files` query works here. Use `DBCC SHRINKFILE` to reclaim unused space from data files or transaction log files when needed.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/file-space-manage.md -->

For transaction log monitoring, use `sys.dm_db_log_space_usage` to check current usage. If the log is full, investigate what's preventing truncation before reaching for `DBCC SHRINKFILE`.

### Update Policy

The update policy controls which SQL engine features your Managed Instance can access. There are three options:
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

| Policy | Internal Format |
|---|---|
| SQL Server 2022 | Aligned with 2022 |
| SQL Server 2025 | Aligned with 2025 |
| Always-up-to-date | Evolves continuously |

**SQL Server 2022** gives you restore compatibility with SQL Server 2022 and MI Link with bidirectional failover. **SQL Server 2025** adds vectors, the JSON type, regex, and optimized locking — with restore compatibility to SQL Server 2025. **Always-up-to-date** gives you the latest features immediately, but sacrifices on-premises restore compatibility.

**SQL Server 2022** is the default for all instances. You can upgrade to SQL Server 2025 or Always-up-to-date, but the internal database format is permanently upgraded — choose carefully.

> **Warning:** Switching from SQL Server 2022 to SQL Server 2025 or Always-up-to-date is a one-way door. Backups from an upgraded instance can only be restored to instances at the same policy level or higher. Test in a non-production environment first.

> **Note:** Changing from **SQL Server 2025** to **Always-up-to-date** is currently and temporarily disabled. If you're planning a staged upgrade (2022 → 2025 → Always-up-to-date), be aware this path is blocked for now.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

The choice matters most for hybrid scenarios. If you need the MI Link with bidirectional failover to SQL Server 2022, stay on that policy.

You can check the current policy with T-SQL:

```sql
SELECT SERVERPROPERTY('ProductUpdateType');
-- 'CU' = SQL Server 2022 or 2025 policy
-- 'Continuous' = Always-up-to-date policy
```

### Time Zone Selection

Managed Instance lets you set a time zone at creation. This affects `GETDATE()`, `SYSDATETIME()`, CLR code, and SQL Agent job schedules. The default is UTC.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-settings/timezones-overview.md -->

> **Important:** You can't change the time zone after creation. Choose carefully. If you're migrating from on-premises, match your original time zone unless you're reimplementing the application logic.

For new cloud-native workloads, stick with UTC — it eliminates daylight saving time ambiguity. Use `AT TIME ZONE` in your queries to convert for display.

You can query the supported time zones with `sys.time_zone_info` and check the current instance time zone with `SELECT CURRENT_TIMEZONE()`.

### Tempdb Tuning

Managed Instance lets you configure `tempdb` — the number of data files, growth increments, and maximum size. These settings persist across restarts and failovers.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-settings/tempdb-configure.md -->

By default, Managed Instance creates 12 `tempdb` data files. You can go up to 128 files max. More files reduce PFS page contention when tempdb is under heavy concurrent use. If you see `PAGELATCH_*` waits on PFS, GAM, or SGAM pages in your wait stats, that's the signal to add more files — each additional data file gets its own allocation pages, spreading the contention.

Add a file with T-SQL:

```sql
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdb_data_13');
```

Check the current file count:

```sql
USE tempdb;
SELECT COUNT(*) AS TempDBFiles FROM sys.database_files WHERE type = 0;
```

> **Tip:** You don't need to restart the instance after adding files. But be aware that new files fill with higher priority initially — the round-robin allocation rebalances over time.

## SQL Server VM Administration

With SQL Server on Azure VMs, you get full control — and full responsibility. The **SQL virtual machines** resource in the Azure portal is your central management point, providing a layer of Azure-aware tooling on top of the standard SQL Server engine.

### Portal-Based Management via the SQL VM Resource

The SQL virtual machines resource is separate from the underlying Virtual machine resource. The VM resource manages the infrastructure (start, stop, resize the VM). The SQL virtual machines resource manages SQL Server settings — licensing, storage, patching, backups, and security.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/manage/manage-sql-vm-portal.md -->

To access it, search for "SQL virtual machines" in the Azure portal. The Overview page shows extension health status, license type, SQL best practices assessment notifications, and storage utilization metrics.

> **Prerequisite:** The SQL virtual machines resource only appears for VMs registered with the SQL Server IaaS Agent extension. If you deployed from a Marketplace image, the extension is installed by default. If you installed SQL Server manually, register the VM yourself.

### License Model Switching

You can switch between three license models directly from the portal's **Configure** page:

- **Pay-as-you-go (PAYG):** SQL Server licensing included in the per-hour VM cost.
- **Azure Hybrid Benefit (AHB):** Bring your own SQL Server license with Software Assurance.
- **HA/DR:** Free Azure replica for disaster recovery.

You can also change the SQL Server edition metadata (Enterprise, Standard, Developer) from the same page. This only updates Azure billing metadata — you must first change the actual edition internally using SQL Server setup media.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/manage/change-sql-server-edition.md -->

> **Gotcha:** Changing license metadata in the portal doesn't actually change the SQL Server edition on the VM. You must run the SQL Server installer first, then update the portal to match. Mismatched metadata means incorrect billing.

### In-Place Edition and Version Changes

You can upgrade SQL Server editions in place — run `Setup.exe`, choose **Edition Upgrade**, and point to your new product key. Downgrading requires a full uninstall and reinstall.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/manage/change-sql-server-edition.md, sql-server-on-azure-vms/windows/how-to-guides/manage/change-sql-server-version.md -->

For version upgrades (e.g., SQL Server 2019 → 2022), run an in-place upgrade through the installer. Before upgrading:

1. Back up all databases, including system databases.
2. Check compatibility certification for the target version.
3. Delete the SQL IaaS Agent extension first — you'll re-register after the upgrade.

> **Warning:** Both edition and version changes restart the SQL Server service and all associated services. Plan for a maintenance window.

### Servicing and Patching

You have two patching options for SQL Server on Azure VMs:

**Azure Update Manager** is the recommended approach. It installs Cumulative Updates (CUs) for SQL Server, not just Critical/Important patches. You get on-demand updates, scheduled maintenance windows, periodic assessments every 24 hours, and multi-VM management at scale.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/patching/azure-update-manager-sql-vm.md -->

**Automated Patching** is the legacy option (retiring September 2027). It only installs patches marked Critical or Important — no CUs. It establishes a maintenance window and installs during that window.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/patching/automated-patching.md -->

> **Gotcha:** Don't enable both Azure Update Manager and Automated Patching at the same time. Overlapping tools cause scheduling conflicts and unexpected patching outside your maintenance windows.

For Always On availability group VMs in different availability zones, stagger your patch schedules so replicas in different zones aren't patched simultaneously.

### Storage Migration to Ultra Disk

If your transaction log needs higher throughput and lower latency than Premium SSD can deliver, you can migrate your log disk to Ultra Disk. The process is manual but straightforward:
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/migrate/storage-migrate-to-ultradisk.md -->

1. Take a full backup.
2. Stop/deallocate the VM and enable Ultra Disk compatibility in **Disks → Additional settings**.
3. Attach the new Ultra Disk and restart the VM.
4. Format the disk, create your log folder, and grant the SQL Server service account full control.
5. Detach the database, move the log files to the new drive, and reattach.

> **Important:** Ultra Disk is supported on a subset of VM sizes and regions. Verify compatibility before you start. You must stop the VM to enable Ultra Disk support — plan for downtime.

### Cross-Region VM Migration via Azure Site Recovery

To move a SQL Server VM to another Azure region, use Azure Site Recovery (ASR). The process follows these phases:
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/migrate/move-sql-vm-different-region.md -->

1. **Prepare** — ensure root certificates are current, pre-create target networking resources.
2. **Configure** — add the VM as a replicated object in an ASR vault.
3. **Test** — run a test failover to validate the move.
4. **Move** — perform the actual failover from source to target region.
5. **Clean up** — remove the source VM, vault resources, and re-register the SQL IaaS Agent extension in the target region.

> **Gotcha:** The SQL virtual machines resource doesn't move with the VM. You must re-register the SQL IaaS Agent extension in the target region after the migration. Make sure the target subscription is registered with the SQL VM resource provider before attempting registration.

The same ASR-based approach works for migrating between subscriptions or tenants — just be sure to handle resource provider registration and extension reinstallation.

---

Administration looks different across the three deployment options, but the pattern is the same: understand what you can change, how long it takes, and what breaks during the operation. SQL Database gives you the simplest operational surface. Managed Instance adds infrastructure-level operations with longer durations and cross-impact between instances. SQL Server on Azure VMs gives you everything — and expects you to manage it. In Chapter 26, we'll look at the cost side of the equation: understanding your bill and optimizing what you spend.
