# Chapter 13: Disaster Recovery

High availability keeps your databases running when a node fails or an availability zone goes dark. Disaster recovery picks up where HA leaves off — when an entire region disappears.

Chapter 12 covered the HA architectures that protect you from localized failures. This chapter is about the mechanisms that protect you from the worst case: a sustained regional outage that makes your primary databases unreachable. We'll cover active geo-replication, failover groups, the DR design patterns that stitch them together, and what to do when the alerts start firing.

## Active Geo-Replication (SQL Database)

**Active geo-replication** continuously replicates data from a primary database to up to four readable secondary databases, each on a different logical server in any Azure region. It's a per-database feature — you configure it individually for each database that needs cross-region protection.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/active-geo-replication-overview.md -->

Under the hood, geo-replication uses the same Always On availability group technology that powers local HA. Changes stream asynchronously from the primary's transaction log to each geo-secondary. The data on secondaries is guaranteed to be transactionally consistent — you won't see partial transactions — but it may lag behind the primary by seconds or more, depending on workload intensity and network latency.

### Readable Secondaries

Every geo-secondary is readable. You can route reporting queries, analytics workloads, or read-heavy API endpoints to a secondary using the same or different security principals as the primary. This offloads work from the primary and gives you geographic read distribution, but it's a side benefit — the primary purpose is DR.

> **Important:** A geo-secondary in the *same* region as the primary provides read scale-out but **not** disaster recovery. For DR, place your secondary in a different region. Use zone redundancy (→ see Chapter 12) for protection within a region.

### Planned and Forced Failover

Geo-replication supports two failover modes:

| Failover mode | Data loss | When to use |
|---|---|---|
| Planned (no data loss) | None | DR drills, region migration, failback after outage |
| Forced | Possible | Primary unreachable, need immediate recovery |

**Planned failover** synchronizes all pending transactions to the secondary before switching roles. It's safe to run in production and is the right choice for DR drills and region migrations. Duration depends on how much unsynchronized log exists on the primary.

**Forced failover** immediately promotes the secondary to primary without waiting for synchronization. Any transactions committed on the primary but not yet replicated are lost. Use this only when the primary is inaccessible and you need to restore service now.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/active-geo-replication-overview.md -->

After either type of failover, the connection endpoint changes because the new primary lives on a different logical server. Your application's connection strings must point to the new server — this is a key difference from failover groups, which handle endpoint redirection automatically.

> **Gotcha:** If your database is a member of a failover group, you can't initiate failover using the geo-replication failover command. You must use the failover group's failover command. To fail over an individual database, remove it from the failover group first.

### Configuring Geo-Secondaries

Both primary and geo-secondary must share the same service tier. Microsoft strongly recommends matching the compute tier (provisioned or serverless) and compute size (DTUs or vCores) as well. If the secondary has less compute capacity than the primary, two things happen:

1. **The primary gets throttled.** Active geo-replication reduces the primary's transaction log rate to let the secondary keep up. You'll see the `HADR_THROTTLE_LOG_RATE_MISMATCHED_SLO` wait type in `sys.dm_exec_requests`.
2. **Post-failover performance suffers.** The new primary (formerly the undersized secondary) won't handle the full workload. Scaling up takes time and triggers an internal HA failover.

Match your secondary's compute to the primary's, and match your backup storage redundancy too. Backup retention policies aren't replicated — the geo-secondary defaults to 7 days of PITR retention, so set it explicitly.

### Security Configuration for Geo-Replicas

Geo-replication creates a copy of your data, but it doesn't replicate everything needed to connect to it. Before a failover event, you need the secondary server ready:

**Contained database users** are the simplest path. Because credentials live inside the database, they replicate automatically with the data. After failover, users can connect without any extra work on the secondary.

**Server-level logins** require manual setup. You must create matching logins with identical SIDs on the secondary server's `master` database before a failover happens:

```sql
-- On the primary, find the SID for each login
SELECT [name], [sid]
FROM sys.sql_logins
WHERE type_desc = 'SQL_Login';

-- On the secondary server, create the login with the same SID
CREATE LOGIN [app_user]
WITH PASSWORD = '<strong-password>',
SID = 0x1234ABCD; -- Use the SID from the primary
```
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/active-geo-replication-security-configure.md -->

**Database-level IP firewall rules** replicate with the database automatically. Server-level firewall rules don't — you must configure them on both servers.

> **Tip:** Prefer contained database users for geo-replicated databases. They eliminate an entire category of post-failover access problems.

### Geo-Replication for Rolling Upgrades

Active geo-replication isn't just for disaster recovery. You can use it to perform zero-downtime application upgrades:

1. Create a geo-secondary of your production database.
2. Set the primary to read-only mode.
3. Disconnect the secondary (planned termination) — it becomes an independent copy.
4. Run your schema migration and upgrade scripts on the disconnected copy.
5. Swap your application endpoints to point at the upgraded database.

If the upgrade fails, your original primary is untouched. Delete the failed copy and try again. This is far safer than running migrations directly against your production database.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/manage-application-rolling-upgrade.md -->

### Monitoring Replication Lag

Use `sys.dm_geo_replication_link_status` on the primary to track how far behind each secondary is:

```sql
SELECT
    partner_server,
    partner_database,
    replication_lag_sec,
    last_replication,
    replication_state_desc
FROM sys.dm_geo_replication_link_status;
```

The `replication_lag_sec` column shows the lag in seconds between transactions committed on the primary and hardened on the secondary. This is your real-time RPO indicator. If the primary fails right now, you lose that many seconds of data.

> **Gotcha:** If `replication_lag_sec` returns `NULL`, the primary doesn't know how far behind the secondary is. This is usually transient after a process restart, but if it persists, the secondary might have a connectivity issue.

### Preventing Data Loss on Critical Transactions

If certain transactions absolutely cannot be lost — financial settlements, for example — call `sp_wait_for_database_copy_sync` immediately after committing:

```sql
BEGIN TRANSACTION;
    -- Critical financial operation
    UPDATE accounts SET balance = balance - 1000 WHERE account_id = 42;
    INSERT INTO audit_log (account_id, action, amount) VALUES (42, 'withdrawal', 1000);
COMMIT TRANSACTION;

EXEC sp_wait_for_database_copy_sync;
```

This blocks the calling thread until the committed transaction is hardened on the secondary. It adds latency — potentially significant latency on a busy primary — so use it only for transactions where data loss is genuinely unacceptable.

## Failover Groups

If active geo-replication is the building block, **failover groups** are the finished product. A failover group manages replication and failover for a set of databases as a coordinated unit, and — crucially — provides stable DNS listener endpoints that don't change after failover.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/failover-group-sql-db.md -->

Under the hood, failover groups use active geo-replication. The difference is the abstraction layer on top: coordinated multi-database failover, automatic DNS-based endpoint redirection, and configurable failover policies.

### DNS Listener Endpoints

Every failover group creates two DNS endpoints:

| Endpoint | DNS pattern (SQL Database) | Routes to |
|---|---|---|
| Read-write | `<fog-name>.database.windows.net` | Current primary |
| Read-only | `<fog-name>.secondary.database.windows.net` | Current secondary |

After a failover, the DNS records update automatically. Your application doesn't need to change connection strings or detect which server is primary — the listener handles it. The DNS TTL is 30 seconds, so clients pick up the change quickly once their local DNS cache refreshes.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/failover-group-sql-db.md -->

> **Important:** The failover group name must be globally unique within the `.database.windows.net` domain.

Use the read-write listener for your OLTP workloads and the read-only listener for reporting. If you're using the read-only listener, add `ApplicationIntent=ReadOnly` to your connection string to route to a read-only replica.

### Customer-Managed vs. Microsoft-Managed Failover Policies

Failover groups support two policies:

**Customer-managed (recommended)** — you decide when to fail over. When you detect that your databases are unavailable and the outage exceeds your tolerance, you initiate the failover yourself. This keeps you in control of timing and scope. In CLI and API calls, this is the `manual` policy value.

**Microsoft-managed** — Microsoft initiates failover during widespread regional outages, after a configurable grace period (minimum one hour). When triggered, *all* failover groups in the region with this policy fail over — you can't selectively fail over individual groups.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/failover-group-sql-db.md -->

> **Warning:** Don't rely on Microsoft-managed failover as your primary DR strategy. It only fires in extreme circumstances, applies to all groups in the region at once, and comes with an RTO of at least one hour. Use customer-managed failover and build your own detection and response process.

The `GracePeriodWithDataLossHours` parameter on a Microsoft-managed policy controls how long the service waits before triggering forced failover. Set it to match your application's tolerance for data loss — but remember that actual failover timing can vary significantly beyond the grace period.

### Failover Groups for SQL Database

For SQL Database, a failover group spans two logical servers — a primary and a secondary in different regions. You choose which databases to include. Key behaviors:

- **Adding a single database** creates a geo-secondary automatically on the secondary server with matching edition and compute size.
- **Adding databases in an elastic pool** creates secondaries in a pool of the same name on the secondary server. The secondary pool must already exist with enough capacity.
- **Multiple failover groups** can exist on the same pair of servers. Each group fails over independently, which lets you control blast radius in multi-tenant designs.

> **Gotcha:** Elastic pools with 800 or fewer DTUs or 8 or fewer vCores and more than 250 databases can experience longer planned geo-failovers and degraded performance. This is especially true for write-intensive workloads with geographically distant replicas.

**Initial seeding** is the slowest part. Under normal conditions, SQL Database can seed at up to 500 GB per hour. All databases in the group seed in parallel. Until seeding completes, you can't fail over.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/failover-group-sql-db.md -->

### Failover Groups for Managed Instance

Managed Instance failover groups work differently in several important ways:

- A failover group contains **all user databases** on the instance. You can't selectively include a subset.
- The primary and secondary instances must share a **DNS zone**. When creating the secondary instance, you specify the primary as the DNS zone partner. This is required because a multi-domain (SAN) certificate is provisioned per DNS zone — if the instances are in different zones, the failover group's listener endpoints can't authenticate client connections to both instances with the same certificate, and failover breaks.
- **System databases aren't replicated.** Logins, agent jobs, and anything in `master` or `msdb` must be manually synchronized to the secondary.
- The listener DNS patterns include a zone ID: `<fog-name>.<zone_id>.database.windows.net` for read-write and `<fog-name>.secondary.<zone_id>.database.windows.net` for read-only.
- **Global VNet peering** is the recommended connectivity method between primary and secondary instances. It provides the lowest latency and highest bandwidth over the Microsoft backbone.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/business-continuity/failover-group-sql-mi.md -->

> **Gotcha:** The listeners for Managed Instance failover groups can't be reached via the public endpoint. You must use private connectivity.

Seeding speed for Managed Instance is up to 360 GB per hour under normal conditions with VNet peering. If you're using VPN gateways instead, expect significantly slower seeding.

> **Gotcha:** Creating a failover group times out automatically after six days if seeding isn't complete. For large instances on slower connectivity, verify seeding progress early.

```sql
-- On the secondary Managed Instance, create logins with matching SIDs
CREATE LOGIN [app_login] WITH PASSWORD = '<strong-password>',
SID = <login_sid_from_primary>;
```

Keep agent jobs, linked servers, credentials, and any other `master`/`msdb` objects synchronized manually. This is operational overhead that doesn't exist with SQL Database failover groups.

### License-Free Standby Replicas

If your secondary is used *only* for DR — no read workloads, no connections — you can designate it as a **standby replica** to eliminate SQL Server licensing costs on the secondary. You still pay for compute and storage, but the vCore license discount is significant.
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/standby-replica-how-to-configure.md -->

For SQL Database, standby replicas are supported on provisioned single databases (General Purpose, Business Critical) but not on serverless or elastic pools. For Managed Instance, the entire secondary instance can be designated as standby.

The standby replica supports only limited operations: DBCC checks, monitoring connections, backup validation, and DR drills. During a failover — planned or unplanned — the standby becomes a full primary and starts incurring regular licensing costs. The original primary becomes the new standby.

| Standby support | SQL Database | Managed Instance |
|---|---|---|
| Provisioned single DB | Yes | N/A (instance-level) |
| Hyperscale | No | N/A |
| Serverless | No | N/A |
| Elastic pool | No | N/A |
| Instance-level | N/A | Yes |

## DR Design Patterns

The mechanisms above give you the building blocks. The question is how to assemble them into an architecture that meets your RTO and RPO targets.

### Choosing Between Geo-Replication and Failover Groups

| Consideration | Geo-replication | Failover groups |
|---|---|---|
| Stable endpoint after failover | No | Yes |
| Multi-DB coordinated failover | No | Yes |
| Multiple secondaries | Up to 4 | 1 (multiple in preview) |
| Same-region secondary | Yes | No |
| Selective DB failover | Yes | Yes (SQL DB) / No (MI) |

**Use failover groups** for most production DR scenarios. The DNS listener endpoints alone justify the choice — they eliminate the need to update connection strings after failover. Use active geo-replication when you need same-region read replicas, more than one secondary, or per-database failover granularity that failover groups don't support.

### Decision Framework: RTO/RPO → Mechanism Selection

Your RTO and RPO targets determine which DR mechanism to deploy:

| RTO target | RPO target | Mechanism |
|---|---|---|
| < 60 s | Near-zero | Failover group (customer-managed) |
| < 60 s | Near-zero | Active geo-replication |
| Minutes–hours | Minutes–hours | Geo-restore |
| Hours | Zero (within backup) | Point-in-time restore |

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/business-continuity-high-availability-disaster-recover-hadr-overview.md -->

Geo-restore is the fallback when you haven't configured geo-replication or failover groups. It restores from geo-replicated backups and is available at no additional cost, but recovery time depends on database size and can stretch to hours.

### Multi-Region DR with Traffic Manager

A failover group handles the database layer. You still need to redirect application traffic. The standard pattern uses Azure Traffic Manager (or Azure Front Door) with priority routing:

1. Deploy your application stack in two regions — an active primary and a warm standby.
2. Configure a failover group between SQL Database servers (or Managed Instance instances) in the two regions.
3. Point your app in both regions at the failover group's read-write listener: `<fog-name>.database.windows.net`.
4. Set up Traffic Manager with priority routing — primary region gets all traffic, secondary is the backup.
5. During an outage, fail over the database (failover group handles DNS). Traffic Manager detects the primary region's app health degradation and routes users to the secondary.

Because both application instances use the failover group listener, neither needs a connection string change. The database and application fail over independently but converge on the same region.

> **Tip:** After failover, other Azure services in the original region may still be running. This means cross-region latency between your app (now in the DR region) and services still in the primary region. Design for full-stack regional failover — not just the database.

### Elastic Pool DR Strategies for Multi-Tenant SaaS

Multi-tenant SaaS applications that use elastic pools have unique DR considerations (for tenancy pattern details, → see Chapter 17):

**Cost-sensitive startups:** Use geo-restore for tenant databases and a failover group only for management databases. Tenant recovery is slower (geo-restore is a size-of-data operation), but ongoing DR cost is minimal.

**Tiered-service applications:** Geo-replicate paying tenant pools for fast failover. Use geo-restore for free-tier tenants. This matches DR investment to revenue — paying customers get sub-minute RTO, trial users get slower recovery.

**Geo-distributed applications:** Split paid tenant primaries across two regions (50/50). Each region holds secondaries for the other region's primaries. An outage in either region impacts at most half your paid tenants, and failover is immediate for those affected.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/disaster-recovery-strategies-for-applications-with-elastic-pool.md -->

## Outage Response

When an outage hits, you need a decision framework — not a frantic scramble through documentation.

### Detecting Service Outages

Monitor for outages through multiple channels:

- **Azure Service Health** — the portal shows active service issues and affected regions. Configure alerts to get proactive email notifications.
- **Resource Health** — per-resource health status, accessible from any resource's Help menu. This tells you whether *your specific database* is affected, not just the region.
- **The Availability metric** — Azure SQL Database exposes an availability metric you can use to set up Azure Monitor alerts.
- **Application-level monitoring** — your application's retry logic and health checks will detect connectivity failures before any Azure notification arrives.

### Deciding When to Initiate Failover

Not every outage warrants failover. The escalation decision depends on your RTO:

**Wait for recovery** if your application can tolerate the downtime and the outage seems transient. Azure teams often restore service faster than you can execute a failover, especially for localized issues.

**Initiate failover** when the outage duration approaches your RTO and your business can't absorb more downtime. Remember that failover itself has costs: potential data loss (with forced failover), DNS propagation time, and application reconfiguration.

Build concrete thresholds into your runbook so the decision isn't ad-hoc under pressure:

- **Monitoring triggers:** Set Azure Monitor alerts on the Availability metric with a threshold below 90% sustained for 5+ minutes. Pair this with Resource Health alerts that fire on `Unavailable` status. When both fire simultaneously, it's time to start the escalation clock.
- **Communication protocol:** Designate an on-call DBA or SRE as the failover decision-maker. When alerts fire, they assess scope (single database vs. region-wide), confirm with Azure Service Health, and decide within a documented time window — typically 10–15 minutes for customer-managed failover policies.
- **DNS-based routing (Traffic Manager / Front Door):** If you're using Traffic Manager or Azure Front Door, database failover and traffic routing happen independently. Verify that both converge on the DR region before declaring recovery complete.
- **Non-DNS routing:** If your app tier doesn't use DNS-based routing, include explicit runbook steps for repointing application instances or triggering an app-tier deployment in the DR region. Failing over the database alone isn't enough if the application is still pointed at the downed region.

### Recovery Escalation Ladder

Work through these steps in order, escalating only as needed:

1. **Wait for Azure to resolve.** Data loss risk: none. Escalate when the outage duration approaches your RTO and you can't afford more downtime.
2. **Planned failover (failover group).** Data loss risk: none. Escalate when the primary isn't responding and the planned failover times out or can't initiate.
3. **Forced failover (failover group).** Data loss risk: possible — unreplicated transactions are lost. Escalate when forced failover fails or no failover group is configured.
4. **Forced failover (geo-replication).** Data loss risk: possible. Escalate when no geo-replication is configured either.
5. **Geo-restore from backup.** Data loss risk: hours of data and hours of downtime. This is the last resort.

At each step, check whether the primary's status is **Online** in the portal. If it is, try a planned failover first — it ensures zero data loss. Only escalate to forced failover when the primary is unreachable or planned failover fails.

### Post-Failover Checklist

After failing over, run through this checklist before declaring the application recovered:

- **Connection strings:** If using active geo-replication (not failover groups), update your app to point at the new primary server.
- **Firewall rules:** Verify that the secondary server's firewall rules match what your application needs.
- **Logins and users:** Confirm that all required logins exist on the new primary with correct SIDs and permissions.
- **Alert rules:** Update monitoring alerts to target the new primary server and database.
- **Auditing:** Ensure auditing configuration on the new primary matches your compliance requirements.
- **Backup retention:** Verify PITR and LTR policies on the new primary — they don't replicate from the old primary.

## DR Drills

You don't know if your DR plan works until you test it. Run drills regularly — quarterly at minimum.

### Geo-Restore Drill

1. Create a test environment (don't use production endpoints).
2. Rename the source database to simulate an outage (this breaks application connectivity).
3. Perform a geo-restore to a different server.
4. Validate application connectivity, logins, data integrity, and functionality against the restored database.
5. Clean up the test resources.

### Failover Group Drill

1. Initiate a **planned failover** to the secondary server. Planned failover ensures full data synchronization first — no data loss, safe for production.
2. Validate that the application reconnects through the listener endpoints.
3. Test read-write and read-only workloads.
4. Fail back to the original primary by initiating another planned failover.

> **Warning:** Don't use forced failover for DR drills unless you've stopped the workload, drained all connections, and confirmed the failover group replication state is `Synchronizing`.

For Managed Instance, allow time for DNS propagation and verify that the instance has fully switched roles. The DNS update happens immediately when failover is initiated, but the actual database role switch can take up to five minutes.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/disaster-recovery/disaster-recovery-drills.md -->

## HA/DR Readiness Checklist

This consolidated checklist covers SQL Database, Managed Instance, and VMs. Treat it as a pre-production gate.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-disaster-recovery-checklist.md, azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/high-availability-disaster-recovery-checklist.md -->

### Availability

- [ ] Retry logic in application code for transient faults
- [ ] Maintenance windows configured (not the default) to make maintenance predictable
- [ ] Application fault resiliency tested by triggering a manual HA failover

### High Availability

- [ ] Zone redundancy enabled where available (SQL Database and Managed Instance)

### Disaster Recovery (SQL Database)

- [ ] Failover group configured with customer-managed failover policy
- [ ] Read-write and read-only listener endpoints used in connection strings
- [ ] Geo-secondary matches primary's service tier, compute tier, and compute size
- [ ] Scale-up order: secondary first, then primary. Scale-down order: primary first, then secondary
- [ ] `sp_wait_for_database_copy_sync` called for zero-loss-critical transactions
- [ ] `replication_lag_sec` monitored via `sys.dm_geo_replication_link_status`
- [ ] Backup storage redundancy set to geo-redundant if no failover group or geo-replication
- [ ] DR drills scheduled and executed regularly

### Disaster Recovery (Managed Instance)

- [ ] Failover group configured with customer-managed failover policy
- [ ] Listener endpoints used in connection strings
- [ ] Secondary instance in same DNS zone as primary
- [ ] Logins, agent jobs, and system database objects synchronized to secondary
- [ ] VNet peering or VPN configured between primary and secondary subnets
- [ ] Secondary instance matches primary's service tier and compute size
- [ ] Backup storage redundancy set to geo-redundant if no failover group
- [ ] DR drills scheduled and executed regularly

### Disaster Recovery (SQL Server on VMs)

- [ ] Availability group with cross-region async replica configured
- [ ] Or log shipping, backup/restore to Blob Storage, or Azure Site Recovery configured
- [ ] Secondary region domain controller deployed
- [ ] VPN or ExpressRoute connectivity between regions verified

### Prepare the Secondary

- [ ] Firewall rules / NSG rules configured on secondary server/instance
- [ ] Logins created on secondary with matching SIDs
- [ ] Alert rules ready to remap to new primary
- [ ] Auditing configuration duplicated on secondary
- [ ] Runbook documented and tested end-to-end

## Cross-Region Migration

Sometimes you need to move databases to a new region — not because of a disaster, but for latency, compliance, or cost reasons. Failover groups provide the cleanest path.

### SQL Database

1. Create a failover group with the secondary server in the target region.
2. Wait for initial seeding to complete.
3. Monitor replication lag until it's near zero.
4. Initiate a planned failover — zero data loss, automatic DNS update.
5. Remove the old server from the failover group, then delete the failover group.
6. Clean up the old server if it's no longer needed.

### Managed Instance

The process is similar, but remember that *all* user databases migrate together (failover groups for MI are instance-scoped). Plan for the full data set, and ensure VNet peering between the source and target regions is established before creating the failover group.

After migration, update any hardcoded references to the old instance endpoint. If you were using failover group listeners, your application doesn't need changes.

## SQL Server VM DR Options

SQL Server on Azure VMs uses the same DR technologies as on-premises SQL Server — you're responsible for configuring and managing them.

### Cross-Region Availability Group Replicas

Extend your Always On availability group with an **asynchronous replica** in a different region. This is the most common VM DR pattern:

- Create an Azure VM in the DR region running the same SQL Server version.
- Add it to the existing availability group as an async-commit replica.
- Cross-region replicas require VNet-to-VNet connectivity (VPN gateway or ExpressRoute).
- Failover to the async replica is manual and can involve data loss — the same tradeoff as forced failover in SQL Database geo-replication.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/business-continuity-high-availability-disaster-recovery-hadr-overview.md -->

> **Tip:** With Software Assurance or pay-as-you-go licensing in Azure, passive DR replicas qualify for free licensing under the HA/DR benefit. Set the license type to **HA/DR** in the SQL Server VM resource settings.

### Log Shipping

Log shipping automatically sends transaction log backups from a primary to one or more secondary servers. It's simpler than availability groups but offers less automation:

- Configure an Azure File Share to store transaction log backup files.
- Set up log shipping jobs on the primary and each secondary.
- RPO depends on your backup frequency. RTO is the time to restore and apply logs.

Log shipping is a solid choice when you need DR for a SQL Server VM but don't want the complexity of availability groups or when you need to ship to a lower SQL Server edition.

### Backup and Restore to Blob Storage

The simplest DR option: back up directly to Azure Blob Storage in a different region using `BACKUP TO URL`. In a disaster, restore from the backups onto a new VM.

This gives you the largest RPO (since your last backup) and the longest RTO (provisioning a VM plus restore time), but it works and costs almost nothing beyond storage.

### Azure Site Recovery

Azure Site Recovery replicates the entire VM — OS, SQL Server binaries, data files — to a secondary region. In a disaster, you fail over the VM itself.

This is a lift-and-shift DR approach. It's simple to configure but doesn't give you the granularity of database-level recovery, and it doesn't let you offload read workloads to the secondary. Use it when you need DR for the whole VM stack and don't want to configure SQL Server-level replication.

The next chapter shifts from keeping your databases alive to understanding how they perform. Chapter 14 covers monitoring and observability — the metrics, DMVs, and diagnostic tools that tell you what your Azure SQL workloads are actually doing.
