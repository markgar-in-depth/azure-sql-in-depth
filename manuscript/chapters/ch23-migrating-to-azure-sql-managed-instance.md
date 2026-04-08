# Chapter 23: Migrating to Azure SQL Managed Instance

Your migration planning is done (Chapter 21), you've assessed compatibility, and you've chosen Managed Instance as your target. Now it's time to move the data. Managed Instance gives you the widest set of migration options in the Azure SQL family — from simple backup/restore to near-real-time replication — because it supports native SQL Server backup files directly. That's a huge advantage over SQL Database, where you're limited to BACPACs and DMS.

This chapter walks through every migration path available, helps you choose between them, and covers the post-migration work that's easy to overlook: TDE certificate handling, identity remapping, and performance validation.

## Migration Paths for Managed Instance

Managed Instance supports four primary migration paths, each suited to different constraints. Here's the quick comparison before we dive in:
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/log-replay-service-lrs/log-replay-service-compare-mi-link.md -->

| Path | Downtime | Min SQL Version |
|---|---|---|
| Log Replay Service | Minutes–hours | SQL Server 2008+ |
| Managed Instance link | Seconds | SQL Server 2016 SP3+¹ |
| Azure DMS | Minutes–hours | SQL Server 2008+ |
| Native backup/restore | Hours | SQL Server 2005+ |

¹ SQL Server 2016 and 2017 also require the matching Azure Connect pack in addition to the minimum CU/SP.

> **Tip:** All four paths are free — there's no per-migration charge. Your only costs are compute, storage, and any blob storage used as a staging area. LRS and native backup/restore suit "fire-and-forget" migrations with acceptable downtime. The MI link is the lowest-downtime option, especially for Business Critical. DMS wraps LRS in a guided experience when you don't want to manage the plumbing yourself.

## Log Replay Service (LRS)

**Log Replay Service** is a free cloud service built on SQL Server log-shipping technology. You take backups on your source SQL Server, upload them to Azure Blob Storage, and LRS restores them on the managed instance. It's the most broadly compatible option — supporting SQL Server 2008 through 2022 — and it works from any source, including AWS RDS, Google Cloud SQL, and on-premises instances.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/log-replay-service-lrs/log-replay-service-overview.md -->

### How LRS Works

The workflow is straightforward:

1. Take a full backup on your source SQL Server, then differentials and transaction log backups.
2. Upload backup files to an Azure Blob Storage container (one folder per database, flat structure — no nested folders).
3. Start LRS, pointing it at the blob container. LRS restores the full backup, then continuously applies differentials and log backups as they appear.
4. When you're ready, stop the source workload and trigger the cutover. The database comes online for read/write on the managed instance.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/migrate/log-replay-service-migrate.md -->

LRS scans the blob folder and reconstructs the backup chain from file headers — no special naming convention required.

### Autocomplete vs. Continuous Mode

LRS runs in two modes:

- **Autocomplete mode:** You upload the entire backup chain in advance and specify the last backup file name. LRS restores everything and finishes automatically. Use this for passive workloads where you can take all backups before starting.
- **Continuous mode:** LRS keeps scanning the blob folder for new backups. You keep taking log backups on the source and uploading them. When you're ready, stop the workload, upload the final log-tail backup, confirm it's restored, and trigger manual cutover. Use this for active workloads that require data catch-up.

```powershell
# Start LRS in continuous mode with a SAS token
Start-AzSqlInstanceDatabaseLogReplay `
    -ResourceGroupName "MyResourceGroup" `
    -InstanceName "my-managed-instance" `
    -Name "SalesDB" `
    -Collation "SQL_Latin1_General_CP1_CI_AS" `
    -StorageContainerUri "https://mystorage.blob.core.windows.net/migration/SalesDB" `
    -StorageContainerSasToken "sv=2023-01-03&ss=b&srt=sco&sp=rl&se=..."
```

```powershell
# Complete the migration (continuous mode)
Complete-AzSqlInstanceDatabaseLogReplay `
    -ResourceGroupName "MyResourceGroup" `
    -InstanceName "my-managed-instance" `
    -Name "SalesDB" `
    -LastBackupName "SalesDB_log_final.trn"
```

> **Important:** A single LRS job can run for a maximum of **30 days**, after which it's automatically canceled. Plan accordingly for very large databases.

### LRS Best Practices

- **Split backups into multiple files.** Large single-file backups are slower to upload and restore. Splitting improves parallelism.
- **Enable backup compression.** Faster uploads, smaller blob storage footprint.
- **Always use `CHECKSUM`.** Without it, restores are slower and you risk migrating a corrupt database.
- **Configure a maintenance window.** System updates take precedence over LRS. On General Purpose, pending restores pause and resume. On Business Critical, they're canceled and restarted. Schedule your maintenance window to avoid collisions with migration.
- **Keep the final backup small.** The cutover doesn't finish until the last file is restored. Frequent log backups shrink that final file and minimize downtime.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/migrate/log-replay-service-migrate.md -->

### LRS Limitations to Know

- The database is in a **restoring** state during migration — no read or write access until cutover completes.
- Only `.bak`, `.log`, and `.diff` files are supported. No BACPAC or DACPAC.
- SAS tokens must have **exactly** `Read` and `List` permissions. Add `Write` and LRS refuses to start.
- The backup URI path, container name, and folder names can't contain `backup`, `Backup`, or `backups` — they're reserved keywords.
- LRS supports up to **100 simultaneous database restores** per instance and **150 per subscription**.
- For SQL Server 2019+, enable **accelerated database recovery** before migrating — you can't enable it afterward.
- For SQL Server 2019+, set the **persistent version store** filegroup to `PRIMARY` before migrating, or you'll hit restore failures on the managed instance.
- Enable **Service Broker** on the source before migrating if you need it on the target — you can't enable it post-migration if it was disabled.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/migrate/log-replay-service-migrate.md -->

> **Gotcha:** Migrating to Business Critical with LRS means extra downtime after cutover. The database must be seeded to three secondary replicas before it's available. For large databases, this can take hours. If that's unacceptable, migrate to General Purpose first and upgrade later, or use the Managed Instance link instead.

### Authentication Options

LRS supports two ways to access your blob storage:

- **SAS token:** Generate a token with `Read` and `List` permissions on the container. Simple to set up, but tokens expire.
- **Managed identity:** Assign the `Storage Blob Data Reader` role to your managed instance's system or user-assigned identity. More secure and no token expiration to manage.

> **Warning:** You can't use both a SAS token and a managed identity on the same storage account simultaneously. Pick one.

## The Managed Instance Link

The **Managed Instance link** is the lowest-downtime migration option. It uses distributed availability groups to stream transaction log records directly from SQL Server to the managed instance — no intermediate blob storage, no backup/upload cycle. Where LRS gives you minutes-to-hours of downtime during cutover, the MI link gives you seconds — making it the only truly online migration path, especially to the Business Critical tier.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/managed-instance-link-feature-overview.md -->

### Why the Link Is Different
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/log-replay-service-lrs/log-replay-service-compare-mi-link.md -->

Beyond the near-zero downtime, the link has several advantages over LRS:

- **Read-only access during migration.** The replicated database on the managed instance is queryable while migration is in progress. You can validate data, test workloads, and run reporting before cutting over.
- **No 30-day limit.** You can keep the link running for months or years. There's no deadline forcing a cutover.
- **Resilient to interruptions.** If SQL Server restarts, network blips occur, or the managed instance fails over, the link automatically resumes replication.
- **Reverse migration.** With SQL Server 2022 or 2025, you can fail back from Managed Instance to SQL Server if the migration doesn't go as planned. LRS can't do this.

### Version Support

The MI link requires SQL Server 2016 or later (Enterprise, Developer, or Standard edition). The functionality varies by version:
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/managed-instance-link-feature-overview.md -->

| SQL Server Version | Direction | Failback Support |
|---|---|---|
| 2016 SP3 + Azure Connect pack | SQL Server → MI only | No |
| 2017 CU31 + Azure Connect pack | SQL Server → MI only | No |
| 2019 CU20 | SQL Server → MI only | No |
| 2022 RTM+ | Bidirectional | Yes (online + offline) |
| 2025 RTM+ | Bidirectional | Yes (online + offline) |

> **Important:** For SQL Server 2016–2019, failing over to Managed Instance **breaks the link permanently**. There's no fail back. With SQL Server 2022 or 2025, you can maintain the link and fail back and forth — but the managed instance's update policy must match the SQL Server version (SQL Server 2022 policy for 2022, SQL Server 2025 policy for 2025).

### Preparing the Environment

Setting up the MI link requires more upfront work than LRS. You need:

1. **Network connectivity** between SQL Server and the managed instance — VPN, ExpressRoute, or VNet peering for Azure VMs.
2. **A database master key** in the `master` database on SQL Server (if one doesn't exist).
3. **Availability groups enabled** on the SQL Server instance.
4. **Startup trace flags** `-T1800` and `-T9567` for optimized replication performance.
5. **Firewall ports open** for the distributed availability group traffic.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-preparation.md -->

```sql
-- Create a database master key if you don't have one
USE master;
GO
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong_password>';
```

On the Azure side, you need `SQL Managed Instance Contributor` role (or equivalent custom permissions) and a managed instance configured with the appropriate update policy if you want bidirectional failover with SQL Server 2022.

> **Gotcha:** Collation between SQL Server and Managed Instance must match. A mismatch can cause server name casing issues and prevent the link from connecting.

### Configuring the Link with SSMS

The easiest way to configure the link is through the **New Managed Instance link** wizard in SSMS (v19.2 or later):
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-configure-how-to-ssms.md -->

1. Connect to your SQL Server in SSMS.
2. Right-click the database, go to **Azure SQL Managed Instance link** → **New…**
3. The wizard walks you through environment validation, certificate exchange, and link creation.

For scripted or automated setups, you can configure the link with T-SQL and PowerShell scripts. This is useful for CI/CD pipelines or when SSMS isn't available.

> **Note:** The link supports one database per link. To replicate 10 databases, create 10 individual links. Each link is independently monitored and failed over, so 10 links means 10 cutover operations to coordinate — plan the sequencing accordingly.

### Online Migration with Planned Failover

Once the link is established and initial seeding completes, the migration cutover is straightforward:
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-migrate.md -->

1. **Stop the workload** on the source SQL Server database so the secondary catches up.
2. **Verify data synchronization** — confirm the redo queue is empty and all data has replicated.
3. **Initiate planned failover** using SSMS, T-SQL, or PowerShell. This temporarily switches to synchronous commit mode to guarantee zero data loss, then completes the failover.
4. For migration (not DR), check **Remove link after successful failover** to cleanly break the link.
5. **Repoint your application** to the managed instance endpoint.

```sql
-- Planned failover via T-SQL (SQL Server 2022 CU13+)
ALTER AVAILABILITY GROUP [MI_Link_SalesDB] FAILOVER;
```

The cutover itself takes seconds. That's the near-zero downtime promise.

### Best Practices and Troubleshooting

**Take regular transaction log backups on SQL Server while the link is active.** The link replicates by sending transaction log records. Until records are confirmed on the secondary, they can't be truncated from the source. Without regular log backups, your transaction log file grows unbounded.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-best-practices.md -->

```sql
-- Scheduled log backup (run via SQL Agent job)
BACKUP LOG [SalesDB]
TO DISK = N'C:\Backups\SalesDB_log.trn'
WITH NOFORMAT, NOINIT, COMPRESSION, STATS = 1;
```

**Match performance capacity between replicas.** If the managed instance can't keep up with the replication rate, the redo queue grows. Monitor `redo_queue_size` in `sys.dm_hadr_database_replica_states` on the primary.

**Validate the certificate chain periodically.** Managed Instance rotates its endpoint certificate automatically. If the SQL Server side gets out of sync, the link degrades. Run `sp_validate_certificate_ca_chain` on SQL Server to check.

**Avoid synchronous commit mode.** The link defaults to asynchronous, which is correct. Synchronous mode adds latency to every transaction on the primary because it waits for secondary confirmation. Planned failover temporarily switches to synchronous automatically — you don't need to set it yourself.

> **Tip:** Initial seeding is the longest phase. For a 100 GB database on a link capable of 84 GB/hour throughput, seeding takes roughly 1.2 hours. If the link speed drops to 10 GB/hour, the same database takes 10 hours. Plan your timeline around your network bandwidth. If seeding hasn't completed within 6 days, the link creation is automatically canceled.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-troubleshoot-how-to.md -->

### Ongoing Hybrid DR and Bidirectional Failover

The Managed Instance link isn't just a migration tool — it's also a hybrid disaster recovery solution. With SQL Server 2022 or 2025, you can maintain the link indefinitely, failing over to Managed Instance during a disaster and failing back to SQL Server once the issue is resolved. For details on configuring hybrid DR with the link, see Chapter 27.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-disaster-recovery.md -->

> **Tip:** If you're using the managed instance purely as a DR replica, activate the **Hybrid failover benefit** to save on licensing costs with a license-free passive DR replica.

## Azure Database Migration Service

**Azure Database Migration Service (DMS)** uses the same underlying LRS technology and APIs, but wraps them in a guided, managed experience. If you don't want to orchestrate blob storage, SAS tokens, and PowerShell scripts yourself, DMS handles the plumbing.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/log-replay-service-lrs/log-replay-service-overview.md -->

DMS supports both online (continuous sync) and offline (one-shot) migrations. For most teams, the tradeoff is simple: DMS is easier to set up, LRS gives you more control. If DMS can't access your backups, or your environment has restrictive network policies, go with LRS directly.

> **Note:** You can also trigger a migration from the Azure portal using the **Azure SQL migration extension** for Azure Data Studio, which provides a visual wizard on top of DMS.

## Native Backup and Restore

Managed Instance supports restoring standard SQL Server `.bak` files directly from Azure Blob Storage. This is the simplest path — no LRS orchestration, no DMS, no link setup. You take a backup, upload it, and restore it with T-SQL.

```sql
-- Restore from a backup in Azure Blob Storage
RESTORE DATABASE [SalesDB]
FROM URL = 'https://mystorage.blob.core.windows.net/backups/SalesDB_full.bak'
WITH REPLACE;
```

The catch: native restore is **offline only**. There's no mechanism to apply subsequent log backups and do a rolling cutover. Your downtime equals the time to take the final backup plus the time to restore it. For small databases or dev/test environments, that's fine. For production databases above a few hundred gigabytes, use LRS or the MI link.

## LRS vs. MI Link: Choosing the Right Approach

As noted earlier, both are free — so the decision is purely technical. The opening table covers downtime and version requirements — here's how to decide based on your environment:
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/log-replay-service-lrs/log-replay-service-compare-mi-link.md -->

**Choose LRS when:**

- Your source is SQL Server 2008–2014 (MI link requires 2016+).
- You can't establish VPN connectivity between SQL Server and the managed instance.
- You need a simple, fire-and-forget migration with acceptable downtime.
- You're on AWS RDS or Google Cloud SQL where you can't install availability group components.

**Choose the MI link when:**

- You need near-zero downtime (especially for Business Critical tier).
- You want read-only access to the database during migration for validation and testing.
- You want a reverse migration option back to SQL Server 2022 or 2025.
- Your migration might take longer than 30 days.
- You need resilience against interruptions — LRS can stall on broken backup chains and gets canceled on Business Critical failovers, while the link auto-resumes.

| Criterion | LRS | MI Link |
|---|---|---|
| Network setup | Blob storage (public) | VPN / ExpressRoute |
| Read during migration | No | Yes (read-only) |
| Max duration | 30 days | Unlimited |
| Resilience | Pauses / restarts | Auto-resumes |

## TDE Certificate Migration

If your source database uses **Transparent Data Encryption (TDE)** with a service-managed certificate, you must migrate that certificate to the managed instance *before* restoring the database. This applies to native backup/restore and LRS migrations. (DMS handles this automatically, and the MI link replicates TDE-encrypted databases without requiring manual certificate migration.)
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/migrate/tde-certificate-migrate.md -->

### Export the Certificate

On the source SQL Server, identify which certificate protects your database:

```sql
USE master;
GO
SELECT db.name AS database_name, cer.name AS certificate_name
FROM sys.dm_database_encryption_keys dek
LEFT JOIN sys.certificates cer
    ON dek.encryptor_thumbprint = cer.thumbprint
INNER JOIN sys.databases db
    ON dek.database_id = db.database_id
WHERE dek.encryption_state = 3;
```

Export the certificate to a pair of files:

```sql
USE master;
GO
BACKUP CERTIFICATE SalesDB_TDE_Cert
TO FILE = 'C:\Certs\SalesDB_TDE_Cert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\Certs\SalesDB_TDE_Cert.pvk',
    ENCRYPTION BY PASSWORD = '<StrongPassword>'
);
```

Convert the `.cer` and `.pvk` files into a single `.pfx` file using the `Pvk2Pfx` tool:

```cmd
pvk2pfx -pvk C:\Certs\SalesDB_TDE_Cert.pvk ^
    -pi "<StrongPassword>" ^
    -spc C:\Certs\SalesDB_TDE_Cert.cer ^
    -pfx C:\Certs\SalesDB_TDE_Cert.pfx
```

### Upload the Certificate

Upload the `.pfx` to the managed instance using PowerShell:

```powershell
$fileContentBytes = Get-Content 'C:\Certs\SalesDB_TDE_Cert.pfx' -AsByteStream
$base64Cert = [System.Convert]::ToBase64String($fileContentBytes)
$secureCert = $base64Cert | ConvertTo-SecureString -AsPlainText -Force
$securePassword = '<StrongPassword>' | ConvertTo-SecureString -AsPlainText -Force

Add-AzSqlManagedInstanceTransparentDataEncryptionCertificate `
    -ResourceGroupName "MyResourceGroup" `
    -ManagedInstanceName "my-managed-instance" `
    -PrivateBlob $secureCert `
    -Password $securePassword
```

> **Note:** The uploaded certificate isn't visible in `sys.certificates`. To verify it uploaded successfully, run `RESTORE FILELISTONLY` against the encrypted backup file.

> **Important:** The migrated certificate is temporary. After the restore completes, Managed Instance replaces it with either a service-managed certificate or your Azure Key Vault key, depending on your TDE configuration.

## Windows-to-Entra Identity Migration

On-premises SQL Server typically uses Windows Authentication with Active Directory users, groups, and service accounts. Managed Instance supports **Microsoft Entra ID** (formerly Azure AD) authentication, and you'll need to remap your Windows-based logins.

### The Remapping Process

1. **Inventory existing logins.** Query `sys.server_principals` on the source for all Windows logins and groups.
2. **Map Windows identities to Entra equivalents.** If you're using Azure AD Connect (or Entra Connect) to sync your on-premises AD with Entra ID, the same users and groups likely already exist in Entra.
3. **Create Entra logins on the managed instance.** Use `CREATE LOGIN [user@domain.com] FROM EXTERNAL PROVIDER`.
4. **Remap database users.** For each database, use `ALTER USER` to reassociate the database-level user with the new Entra login.

```sql
-- Create an Entra login on the managed instance
CREATE LOGIN [alice@contoso.com] FROM EXTERNAL PROVIDER;

-- Map the database user to the Entra login
USE [SalesDB];
ALTER USER [CONTOSO\alice] WITH LOGIN = [alice@contoso.com];
```

> **Gotcha:** Don't forget service accounts. Applications that connect using Windows Authentication with domain service accounts need to be updated to use either Entra authentication (with managed identity if possible) or SQL authentication.

### Handling Groups

If your on-premises setup grants permissions to AD groups, create corresponding Entra groups and add the same members. Then create a single login for the Entra group:

```sql
CREATE LOGIN [SalesDBReaders@contoso.com] FROM EXTERNAL PROVIDER;
```

This is cleaner and easier to maintain than migrating individual user logins.

## Post-Migration Validation

Cutting over is half the job. The other half is proving the migration actually worked — that performance matches expectations and nothing slipped through the compatibility cracks.

### Performance Baselining Comparison

Before migration, you should have captured baseline performance metrics on the source (as described in Chapter 21). After cutover, run the same workload and compare:

- **Query execution times.** Compare top queries by duration and CPU. Use Query Store on both source and target — Managed Instance enables it by default.
- **Wait statistics.** Run `sys.dm_os_wait_stats` and compare the top wait types. New waits or shifted proportions signal infrastructure differences (network latency, storage throughput, memory pressure).
- **I/O throughput.** Compare IOPS and latency. Managed Instance General Purpose uses Azure Premium Storage (with different IOPS caps than your on-premises SAN), while Business Critical uses local NVMe.
- **Resource utilization.** Check `avg_cpu_percent`, `avg_data_io_percent`, and `avg_log_write_percent` through `sys.dm_db_resource_stats`. If you're consistently hitting 90%+ on any metric, you may have undersized the instance.

> **Tip:** Don't compare raw numbers in isolation. An increase in query duration might be offset by a decrease in I/O wait time. Look at the full picture — total throughput, 95th-percentile latency, and overall workload completion time.

### Compatibility Assessment Rule Resolution

Chapter 21 covered running pre-migration assessments. Post-migration, you'll want to verify that any assessment warnings you accepted have actually resolved cleanly:

- **Unsupported features.** If the assessment flagged features like cross-database queries, CLR assemblies, or linked servers, confirm your workarounds are functioning in production.
- **Deprecated syntax.** T-SQL that triggered warnings should be tested end-to-end. Managed Instance has near-100% compatibility with SQL Server, but "near" isn't "total."
- **Agent jobs.** SQL Agent runs natively on Managed Instance, but jobs that reference local file paths, SSIS packages, or network shares may need adjustments.
- **Database mail.** If your source used Database Mail, reconfigure it on the managed instance with SMTP credentials that work from Azure.

Run your full integration test suite after migration. If you don't have one, this is a strong motivator to build one — before the next migration.

> **Gotcha:** Managed Instance's update policy affects your reverse migration options. There are three policies: **SQL Server 2022**, **SQL Server 2025**, and **Always-up-to-date**. The SQL Server 2022 policy lets you restore databases back to SQL Server 2022. The SQL Server 2025 policy lets you restore to SQL Server 2025 but *not* back to 2022. The Always-up-to-date policy blocks restore to any SQL Server version. If you need a rollback path, choose the update policy that matches your target SQL Server version.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/backup-restore/restore-database-to-sql-server.md, azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->
