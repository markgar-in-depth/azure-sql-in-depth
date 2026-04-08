# Chapter 12: High Availability

Your database is always one failure away from an outage. A disk dies, a rack loses power, an entire availability zone goes dark. The question isn't *whether* something will fail — it's whether your architecture keeps serving requests when it does.

Azure SQL has high availability baked in, but "baked in" doesn't mean "one size fits all." The HA architecture varies dramatically by service tier. Your choices around zone redundancy and maintenance windows determine whether a failure is a non-event or a 3 AM page. This chapter breaks down the three HA models, shows you how to harden them with zone redundancy, and covers the maintenance events that cause most of the "downtime" you'll actually experience.

## Availability Architectures

Every Azure SQL Database, Managed Instance, and SQL Server VM needs an answer to the same question: what happens when the node running your database goes away? The three managed service tiers answer it differently.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### The Remote Storage Model (General Purpose)

General Purpose — and its DTU equivalents, Basic and Standard — separates compute from storage. Your data files (`.mdf` and `.ldf`) live in Azure Blob Storage, not on the machine running the database engine. The compute node is stateless: it holds `tempdb`, plan cache, buffer pool, and columnstore pool in memory, but the durable data is elsewhere.

When a compute node fails, Azure Service Fabric spins up a new one and reattaches the storage. Your data is never at risk because Azure Blob Storage replicates it three times within the datacenter (locally redundant storage). But the new process starts with a cold cache, so you'll feel a performance dip until it warms up.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

The tradeoff is clear: General Purpose is cheaper, but failovers are slower and read-heavy workloads hit cold cache harder. There's no built-in read scale-out — the secondary replicas don't exist in this model.

> **Important:** Managed Instance also offers a **Next-gen General Purpose** tier that replaces Azure Blob Storage with Elastic SAN for the storage layer. The HA model is similar — compute is still stateless and failover still means reattaching storage — but I/O performance is significantly better. Zone redundancy isn't available for Next-gen General Purpose.

### The Local Storage Model (Business Critical)

Business Critical — and its DTU equivalent, Premium — co-locates compute and storage on the same node. Each node has locally attached SSDs holding the data and log files, which means sub-millisecond I/O latency for your workload.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

Availability comes from replication. The service maintains a cluster of up to four nodes: one primary and up to three secondary replicas. The primary pushes every transaction to the secondaries before committing, using a technology similar to SQL Server Always On availability groups. If the primary dies, Service Fabric promotes a secondary that already has a complete copy of the data. Failover is fast, and the new primary starts with a warm cache.

This architecture gives you two things General Purpose doesn't:

1. **Minimal performance impact during failover.** The promoted secondary already has your data cached locally.
2. **Read Scale-Out.** You can route read-only connections to a secondary replica by adding `ApplicationIntent=ReadOnly` to your connection string. This offloads analytics and reporting workloads at no extra cost — the secondary replicas are already there for HA.

> **Tip:** Read Scale-Out is enabled by default on Business Critical and Premium databases. If your SQL connection string includes `ApplicationIntent=ReadOnly`, the connection goes to a secondary replica. To verify, run `SELECT DATABASEPROPERTYEX(DB_NAME(), 'Updateability')` — it returns `READ_ONLY` when you're on a secondary.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/read-scale-out.md -->

> **Gotcha:** Reads from a read-only replica are always asynchronous with respect to the primary — there's no fixed upper bound on propagation latency. However, *within* a single session connected to a read-only replica, reads are always transactionally consistent. The trap: don't write to the primary and immediately read from a secondary expecting to see that write. The data will get there, but you can't predict when.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/read-scale-out.md -->

### The Hyperscale Model

Hyperscale takes a fundamentally different approach. Instead of one storage layer, it distributes availability across four:

| Layer | Role | Redundancy |
|---|---|---|
| Compute | Runs the engine | Stateless; Service Fabric failover |
| Page servers | Distributed storage | Active-active pairs |
| Log service | Transaction log | Landing zone + Azure Storage |
| Data storage | `.mdf`/`.ndf` files | Azure Storage redundancy |

Each layer fails independently and recovers independently. A page server going down doesn't take out your compute, and a compute node failure doesn't touch the log service.

Hyperscale also supports read scale-out through HA replicas and named replicas (covered in detail in Chapter 10). The key distinction: HA replicas participate in automatic failover, while named replicas are independently sized read endpoints that don't.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### Local Redundancy vs. Zone Redundancy

By default, all three models use **local redundancy**: replicas live within a single datacenter. This protects against node-level and rack-level failures but not against an entire availability zone going down. If the datacenter itself has an issue, your only recovery path is a disaster recovery mechanism like failover groups or geo-restore.

**Zone redundancy** spreads replicas across two or three availability zones within a region — physically separate locations with independent power, cooling, and networking. This is the difference between "a server failed" and "a datacenter failed," and it's the leap from availability to *high* availability.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### SLA Implications

The SLA you get depends on the tier and whether zone redundancy is enabled. The exact percentages are published in Microsoft's SLA documents and can change, but the pattern is consistent: Business Critical and Premium with zone redundancy offer the highest SLAs, while Basic and Standard (which don't support zone redundancy) offer lower ones.

| Service Tier | Zone Redundancy | Relative SLA |
|---|---|---|
| Basic / Standard (DTU) | Not available | Lowest |
| General Purpose (vCore) | Optional | Higher when enabled |
| Premium (DTU) | Optional | Higher when enabled |
| Business Critical (vCore) | Optional | Highest when enabled |
| Hyperscale (vCore) | Optional | Higher when enabled |

> **Tip:** Check the current SLA numbers for your tier at the [Azure SQL Database SLA page](https://azure.microsoft.com/support/legal/sla/azure-sql-database). SLA guarantees apply only when zone redundancy is enabled for tiers that support it.

## Zone Redundancy

Zone redundancy is the single most impactful HA setting you can toggle. It's also one of the most misunderstood — developers often assume it's enabled by default, or that it's only available on expensive tiers.

### SQL Database: Single and Pooled

Zone redundancy is available on the following SQL Database tiers:
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/enable-zone-redundancy.md -->

| Service Tier | Zone Redundancy |
|---|---|
| General Purpose (vCore) | ✅ Supported |
| Business Critical (vCore) | ✅ Supported |
| Hyperscale (vCore) | ✅ Supported |
| Premium (DTU) | ✅ Supported |
| Basic (DTU) | ❌ Not available |
| Standard (DTU) | ❌ Not available |

For **General Purpose**, zone redundancy places the stateless compute in one availability zone and stores data on zone-redundant storage (ZRS), which synchronously replicates across multiple zones. On failover, a standby compute node in a different zone picks up the ZRS-backed data files.

For **Business Critical and Premium**, zone redundancy distributes the Always On replicas across different availability zones. Because those replicas already exist for local HA, enabling zone redundancy doesn't add extra replicas — it just spreads them geographically. See "Cost and Latency Considerations" below for the pricing implications.

For **Hyperscale**, zone redundancy spans all layers of the architecture; see "Hyperscale Zone Redundancy" below for details.

Enabling zone redundancy on an existing General Purpose, Business Critical, or Premium database is an **online operation** with only a brief disconnect at the end — standard retry logic handles it. Use the portal, PowerShell, or CLI:

```azurecli
az sql db update \
  --resource-group "myRG" \
  --server "myServer" \
  --name "myDB" \
  --zone-redundant
```
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/enable-zone-redundancy.md -->

> **Gotcha:** Hyperscale zone redundancy can only be set at database creation time. You can't toggle it on an existing Hyperscale database. To add zone redundancy to an existing Hyperscale database, you need to create a new zone-redundant database via database copy, point-in-time restore, or geo-replica, then switch over.
<!-- Source: azure-sql-database-sql-db/how-to/business-continuity/enable-zone-redundancy.md -->

When you enable zone redundancy on a SQL Database logical server, the `master` database automatically becomes zone-redundant too. This matters because `master` hosts logins and firewall rules — without a zone-redundant `master`, a zone failure could prevent all authentication to the server, even if your user databases survived the outage.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### Managed Instance

Zone redundancy for SQL Managed Instance works the same conceptual way: General Purpose gets zone-redundant storage, Business Critical gets cross-zone replicas.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

There's one prerequisite specific to Managed Instance: your **backup storage redundancy** must be set to zone-redundant or geo-zone-redundant before you can enable zone redundancy on the instance. Backups have to be configured first.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/instance-zone-redundancy-configure.md -->

```azurecli
# Create a new zone-redundant managed instance
az sql mi create \
  --resource-group "myRG" \
  --name "myMI" \
  --zone-redundant true \
  --backup-storage-redundancy Zone
```

Enabling or disabling zone redundancy on an existing managed instance is a fully online scaling operation. Zone redundancy isn't available for the Next-gen General Purpose service tier.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/instance-zone-redundancy-configure.md -->

### Hyperscale Zone Redundancy

For Hyperscale, zone redundancy ensures every layer of the architecture — compute, page servers, log service, and persistent storage — is spread across availability zones. The requirement is at least one HA replica plus zone-redundant backup storage.

Because Hyperscale zone redundancy is immutable after creation, plan for it from the start. If you're migrating a database to Hyperscale, you can specify zone redundancy during the tier change via Azure CLI:

```azurecli
az sql db update \
  --resource-group "myRG" \
  --server "myServer" \
  --name "myDB" \
  --edition Hyperscale \
  --zone-redundant true
```
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### Cost and Latency Considerations

For SQL Database, zone redundancy on Business Critical and Premium doesn't cost extra — those replicas already exist, and you're just relocating them across zones. On General Purpose, the shift from LRS to ZRS storage may have a modest cost impact, but it's typically small. For Managed Instance, both General Purpose and Business Critical incur a zone-redundancy add-on charge.

If you're using **Azure Reservations**, be aware that zone-redundant General Purpose (SQL Database) and zone-redundant General Purpose or Business Critical (Managed Instance) incur a separate zone-redundancy add-on charge. Your standard **vCore** reservation doesn't cover it — you need a second reservation of type **vCore ZR** to discount the add-on. Plan for both reservation types when budgeting zone-redundant deployments.
<!-- Source: shared-sql-db-sql-mi-docs/billing-options/reservations-discount-overview.md -->

The real cost is latency. Replicas in different zones have more network distance between them. For Business Critical, this means slightly higher commit latency because the primary must wait for synchronous acknowledgment from cross-zone secondaries. For most OLTP workloads, the impact is negligible. For ultra-low-latency workloads, test under load before committing.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

## Planned Maintenance and Maintenance Windows

Here's a secret that most HA conversations skip: the majority of brief disruptions your database experiences aren't from hardware failures. They're from **planned maintenance** — the continuous stream of OS patches, SQL engine upgrades, and platform updates that keep the service running.

### Reconfiguration Behavior

During planned maintenance, replicas go offline one at a time. For Business Critical and Premium, the secondary replicas take over without client downtime. For General Purpose, Standard, and Basic, the primary moves to a different compute node with free capacity, which triggers a brief reconfiguration.
<!-- Source: resources/service-updates/planned-maintenance.md -->

On average, a planned maintenance event produces 1.7 reconfigurations, and each reconfiguration finishes within about 30 seconds (average: 8 seconds). During reconfiguration:
<!-- Source: resources/service-updates/planned-maintenance.md -->

- Existing connections drop and must reconnect.
- New connections get error 40613: *"Database is not currently available."*
- Long-running queries are interrupted and must restart.

If your application has proper retry logic, most users won't notice. If it doesn't, every maintenance event looks like an outage.

### Choosing a Maintenance Window

By default, Azure SQL blocks most impactful maintenance during **8 AM to 5 PM local time** — protecting typical business hours. The system default window of 5 PM to 8 AM handles most updates, but urgent patches can still land outside it.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md -->

To guarantee that *all* planned maintenance happens within a specific window, choose a non-default option:

| Window | Schedule |
|---|---|
| Weekday | 10 PM – 6 AM, Mon–Thu |
| Weekend | 10 PM – 6 AM, Fri–Sun |

The start day is when the 8-hour window begins. "Monday–Thursday" means maintenance starts at 10 PM Monday and could run until 6 AM Tuesday, and so on through Thursday night into Friday morning.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md -->

Maintenance windows are free and available on most service tiers. The exceptions:

- **Not supported:** DTU Basic, S0, S1, DC hardware, Fsv2 hardware
- **Managed Instance:** Available on all SLOs except instance pools
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md, azure-sql-managed-instance-sql-mi/concepts/scheduled-maintenance/maintenance-window.md -->

> **Tip:** If you're using geo-replication or failover groups across non-paired regions, assign different maintenance windows to primary and secondary. Use **Weekday** for one and **Weekend** for the other. This way, they won't both get patched at the same time.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md -->

### Advance Notifications

Once you configure a non-default maintenance window, you can enable **advance notifications** through Azure Service Health. You'll get alerts 24 hours before maintenance starts, when it begins, and when it completes. Notifications support email, SMS, Azure push notifications, and voice.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/advance-notifications.md -->

> **Important:** Advance notifications require a non-default maintenance window. If you're using the system default, you can't enable them.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/advance-notifications.md -->

To set up advance notifications, create a Service Health alert in the Azure portal with **Planned maintenance** as the event type, scoped to the Azure SQL Database or SQL Managed Instance service and your region.

### Retry Logic During Maintenance

Every application connecting to Azure SQL should implement retry logic for transient errors. This isn't optional advice — it's the foundation of reliable cloud database access.

During a reconfiguration, the database engine process restarts or moves to a new node. Connections drop and queries in flight fail. Your retry logic should:

1. **Catch transient errors** — error 40613 (database unavailable), 40197 (service error), and connection timeout errors.
2. **Wait briefly before retrying** — start with 1–2 seconds, then back off exponentially.
3. **Use the redirect connection policy** in Azure SQL Database. Redirect connections go directly to the node hosting the database, bypassing the gateway. This means gateway maintenance doesn't affect your connections at all.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md -->

> **Gotcha:** The maintenance window only protects against *planned* maintenance. Hardware failures, cluster rebalancing, and reconfigurations from service tier changes can still cause brief interruptions outside the window.
<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md -->

## SQL Server VM High Availability

When you run SQL Server on Azure VMs, you leave the PaaS world behind. There's no built-in HA — you build it yourself using the same Windows Server Failover Clustering (WSFC) technologies you'd use on-premises, adapted for Azure's networking and storage model.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

### Windows Server Failover Clustering on Azure VMs

WSFC is the foundation of both availability groups and failover cluster instances. The cluster service monitors node health through heartbeats and initiates failover when a node or resource becomes unhealthy.

On Azure, there's an important nuance: the cluster needs tuning for cloud. Default WSFC heartbeat thresholds are calibrated for on-premises networks with sub-millisecond latency. In Azure, transient network blips are more common, and Azure platform maintenance can pause a VM for up to 30 seconds (memory-preserving maintenance). Aggressive cluster settings will interpret these pauses as node failures and trigger unnecessary failovers.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

> **Important:** Use **relaxed monitoring** settings for WSFC on Azure VMs. Aggressive settings cause premature failovers that result in longer outages than the transient event that triggered them. Follow the Azure-specific cluster best practices for heartbeat thresholds and health check timeouts.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

**Quorum** is the other critical configuration. Every production cluster needs a quorum witness:
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

| Witness Type | Best For |
|---|---|
| Cloud witness | Most deployments; uses Azure Storage |
| Disk witness | FCIs with Azure shared disks |
| File share witness | When cloud/disk aren't available |

Use a cloud witness whenever possible — it's simple, cheap, and region-independent. A disk witness makes sense only when you're already using Azure shared disks for FCI storage.

### Always On Availability Groups

Availability groups (AGs) are the workhorse of SQL Server HA on Azure VMs. An AG replicates one or more databases from a primary replica to one or more secondary replicas. Each replica runs on its own VM with its own storage.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

**Synchronization modes** determine the tradeoff between data safety and performance:

- **Synchronous commit** — the primary waits for the secondary to harden the log before committing. Zero data loss on failover, but latency increases with network distance.
- **Asynchronous commit** — the primary commits without waiting. Lower latency, but the secondary can lag behind, meaning potential data loss on forced failover.

For HA within a region, use synchronous commit with automatic failover. For DR across regions, add an asynchronous replica — the latency across hundreds of miles makes synchronous commit impractical for most workloads.

**Cross-region replicas** deserve a brief mention here. An asynchronous secondary in a different Azure region gives you a warm standby for disaster recovery — if the entire primary region goes down, you can force a manual failover to the remote replica. You'll lose any transactions that hadn't propagated, but the database will be online. Chapter 13 covers DR architecture in detail; for now, know that cross-region async replicas are the AG-based equivalent of failover groups for the PaaS tiers.

**Connectivity** is where Azure AGs diverge from on-premises. On-premises, the AG listener uses gratuitous ARP to update network routing on failover. Azure doesn't allow ARP broadcasts, so you need an alternative.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

The best option: **deploy VMs across multiple subnets**. See the "Anti-Pattern: Single-Subnet AG with Load Balancer" section below for the full rationale.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

If you're stuck in a single subnet, you have two options:

| Approach | Pros | Cons |
|---|---|---|
| Azure Load Balancer (VNN) | Works with all versions | Adds failover delay; extra resource |
| Distributed Network Name (DNN) | Faster failover; no LB cost | SQL 2016 SP3+ / 2017 CU25+ / 2019 CU8+ |

DNN is recommended over load balancers when your SQL Server version supports it. The DNN creates a DNS entry pointing to all cluster nodes, and clients with `MultiSubnetFailover=True` try all IPs in parallel for instant connection.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

> **Tip:** Always set `MultiSubnetFailover=True` in your connection strings for both multi-subnet and DNN configurations. It enables parallel IP resolution, which dramatically reduces connection time during failover.

For VM placement, choose between **availability sets** and **availability zones**:

- **Availability sets** protect against rack-level failures within a datacenter. VMs can be placed in a proximity placement group for minimal latency.
- **Availability zones** protect against datacenter-level failures. Network latency between zones is higher, which affects synchronous replication performance.

Test under load before choosing availability zones with synchronous commit. The increased latency can impact transaction throughput.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

### Failover Cluster Instances (FCI)

A failover cluster instance is a single SQL Server instance installed across multiple WSFC nodes using shared storage. Only one node runs the instance at a time — on failover, a different node starts the same SQL Server instance, accessing the same storage.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/failover-cluster-instance-overview.md -->

The key difference from AGs: with an FCI, you share storage instead of replicating it. This means you protect the entire instance (all databases, logins, jobs, everything), but your storage becomes the single point of failure.

Azure offers four shared storage options for FCIs:
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/failover-cluster-instance-overview.md -->

| Storage | AZ Support | FILESTREAM | MSDTC |
|---|---|---|---|
| Shared disks | ✅ (with ZRS) | ✅ | ✅ (Win 2019+) |
| Premium files | ✅ | ❌ | ❌ |
| S2D | ❌ | ✅ | ❌ |
| Elastic SAN | ✅ | ❌ | ❌ |

Azure shared disks are the most feature-complete option. They support SCSI persistent reservations, FILESTREAM, and MSDTC on Windows Server 2019 and later. Premium SSD ZRS shared disks even support cross-zone FCIs. Premium file shares, Storage Spaces Direct (S2D), and Azure Elastic SAN each cover narrower use cases — refer to the table above.

Like AGs, FCIs benefit from multi-subnet deployment to avoid the load balancer dependency. DNN is also supported for FCIs starting with SQL Server 2019 CU2 on Windows Server 2016+.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

### When to Use AG vs. FCI vs. Log Shipping

| Criteria | AG | FCI | Log Shipping |
|---|---|---|---|
| Protects | Specific databases | Entire instance | Specific databases |
| Storage model | Per-node | Shared | Per-node |
| Automatic failover | ✅ (sync mode) | ✅ | ❌ (manual) |
| Read scale-out | ✅ (read replicas) | ❌ | ✅ (with delay) |
| RPO | Zero (sync) | Zero | Minutes to hours |

**Use AGs** when you need per-database control, readable secondaries, or cross-region DR with asynchronous replicas. This is the right choice for most workloads.

**Use FCIs** when you need to protect the entire instance — all databases, SQL Agent jobs, linked servers, and server-level objects — as a single unit. FCI is also the right choice if your workload requires MSDTC.

**Use log shipping** as a lightweight async DR mechanism when you don't need automatic failover. It's simple, well-understood, and works across versions and editions.

### Anti-Pattern: Single-Subnet AG with Load Balancer

If you're building a new AG on Azure VMs, use multi-subnet. Single-subnet deployments that rely on Azure Load Balancer for the VNN listener add complexity, cost, and failover delay. The health probe polls every 10 seconds by default, which means failover detection is slower than it needs to be.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/hadr-windows-server-failover-cluster-overview.md -->

Multi-subnet eliminates the load balancer entirely. Each replica gets its own IP in its own subnet, and DNS-based failover just works. If you already have a single-subnet AG, you can migrate it to multi-subnet without rebuilding the cluster.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

> **Gotcha:** If you have multiple AGs or FCIs on the same cluster, each one needs its own independent connection point — whether that's a VNN listener, a DNN listener, or multi-subnet IPs. They can't share.
<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md -->

Deep-dive topics like cluster tuning, AG connectivity edge cases, and FCI storage configuration are covered in Chapter 28.

The next chapter shifts from keeping your database available within a region to surviving the loss of an entire region: disaster recovery.
