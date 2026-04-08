# Chapter 11: Backups and Restore

You never think about backups until you need a restore. And when you need one, you need it *now* — not in a few hours, not after a planning meeting. The good news: Azure SQL handles the heavy lifting automatically. The nuance is understanding what's actually happening behind the scenes, what you can tune, and what your restore options look like when something goes wrong.

## Automated Backups

Every database in Azure SQL Database and Managed Instance gets automatic backups with zero configuration. The service handles scheduling, storage, and retention. You don't manage backup agents, cron jobs, or storage accounts — the platform does it all.

### Backup Frequency

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/automated-backups-overview.md -->

Azure SQL Database creates three types of backups on a rolling schedule:

- **Full backups** run once per week.
- **Differential backups** run every 12 or 24 hours.
- **Transaction log backups** run approximately every 10 minutes, depending on compute size and activity level.

The exact timing is managed by the service. You can't customize the schedule or disable individual backup types. The first full backup runs immediately after you create or restore a database, and it typically completes within 30 minutes — though large databases or database copies can take longer.

> **Important:** Point-in-time restore becomes available only after the first transaction log backup completes following the initial full backup.

The differential backup frequency is configurable. In the vCore model, the default is every 12 hours. In the DTU model, the default is every 24 hours.

> **Note:** A 24-hour differential frequency can significantly increase restore times compared to the 12-hour default, since the service must replay more transaction log to reach the target point in time. If restore speed matters for your SLA, switch DTU databases to 12-hour differentials.

Managed Instance follows the same general pattern: weekly fulls, regular differentials, and frequent log backups. The exact cadence is managed by the platform.

### Storage Redundancy Options

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/automated-backups-overview.md -->

Backup storage redundancy determines how many copies of your backups exist and where they're stored. You choose from four options:

| Option | Copies | Geography |
|--------|--------|-----------|
| LRS | 3 in one location | Single region |
| ZRS | 3 across AZs | Single region |
| GRS | 3 local + 3 paired | Two regions |
| GZRS | 3 across AZs + 3 paired | Two regions |

**GRS** is the default for new databases. It replicates backups to the paired Azure region asynchronously, enabling geo-restore if your primary region goes down.

**GZRS** gives you the best of both worlds: zone redundancy within your primary region and a copy in the paired region. Microsoft recommends this for applications requiring maximum durability.

**LRS** and **ZRS** keep your data within a single region. Choose these when data residency requirements prohibit cross-region replication, or for dev/test environments where geo-restore isn't needed.

> **Warning:** Geo-restore is disabled the moment you switch a database to LRS or ZRS. You can change redundancy settings on an existing database, but the change applies only to future backups and can take up to 48 hours.

You can enforce redundancy choices organization-wide using Azure Policy. For example, the built-in policy "Azure SQL DB should avoid using GRS backup" prevents anyone from creating databases with geo-redundant storage.

> **Gotcha:** Azure Policy doesn't apply when databases are created via T-SQL. If your team uses T-SQL to create databases, you'll need to specify the `BACKUP_STORAGE_REDUNDANCY` parameter explicitly.

### Short-Term Retention

Short-term retention controls how far back you can do a point-in-time restore. The default is **7 days**, and you can configure it between **1 and 35 days** for most tiers. Basic-tier databases are limited to 1–7 days.

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/automated-backups-overview.md -->

When you increase the retention period, the new window doesn't take effect immediately — the system needs time to accumulate backups that cover the longer period. When you decrease it, you lose the ability to restore to points older than the new setting immediately.

> **Tip:** If you delete a database, the service retains its PITR backups for the configured retention period — you can still restore it. For what happens when you delete the *server*, see the LTR section and "Deleted-Server Restore" later in this chapter.

### Backups on Business Critical

In the Business Critical tier, automated backups are taken from a secondary replica by default. This means backup operations don't compete with your primary workload or read-only queries on the readable secondary. If a backup fails on the secondary, the service falls back to the primary.

### How SQL Database, Managed Instance, and VMs Differ

The automation story is consistent across SQL Database and Managed Instance, but SQL Server on Azure VMs is a different world:

**SQL Database and Managed Instance:**

- Fully managed automatic backups — no agents, no schedule to configure
- Platform controls the backup schedule
- 1–35 day retention range
- Backup storage is Microsoft-managed and not directly accessible
- Restore through Azure only (Managed Instance also exposes backup history via `msdb`)

**SQL Server on Azure VMs:**

- Backups run via the IaaS Agent extension or your own configuration
- Fully configurable schedule
- 1–90 day retention with Automated Backup
- Customer-managed storage account — you own the backup files
- Direct file access for backup and restore

### Backup Encryption and Integrity

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/automated-backups-overview.md -->

All databases in Azure SQL are encrypted with TDE by default, and backups inherit this encryption automatically. There's nothing to configure — your backups at rest are encrypted whether you think about it or not. Full and differential backups are always compressed regardless of TDE status.

> **Note:** For TDE-encrypted databases, transaction log backups are not compressed for performance reasons. This applies to all service tiers, not just Business Critical.

Azure SQL also runs restore validation and DBCC CHECKDB on point-in-time restores automatically. All backups are taken with the CHECKSUM option for additional integrity guarantees. Backups are stored in Microsoft-managed storage accounts that aren't accessible externally.

## Long-Term Retention (LTR)

Short-term retention maxes out at 35 days. For compliance requirements that demand months or years of backup retention, you need **long-term retention**.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/business-continuity/backup-and-recovery/long-term-retention-overview.md -->

LTR copies full backups to separate Azure Blob Storage for up to **10 years**. It's available for both SQL Database (including Hyperscale) and Managed Instance. The copy is a background job with no performance impact on your database.

### Policy Configuration

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/business-continuity/backup-and-recovery/long-term-retention-overview.md -->

LTR uses four parameters to define your retention policy:

| Parameter | Meaning |
|-----------|---------|
| **W** | Weekly backup retention |
| **M** | Monthly backup retention (first backup of each month) |
| **Y** | Yearly backup retention |
| **WeekOfYear** | Which week's backup to keep for yearly retention |

These compose naturally. Set `W=12` to keep 12 weeks of weekly backups. Set `M=12, Y=10, WeekOfYear=20` to keep monthly backups for a year plus the backup from week 20 each year for a decade.

A few things to know:

- Changes to the LTR policy apply only to *future* backups. Existing LTR backups keep their original retention settings.
- The timing of LTR backup creation is controlled by Microsoft. After you configure a policy, it can take up to **7 days** before the first LTR backup appears.
- When you first enable an LTR policy, the most recent full backup is copied to long-term storage.

> **Important:** LTR backups survive database and server deletion. If you delete a logical server, the LTR backups remain and can restore databases to a different server in the same subscription.

### Configuring LTR

<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/business-continuity/long-term-backup-retention-configure.md -->

You can configure LTR through the Azure portal, PowerShell, or the Azure CLI. In the portal, navigate to your database, open **Backups** → **Retention policies**, and set the weekly, monthly, and yearly values in the **Configure policies** pane.

With the Azure CLI, use `az sql db ltr-policy set`:

```bash
az sql db ltr-policy set \
    --resource-group myResourceGroup \
    --server myserver \
    --database mydb \
    --weekly-retention "P12W" \
    --monthly-retention "P12M" \
    --yearly-retention "P10Y" \
    --week-of-year 20
```

With PowerShell, use `Set-AzSqlDatabaseBackupLongTermRetentionPolicy`:

```powershell
Set-AzSqlDatabaseBackupLongTermRetentionPolicy `
    -ServerName "myserver" `
    -DatabaseName "mydb" `
    -ResourceGroupName "myResourceGroup" `
    -WeeklyRetention "P12W" `
    -MonthlyRetention "P12M" `
    -YearlyRetention "P10Y" `
    -WeekOfYear 20
```

Retention values use ISO 8601 durations — `P12W` means 12 weeks, `P12M` means 12 months, `P10Y` means 10 years. Set any parameter to `P0W` (or equivalent zero) to disable that tier.

### Geo-Replication and LTR

If you're using active geo-replication or failover groups, configure the same LTR policy on both primary and secondary. LTR backups are only generated from the primary. If a failover occurs, the new primary starts generating LTR backups — but only if it has a policy configured.

## Backup Immutability

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/backup-immutability/backup-immutability.md -->

For organizations bound by SEC 17a-4(f), FINRA 4511(c), or CFTC 1.31, Azure SQL Database supports **immutable LTR backups** stored in WORM (Write Once, Read Many) format. Immutability ensures backups can't be modified or deleted — not even by an administrator — for the configured retention period.

There are two modes:

**Time-based immutability** is set at the policy level. Once enabled and **locked**, all new LTR backups inherit the setting. Backups remain immutable until their retention period expires. You can enable it in an unlocked state first to test, then lock it — but once locked, it can't be reversed.

**Legal hold** is applied to individual existing backups. It's independent of time-based immutability and keeps a backup available and immutable indefinitely, until you explicitly remove the hold. This is designed for litigation and auditing scenarios.

> **Note:** Backup immutability is available only for SQL Database LTR backups. Managed Instance doesn't support immutable backups directly. As a workaround, you can take copy-only backups in Managed Instance and store them in an Azure Storage account with immutability policies.

There's no extra cost for enabling immutability. However, once locked, you can't delete backups early — storage charges continue accruing until the retention period expires, even past the LTR expiration date.

> **Gotcha:** Starting February 17, 2026, configuring immutability blocks deletion of the logical server until all immutable backups are removed. Plan accordingly if you need to decommission servers.

## Accelerated Database Recovery (ADR)

ADR isn't about backups directly — it's about what happens when the database engine needs to *recover*. Understanding ADR helps you reason about recovery times, transaction log behavior, and the impact of long-running transactions.

### How Traditional Recovery Works

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/business-continuity/backup-and-recovery/accelerated-database-recovery-concepts.md -->

The SQL Server engine uses a three-phase recovery process based on the ARIES model:

1. **Analysis:** Scan the transaction log from the last checkpoint to determine which transactions were active at the time of the crash.
2. **Redo:** Replay all committed operations from the log to bring the database back to its crash-time state.
3. **Undo:** Roll back all transactions that were active but not committed at crash time.

The problem is the undo phase. If a transaction had been running for hours, undoing it can take just as long. Recovery time is proportional to the longest active transaction. Meanwhile, the database is unavailable.

### How ADR Fixes This

ADR redesigns the recovery process with three key mechanisms:

**Persistent Version Store (PVS)** stores row versions directly in the database, not in tempdb. Every physical modification gets a version, which means undo can happen logically — by simply marking the transaction as aborted and letting concurrent queries ignore its row versions.

**Logical Revert** replaces the traditional log-based undo. Instead of scanning backward through the transaction log, ADR performs row-level version-based undo using PVS. Rollback is instantaneous regardless of transaction size.

**Aggressive Log Truncation** is possible because ADR doesn't need to retain transaction log records for the undo phase. The log can be truncated as checkpoints occur, even with active long-running transactions.

> **Important:** ADR is always enabled in Azure SQL Database and Azure SQL Managed Instance. You can't disable it in these services.

### When ADR Makes a Difference

ADR's biggest impact is on workloads with long-running transactions. Without ADR, a transaction that's been running for an hour could mean an hour-long undo phase during recovery. With ADR, recovery completes in seconds.

ADR also prevents the transaction log from growing out of control when long-running transactions are active. In traditional SQL Server, the log can't truncate past the oldest active transaction. With ADR, aggressive truncation keeps log growth in check.

For most workloads, you'll never notice ADR is there — recovery is fast, log growth is tame, and rollbacks are instant. But if your application has batch processes that run long transactions, ADR is quietly saving you from what could be catastrophic recovery times.

### The Performance Trade-Off

ADR isn't free. Write-intensive workloads generate row versions that consume space in PVS, and data pages may split more frequently to accommodate in-row versions. Transaction log generation can increase because all row versions are logged.

For most workloads, the overhead ranges from undetectable to minor. The certain benefit of fast recovery outweighs the potential cost. But if you're running extremely write-heavy workloads and notice increased space consumption, PVS usage is worth monitoring through the `sys.dm_tran_persistent_version_store_stats` DMV.

> **Tip:** Avoid unnecessarily long-running transactions even with ADR. Long transactions delay PVS cleanup and increase storage consumption. Large DDL operations in a single transaction can also cause pressure on the secondary log stream (SLOG).

## Restore Paths

When you need to recover data, the right restore mechanism depends on the scenario. Azure SQL provides several paths, each with different characteristics.

### Point-in-Time Restore (PITR)

<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/recovery-using-backups.md -->

PITR is the most common restore operation. It creates a new database on the same server (SQL Database) or same/different instance (Managed Instance), recovered to any second within your retention window.

Key characteristics:

- Creates a **new database** — you can't overwrite the original.
- Restore time depends on database size, activity level, and the number of transaction logs to replay. Large databases can take hours.
- After restoring, rename the original and swap in the restored database if you need to replace it.
- PITR is same-server only for SQL Database. You can't restore cross-server, cross-subscription, or cross-region with PITR.

Concurrent restore limits exist per subscription:

| Scope | Max concurrent | Max queued |
|-------|---------------|------------|
| Single database | 30 | 100 |
| Elastic pool | 4 per pool | 2,000 |

For Managed Instance, PITR is more flexible — you can restore to the same instance, a different instance, or even a different subscription.

### Deleted-Database Restore

<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/recovery-using-backups.md -->

If someone drops a database, you can restore it to the point of deletion or any earlier point within the retention window. The database must be restored to the same server where it was created.

The service takes a final transaction log backup before deletion to prevent data loss. Recently deleted databases may take a few minutes to appear in the Azure portal's deleted databases list.

> **Warning:** Deleting a *server* deletes all databases and their PITR backups. Without soft-delete retention configured (see "Deleted-Server Restore" below), a deleted server can't be recovered. LTR backups do survive server deletion — see the canonical explanation in the LTR section earlier in this chapter.

### Geo-Restore

<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/recovery-using-backups.md -->

Geo-restore recovers a database from geo-replicated backups to any server in any Azure region. This is your fallback when an entire region is unavailable.

- Requires **GRS or GZRS** backup storage redundancy. If you're using LRS or ZRS, geo-restore is unavailable.
- RPO can be up to several minutes due to asynchronous replication lag.
- Restore can take significant time for large databases, and capacity in the target region isn't guaranteed during a regional outage.
- Same-subscription only.

Geo-restore is the most basic DR mechanism. For business-critical applications, failover groups (covered in Chapter 13) provide much lower RTO and RPO with guaranteed capacity.

### Long-Term Retention Restore

LTR restores work like PITR but use the archived full backups instead of the short-term backup chain. You select a specific LTR backup (weekly, monthly, or yearly) and restore it to any server in the same subscription.

> **Note:** When restoring a Hyperscale database from an LTR backup, the read scale-out property is disabled on the restored database. You'll need to update the database after restore to re-enable it.

### Deleted-Server Restore (Preview)

<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/deleted-logical-server-restore.md -->

If someone deletes a logical server, soft-delete retention can save you. This preview feature keeps a deleted server in a recoverable state for a configurable period, so you can restore it — along with its databases — to its original state.

**How it works:** You configure a soft-delete retention period of **0–7 days** on the logical server. Setting 0 disables the feature entirely — a deleted server is gone immediately. A value of 1–7 keeps the server in a soft-deleted state for that many days instead of permanently removing it. During the retention window, you can restore the server through the portal, PowerShell, or CLI. Once restored, you can also restore the individual databases using standard PITR.

> **Important:** Logical servers older than two years automatically have soft-delete retention set to 7 days. Servers less than two years old have soft-delete retention disabled by default — you must enable it explicitly.

Configuration is straightforward. With the Azure CLI:

```bash
az sql server update \
    --name myserver \
    --resource-group myResourceGroup \
    --soft-delete-retention-days 7
```

To restore a soft-deleted server:

```bash
az sql server restore \
    --name myserver \
    --resource-group myResourceGroup \
    --location eastus
```

> **Gotcha:** If you use Azure Policy to enforce Microsoft Entra-only authentication, you can't restore a deleted server until you remove the policy. Also, managed identities are deleted with the server — any customer-managed key (CMK) encryption needs to be reconfigured after restore.

### Cross-Instance and Cross-Subscription Restore (Managed Instance)

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/backup-restore/point-in-time-restore.md -->

Managed Instance has richer restore capabilities than SQL Database. You can restore:

- To the same instance or a different instance
- From a deleted database to a different instance
- Across subscriptions (within the same tenant and region)

Cross-subscription restore requires specific RBAC permissions: `Microsoft.Sql/managedInstances/databases/readBackups/action` on the source and `Microsoft.Sql/managedInstances/crossSubscriptionPITR/action` on the target.

> **Gotcha:** System updates on Managed Instance take precedence over in-progress restores. Pending restores are suspended during updates and resume afterward, which can extend total restore time. Schedule restores outside your configured maintenance window if timing matters.

### Restore to SQL Server from Managed Instance

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/backup-restore/restore-database-to-sql-server.md -->

Need to move a database off Managed Instance entirely? You can take a copy-only backup and restore it to SQL Server 2022 or SQL Server 2025, as long as the instance's update policy aligns with the target SQL Server version.

The process is straightforward: create a credential on the managed instance pointing to a storage account, take a copy-only backup to that account, then restore from the storage account on your SQL Server instance. You can use either a managed identity or a SAS token for authentication.

```sql
-- On SQL Managed Instance: create credential and back up
CREATE CREDENTIAL [https://mystorageaccount.blob.core.windows.net/backups]
WITH IDENTITY = 'MANAGED IDENTITY';

BACKUP DATABASE [MyDatabase]
TO URL = 'https://mystorageaccount.blob.core.windows.net/backups/MyDatabase.bak'
WITH COPY_ONLY;
```

This gives you portability when you need to move data off the managed service entirely.

## Hyperscale Backup and Restore

<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/hyperscale-automated-backups-overview.md -->

Hyperscale takes a fundamentally different approach to backups. Instead of the traditional full/differential/log chain, Hyperscale uses **storage snapshots**.

### How It Works

Hyperscale databases separate storage from compute. Backups are pushed to the storage layer, meaning they consume zero resources on compute replicas — primary or secondary. Data file snapshots are taken regularly, and the transaction log is retained for the configured retention period. At restore time, the service reverts to the appropriate snapshot and replays transaction logs to reach the target point in time.

The practical result: **backups are virtually instantaneous** and **restores are independent of database size** (within the same region). A multi-terabyte Hyperscale database restores in minutes, not hours.

### Where Hyperscale Differs

| Aspect | Standard tiers | Hyperscale |
|--------|---------------|------------|
| Backup type | Full + diff + log | Snapshots + log |
| Backup impact | Runs on compute | Runs on storage layer |
| Restore speed | Size-dependent | Size-independent (same region) |
| Storage redundancy change | Anytime | Creation-time only |

> **Gotcha:** You can set backup storage redundancy for Hyperscale only during database creation. To change it afterward, you'll need to use active geo-replication or database copy, which involves downtime. Choose carefully up front.

Hyperscale also supports LTR (generally available since September 2023) and short-term retention of 1–35 days.

Geo-restore for Hyperscale is a **size-of-data operation**, unlike same-region restores. Even restoring to the paired region involves data transfer proportional to the database size. For details on Hyperscale architecture, see Chapter 10.

## Backup Transparency (Managed Instance)

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/business-continuity/backup-transparency.md -->

One of Managed Instance's advantages over SQL Database is backup transparency through the `msdb` database. You can query the standard SQL Server backup history tables to see exactly what backups have been taken:

```sql
SELECT TOP 20
    DB_NAME(DB_ID(bs.database_name)) AS [Database],
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END AS [Backup Type],
    CONVERT(BIGINT, bs.compressed_backup_size / 1048576) AS [Size (MB)],
    DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date)
        AS [Duration (sec)],
    bs.backup_finish_date AS [Completed]
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS bmf
    ON bs.media_set_id = bmf.media_set_id
ORDER BY bs.backup_finish_date DESC;
```

The supported tables are `backupset`, `backupmediaset`, and `backupmediafamily`. Fields related to file paths, usernames, and backup expiration aren't populated — those concepts don't map cleanly to the cloud. If you're migrating scripts from on-premises that query these columns, expect NULLs and adjust accordingly.

A few things to note:

- LTR backups don't appear in `msdb` because they're created at the storage level, not by the engine. For LTR backup metadata, query the Azure Resource Manager APIs or use the Azure portal.
- Records for automatic backups are retained for up to **60 days**. User-initiated (copy-only) backup history is preserved indefinitely. If you need compliance auditing beyond 60 days, you'll need Azure Monitor or LTR metadata queries — `msdb` won't have the history.
- Use the `is_copyonly` column to distinguish manual backups from automated ones.

SQL Database doesn't expose `msdb` backup tables at all. If you need backup visibility on SQL Database, use Azure Monitor metrics to track backup storage consumption.

## SQL Server VM Backup Strategies

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/backup-restore.md -->

SQL Server on Azure VMs gives you the most flexibility — and the most responsibility. You're managing SQL Server directly, so you get full control over backup strategies. There are four main approaches.

### Automated Backup via the IaaS Agent Extension

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/business-continuity/backup-and-restore/automated-backup.md -->

The SQL Server IaaS Agent extension provides an **Automated Backup** feature for SQL Server 2016 and later (Standard, Enterprise, Developer editions). It configures SQL Server Managed Backup to Azure, writing backups to an Azure storage account you specify.

| Setting | Range |
|---------|-------|
| Retention | 1–90 days |
| Full backup frequency | Daily or weekly |
| Full backup window | 1–23 hours |
| Log backup frequency | 5–60 minutes |

Automated Backup uses compression by default (can't be disabled), supports encryption, and can include system databases. The backup schedule is either automatic (based on log growth) or manual (your defined window).

> **Gotcha:** Automated Backup runs sequentially — one database at a time. If you have many large databases, make sure your backup window is wide enough to cover all of them. Missed backups mean your actual RPO is higher than configured.

### Azure Backup (Enterprise-Grade)

Azure Backup provides a centralized, policy-driven backup solution via a Recovery Services vault. Key advantages over Automated Backup:

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/backup-restore.md -->
- **15-minute RPO** for transaction log backups
- Point-in-time restore through the Azure portal
- Centralized monitoring and alerting across all SQL VMs
- Customizable retention policies (including long-term)
- Support for Always On Availability Groups with backup preference honoring
- Azure RBAC for backup and restore operations

This is the right choice for enterprise environments managing dozens or hundreds of SQL VMs.

> **Note:** Azure Backup and Automated Backup are mutually exclusive. You must disable Automated Backup before enabling Azure Backup.

### Manual Backup-to-URL and Managed Backup

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/backup-restore.md -->
For full control, use native SQL Server backup commands targeting Azure Blob Storage. Starting with SQL Server 2012 SP1 CU2, you can `BACKUP DATABASE ... TO URL` directly. SQL Server 2016 added striping (backup across multiple blobs, up to 12.8 TB) and file-snapshot backup.

### File-Snapshot Backup

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/backup-restore.md -->

When your database files are stored in Azure Blob Storage, **file-snapshot backup** provides near-instant backups by leveraging Azure storage snapshots. Backups and restores are almost instantaneous regardless of database size. This is a powerful option for large databases on VMs where traditional backup windows are impractical.

### Managed Identity for Backup/Restore to URL

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/business-continuity/backup-and-restore/backup-restore-to-url-using-managed-identities.md -->

Starting with SQL Server 2022 CU17, you can use managed identities instead of SAS tokens for backup-to-URL authentication. Create a credential with `IDENTITY = 'Managed Identity'`, assign the VM's managed identity the **Storage Blob Data Contributor** role on the target storage account, and back up with standard T-SQL:

```sql
CREATE CREDENTIAL [https://mystorageaccount.blob.core.windows.net/backups]
    WITH IDENTITY = 'Managed Identity';

BACKUP DATABASE [AdventureWorks]
    TO URL = 'https://mystorageaccount.blob.core.windows.net/backups/AdventureWorks.bak';
```

This eliminates SAS token management and rotation — a meaningful operational simplification.

With backups handled, the next chapter tackles how Azure SQL keeps your database *available* — the high-availability architectures that prevent you from needing those backups in the first place.
