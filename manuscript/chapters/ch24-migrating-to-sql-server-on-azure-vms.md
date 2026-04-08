# Chapter 24: Migrating to SQL Server on Azure VMs

Your on-premises SQL Server has served you well for years, maybe decades. Now the data center lease is expiring, the hardware is aging, or your team simply doesn't want to manage physical servers anymore. But you're not ready to refactor for PaaS — you need the full SQL Server engine, your existing version, and control of the OS. That's exactly where SQL Server on Azure VMs fits.

This chapter covers every migration path to get your SQL Server workloads onto Azure VMs:

- Lift-and-shift via Azure Migrate
- Backup/restore, log shipping, and detach/attach
- Near-zero-downtime distributed availability group migrations
- Azure Database Migration Service
- Migrating HA configurations, BI services, and server objects

> **Note:** Chapters 22 and 23 cover migration to Azure SQL Database and Managed Instance respectively. If you haven't yet chosen your deployment target, revisit Chapter 1's decision framework before diving in here.

## Migration Strategies

There are two fundamental approaches to moving SQL Server to Azure VMs: **lift-and-shift** and **migrate**. The distinction matters because it determines your downtime, your version flexibility, and how much work you'll do on the other side.

<!-- Source: migrate-from-sql-server/to-sql-server-on-azure-vms/overview.md -->

**Lift-and-shift** moves the entire machine — OS, SQL Server installation, databases, and everything else — as-is to an Azure VM. You use Azure Migrate with agent-based replication. The source server stays online during replication, so downtime is limited to the final cutover window. This is your best option when you want to preserve the exact SQL Server version and OS, need minimal code changes, and are migrating at scale (a single Azure Migrate project can discover and assess up to 35,000 machines).

**Migrate** moves just the databases (and optionally server objects) to a fresh SQL Server installation on an Azure VM. You pick the target SQL Server version and OS independently. This is the right approach when you want to upgrade SQL Server versions, move off an older OS, or consolidate multiple instances.

### Lift-and-Shift via Azure Migrate

Azure Migrate uses the same agent-based replication architecture as Azure Site Recovery. You deploy a replication appliance on-premises (a Windows Server 2016 machine running a configuration server and process server), install mobility agents on your source SQL Server machines, and let Azure Migrate handle continuous replication to Azure managed disks.

The workflow:

1. Create an Azure Migrate project and configure the replication appliance.
2. Install the mobility agent on each source server.
3. Start replication — Azure Migrate continuously syncs disk-level changes.
4. Run test migrations to validate everything works in Azure.
5. Perform the final migration, which triggers a brief cutover window.

> **Tip:** After lift-and-shift, register your VM with the SQL IaaS Agent extension immediately (→ see the Post-Migration Checklist below and Chapter 28 for details).

Azure Migrate now supports lifting both availability group and failover cluster instance topologies directly. We'll cover those in the "Migrating High-Availability Configurations" section later in this chapter.

### Migrate: Backup and Restore

Backup and restore is the simplest and most battle-tested migration method. Take a full backup on-premises, copy it to Azure, restore it on the target VM. Done.

The recommended approach depends on your database size and SQL Server version:

| Method | Best For |
|---|---|
| Backup to file + AzCopy | Most migrations (any version) |
| Backup to URL | Direct-to-Blob (2012 SP1 CU2+; 12.8 TB limit on 2016+) |
| Detach/attach via Blob | Very large DBs where backup itself is too slow |

<!-- Source: migrate-from-sql-server/to-sql-server-on-azure-vms/overview.md -->

For databases under 1 TB with good network connectivity, **backup to URL** is the cleanest path. You back up directly to Azure Blob Storage, then restore from the URL on the target VM — no intermediate file copies.

For larger databases, take a compressed backup to a local file, then use **AzCopy** to upload it to Blob Storage. For databases over 2 TB, consider splitting the backup into multiple files for faster transfer and parallel restore:

```sql
-- Compressed backup split across four files
BACKUP DATABASE [YourDatabase]
TO DISK = N'C:\Backups\YourDB_1.bak',
   DISK = N'C:\Backups\YourDB_2.bak',
   DISK = N'C:\Backups\YourDB_3.bak',
   DISK = N'C:\Backups\YourDB_4.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;
GO
```

Then upload with AzCopy:

```bash
azcopy copy "C:\Backups\YourDB_*.bak" \
  "https://yourstorageaccount.blob.core.windows.net/backups/" \
  --put-md5
```

On the target VM, restore from the uploaded files:

```sql
RESTORE DATABASE [YourDatabase]
FROM DISK = N'\\path\YourDB_1.bak',
     DISK = N'\\path\YourDB_2.bak',
     DISK = N'\\path\YourDB_3.bak',
     DISK = N'\\path\YourDB_4.bak'
WITH RECOVERY, STATS = 10;
GO
```

> **Gotcha:** Backup to URL has a 12.8 TB limit per file starting with SQL Server 2016. Earlier versions cap at 1 TB. For databases approaching these limits, use the multi-file backup approach with AzCopy instead.

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/backup-restore.md -->
<!-- TODO: source needed for "Earlier versions cap at 1 TB" -->

> **Tip:** Always use `WITH COMPRESSION` and `WITH CHECKSUM` for migration backups. Compression cuts transfer time dramatically, and checksums catch corruption before you discover it the hard way on the target.

### Migrate: Log Shipping

Log shipping gives you a warm standby on the Azure VM before cutover. You restore a full backup with `NORECOVERY`, then continuously ship and apply transaction log backups. When you're ready to cut over, stop the source workload, ship the final log, and recover the database on the target.

Log shipping has been a core SQL Server feature for many versions, so it works with any source version you're likely to encounter. It provides **minimal downtime** with less configuration overhead than a distributed availability group — a good middle ground when you can't afford a long cutover window but don't want the complexity of DAG setup.

The high-level steps:

1. Take a full backup and restore it on the Azure VM with `NORECOVERY`.
2. Configure log shipping — the source writes log backups to a share accessible from Azure (or to Azure Blob Storage directly).
3. The target VM restores log backups on a schedule (every 5–15 minutes is typical).
4. At cutover time, stop the application, take a final `BACKUP LOG WITH NORECOVERY`, ship it, and `RESTORE WITH RECOVERY` on the target.

> **Note:** Log shipping requires the same network connectivity described in the DAG prerequisites section below (site-to-site VPN or ExpressRoute). Without it, use the offline backup-and-restore approach instead.

### Migrate: Detach/Attach and VHD Conversion

Two additional methods serve niche scenarios:

**Detach and attach** works by detaching the database files from the source, uploading the `.mdf` and `.ldf` files to Azure Blob Storage via AzCopy, then attaching them on the target VM. This bypasses the backup/restore process entirely and can be faster for very large databases where the backup itself would take too long. The downside is that the database is offline from the moment you detach.

**VHD conversion** takes the entire on-premises machine — OS, SQL Server, and databases — converts it to a Hyper-V VHD, uploads it to Azure Storage, and deploys a new VM from the uploaded VHD. This migrates everything in one shot, including system databases and all server-level configuration.

Use VHD conversion when you need to preserve the complete server state but can't use Azure Migrate — for example, due to network constraints that prevent agent-based replication.

### Distributed Availability Group Migration

For large databases where you need **near-zero downtime**, a distributed availability group (DAG) is the best migration method. A DAG spans two separate availability groups — one on-premises and one on the Azure VM — and continuously synchronizes data between them. When you're ready to cut over, you fail over to the Azure side.

<!-- Source: migrate-from-sql-server/to-sql-server-on-azure-vms/migrate-with-a-distributed-ag/_summary.md -->

There are two variants:

- **Standalone instance migration:** You create a clusterless AG on the source instance (`CLUSTER_TYPE = NONE`), a matching AG on the target VM, then create the DAG to link them. No WSFC or listener required on either side.
- **Availability group migration:** If your source already runs in an AG, you create a new AG on the Azure VM and link the two via a DAG. This requires a WSFC and listener on both sides.

#### Prerequisites

Before you set up a DAG migration, both sides need to be ready:

**Source requirements:**
- SQL Server 2017+ for standalone instance migration, SQL Server 2016+ for AG migration
- Enterprise edition
- Always On availability groups feature enabled
- Databases backed up in full recovery mode
- Ports 1433 (SQL Server) and 5022 (mirroring endpoint) open in the firewall

**Target requirements:**
- Same or higher SQL Server version as source
- Enterprise edition
- Always On feature enabled
- Same ports open
- If using automatic seeding, the source and target instance names must match

**Connectivity:** Site-to-site VPN or ExpressRoute between on-premises and the Azure virtual network. Both SQL Server instances must be in the same domain, or their domains must be federated.

<!-- Source: sql-server-on-azure-vms/migration-guides/from-sql-server/using-distributed-ag/_summary.md -->

#### Setting Up a Standalone DAG Migration

Here's the end-to-end process for migrating databases from a standalone instance:

**Step 1: Create mirroring endpoints on both servers.**

```sql
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
GO
```

Run this on both the source and target instances. If using service accounts that aren't sysadmins, grant connect permission explicitly:

```sql
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [CONTOSO\SqlServiceAccount];
```

**Step 2: Create the source availability group.** On the source instance, wrap your databases in a clusterless AG:

```sql
CREATE AVAILABILITY GROUP [OnPremAG]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    CLUSTER_TYPE = NONE
)
FOR DATABASE [YourDatabase]
REPLICA ON N'OnPremNode'
WITH (
    ENDPOINT_URL = N'TCP://OnPremNode.contoso.com:5022',
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = NO)
);
GO
```

**Step 3: Create the target availability group.** On the Azure VM:

```sql
CREATE AVAILABILITY GROUP [AzureAG]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    CLUSTER_TYPE = NONE,
    REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0
)
FOR REPLICA ON N'SQLVM'
WITH (
    ENDPOINT_URL = N'TCP://SQLVM.contoso.com:5022',
    FAILOVER_MODE = MANUAL,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = NO)
);
GO
```

**Step 4: Create the distributed availability group.** On the source:

```sql
CREATE AVAILABILITY GROUP [DAG]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    'OnPremAG' WITH (
        LISTENER_URL = 'tcp://OnPremNode.contoso.com:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    'AzureAG' WITH (
        LISTENER_URL = 'tcp://SQLVM.contoso.com:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
GO
```

**Step 5: Join the target AG to the DAG.** On the Azure VM:

```sql
ALTER AVAILABILITY GROUP [DAG]
JOIN AVAILABILITY GROUP ON
    'OnPremAG' WITH (
        LISTENER_URL = 'tcp://OnPremNode.contoso.com:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    'AzureAG' WITH (
        LISTENER_URL = 'tcp://SQLVM.contoso.com:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
GO
```

Automatic seeding kicks in and the databases start synchronizing. Monitor progress on both sides:

```sql
SELECT ag.name, drs.database_id,
       DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc,
       drs.last_hardened_lsn
FROM sys.dm_hadr_database_replica_states AS drs
INNER JOIN sys.availability_groups AS ag
    ON drs.group_id = ag.group_id;
```

Wait until `synchronization_state_desc` shows `SYNCHRONIZED` for the primary AG and `SYNCHRONIZING` for the DAG, and the `last_hardened_lsn` values match on both sides.

**Step 6: Cut over.** Fail over the DAG to the Azure side, update your application connection strings, then drop the DAG on both sides:

```sql
DROP AVAILABILITY GROUP [DAG];
```

> **Gotcha:** If the source and target instance names don't match, automatic seeding won't work. You'll need to set `SEEDING_MODE = MANUAL` and manually restore the databases on the target with `NORECOVERY` before joining the DAG.

> **Tip:** If you're upgrading SQL Server versions during the migration (say, from 2017 to 2022), you must use manual seeding. Create the DAG with `SEEDING_MODE = MANUAL`, manually back up and restore the databases to the target, then join the DAG.

### Azure Database Migration Service

Azure Database Migration Service (DMS) provides a managed migration experience for SQL Server to Azure VMs. It supports both **online** (continuous sync) and **offline** (one-time) migrations using backup files.

The online migration workflow:

1. **Configure DMS** — create a migration project in the Azure portal, specifying source and target SQL Server instances.
2. **Point to backups** — DMS reads backup files from either an SMB network share or Azure Blob Storage. For online mode, provide a full backup followed by continuous log backups in the share.
3. **Monitor progress** — DMS applies the full backup and then continuously restores log backups on the target VM. Track restore status in the portal.
4. **Cutover** — when the target is caught up and you're ready, trigger the cutover. DMS applies the final logs and brings the database online.

For an offline migration, you point DMS at a full backup (and optionally differential and log backups) and it restores them in order on the target. No ongoing sync — just a one-shot restore.

DMS is usually preferable to manual log shipping when you want portal-based monitoring, don't want to configure log shipping jobs by hand, or need to migrate multiple databases in parallel with centralized tracking. It's also a good choice when your team isn't comfortable scripting backup-restore chains in T-SQL.

> **Note:** DMS requires the same network connectivity described in the DAG prerequisites section (VPN or ExpressRoute), plus the DMS hybrid worker for on-premises sources.

### Choosing a Migration Method

With so many options, here's a decision guide:

| Scenario | Method |
|---|---|
| Keep same OS and SQL version | Lift-and-shift |
| Upgrade SQL Server version | Backup/restore or DAG |
| Large DB, minimal downtime | DAG |
| Moderate DB, some downtime OK | Log shipping |
| Simple one-time move | Backup/restore |
| No network connectivity | VHD conversion |
| Managed migration experience | DMS |
| Migrating at scale (many VMs) | Azure Migrate |

## Migrating High-Availability Configurations

If your on-premises SQL Server runs in an Always On availability group or failover cluster instance, you don't have to tear down HA first and rebuild it after. Azure Migrate now supports migrating both topologies directly.

### Always On Availability Group Migration

Azure Migrate can lift an entire AG to Azure VMs using agent-based replication. The process mirrors a standard lift-and-shift but handles the cluster and AG metadata:

1. Deploy the replication appliance and install mobility agents on all AG replica nodes.
2. Start replication for each replica VM.
3. Perform a test migration to validate the AG works correctly in Azure.
4. Run the full migration — Azure Migrate migrates each node, preserving the WSFC configuration and AG metadata.
5. Reconfigure the AG listener and connectivity post-migration (you'll need to set up an Azure load balancer or DNN listener depending on your subnet configuration — see Chapter 28).

<!-- Source: sql-server-on-azure-vms/migration-guides/from-sql-server/availability-group-migrate.md -->

Alternatively, you can use a **distributed availability group** to migrate an existing AG. This approach lets you keep the source AG online and serving traffic while the Azure-side AG catches up. Once synchronized, you fail over to Azure. This is the lowest-downtime option for AG migrations, but requires more configuration than a straight lift-and-shift.

### Failover Cluster Instance Migration

FCI migration also uses Azure Migrate with agent-based replication. Each node in the failover cluster is migrated as a physical server to an Azure VM. After migration, you reconfigure the cluster to use **Azure shared disks** as the shared storage layer (replacing your on-premises SAN or Storage Spaces Direct).

<!-- Source: sql-server-on-azure-vms/migration-guides/from-sql-server/sql-server-failover-cluster-instance-to-sql-on-azure-vm.md -->

The high-level steps:

1. Prepare Azure — create a VNet, verify permissions (Contributor or Owner on the subscription).
2. Deploy the replication appliance on a separate Windows Server 2016 machine.
3. Install the mobility agent on each FCI node and start replication.
4. After replication completes, run the migration for each node.
5. Post-migration, create Azure shared disks and reconfigure the Windows Server Failover Cluster to use them.
6. Reinstall the FCI using the new shared storage.

> **Important:** FCI migration has higher downtime than AG migration because all cluster nodes must be stopped and migrated. Plan for a maintenance window proportional to your disk sizes and network throughput.

> **Tip:** If you're migrating an FCI and have flexibility, consider whether an Always On availability group on Azure VMs might serve you better. AGs are the more natural HA pattern on Azure since they don't require shared storage. The FCI migration path makes sense when you need to preserve your existing topology or have specific FCI requirements.

## Migrating BI Services

If your SQL Server hosts Integration Services, Reporting Services, or Analysis Services alongside your databases, these need their own migration treatment. A database backup doesn't capture BI services.

### SSIS (SQL Server Integration Services)

You have two paths for SSIS migration:

- **Backup and restore SSISDB.** If your packages are deployed using the project deployment model and stored in the SSIS catalog (SSISDB), back up the SSISDB database and restore it on the target VM. This brings along all projects, packages, environments, and execution history.
- **Redeploy packages.** Export your SSIS projects and redeploy them on the target using SSMS, DTUTIL, or the SSIS deployment wizard.

If your packages still use the legacy package deployment model, consider converting them to the project deployment model before migration. The project model is easier to manage and deploy.

> **Tip:** With lift-and-shift via Azure Migrate, SSIS comes along automatically since the entire server migrates as-is. The manual approaches above are only necessary when using backup/restore or other database-level migration methods.

### SSRS (SQL Server Reporting Services)

Migrate SSRS by using the native mode migration process: back up the report server databases (`ReportServer` and `ReportServerTempDB`), back up the encryption key, and restore everything on the target VM's SSRS instance.

Alternatively, if you're looking to modernize, consider migrating SSRS reports to **paginated reports in Power BI** using Microsoft's open-source RDL Migration Tool. This moves your reports out of on-premises SSRS entirely.

### SSAS (SQL Server Analysis Services)

For Analysis Services databases — whether multidimensional or tabular models — you can migrate using:

- **SSMS:** Back up and restore the SSAS database interactively. Best for one-off migrations where you're moving a small number of models manually.
- **AMO (Analysis Management Objects):** Script the migration programmatically. Use AMO when you need to automate migrations across multiple models or integrate into a deployment pipeline.
- **XMLA scripting:** Generate XMLA scripts to back up and restore models. XMLA is the right choice when you want version-controlled, repeatable scripts without taking a dependency on the AMO library.

If you're running tabular models, also consider whether **Azure Analysis Services** or **Power BI Premium** (via XMLA read/write endpoints) might be a better long-term home than running SSAS on a VM.

## Server Object Migration

Databases are only part of the picture. A SQL Server instance carries logins, Agent jobs, linked servers, and other objects that live at the server level. Miss any of these and your application breaks on the new VM.

<!-- Source: migrate-from-sql-server/to-sql-server-on-azure-vms/guide.md -->

The general approach is to **script everything with SSMS** on the source and run the scripts on the target. Here's what you need to move:

| Object | Method |
|---|---|
| Logins and roles | SSMS scripting |
| SQL Server Agent jobs | SSMS scripting |
| Agent alerts and operators | SSMS scripting |
| Linked servers | SSMS scripting |
| Server triggers | SSMS scripting |
| Database Mail | SSMS scripting |
| Cryptographic providers | Key Vault |
| Replication | SSMS scripting |
| Backup devices | Azure Backup |

For cryptographic providers, convert your on-premises provider configuration to Azure Key Vault integration on the target VM. For backup devices, replace local backup device definitions with Azure Backup or backup-to-URL configurations.

### Logins

Login migration is the one that bites people most often. When you restore a database on a new server, the database users exist but their corresponding server-level logins don't. This creates **orphaned users**.

To migrate logins with their SIDs (so they map correctly to existing database users), script the logins from the source using `sp_help_revlogin` or the SSMS migration component. The key is preserving the SID — if the SID doesn't match, you'll need to run `ALTER USER ... WITH LOGIN` for every orphaned user in every database.

```sql
-- Check for orphaned users after migration
SELECT dp.name AS database_user, dp.sid
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE sp.sid IS NULL
  AND dp.type IN ('S', 'U')
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys');
```

### Agent Jobs

Script all Agent jobs on the source and run the scripts on the target. Be sure to also migrate:

- **Proxy accounts** that jobs use to run under different credentials.
- **Credential objects** referenced by those proxies.
- **Operators** that receive notifications.
- **Schedules**, which are scripted as part of the job but may need timezone adjustments if the Azure VM runs in a different time zone than the source.

> **Gotcha:** If your Agent jobs reference local file paths (for example, SSIS package paths, backup destinations, or log file locations), those paths won't exist on the Azure VM. Update them before enabling the jobs on the target.

### Linked Servers

Script linked servers from SSMS. After migration, test each linked server connection — if they point to other on-premises servers, you'll need network connectivity (VPN or ExpressRoute) from the Azure VM back to those sources, or migrate those servers too.

> **Note:** For a complete list of server objects that need migration attention, see the SQL Server documentation on "Manage Metadata When Making a Database Available on Another Server." It covers edge cases like PolyBase external data sources, full-text catalogs, and server-scoped certificates.

## Post-Migration Checklist

After migration, don't skip validation. Run through this list before declaring the migration complete:

1. **Register with the SQL IaaS Agent extension** for automated backups, patching, portal management, and Azure Hybrid Benefit license tracking.
2. **Verify all databases are online** and accessible.
3. **Run orphaned user checks** and fix login-to-user mappings.
4. **Test Agent jobs** — run each one manually and verify success.
5. **Test linked server connections.**
6. **Validate application connectivity** — connection strings, firewall rules, NSG rules.
7. **Run performance baselines** and compare against your pre-migration baseline. Follow the storage and VM sizing best practices from Chapter 28.
8. **Configure backups** — set up automated backups through the SQL IaaS Agent extension or Azure Backup.
9. **Configure HA/DR** if not migrated as part of a lift-and-shift (→ see Chapter 28 for AG and FCI configuration on Azure VMs).

The migration itself is often the easy part. Getting all the surrounding pieces — logins, jobs, linked servers, application connection strings, monitoring, backups — properly configured on the target is what separates a smooth migration from a week of firefighting. Take the time to validate everything before you decommission the source.
