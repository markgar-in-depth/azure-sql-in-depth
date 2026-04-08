# Chapter 28: SQL Server on Azure VMs — Advanced Topics

You've provisioned your SQL Server VM, connected your apps, and set up basic operations (→ see Chapter 25). Now it's time to go deep.

This chapter covers six areas that separate a VM that works from one that performs, stays online, and passes audit:

- Storage architecture — disk types, striping, caching
- HADR — cluster tuning, AG connectivity, FCI storage
- Security hardening — Defender, encryption, network controls
- Application architecture patterns for IaaS workloads
- SQL Server on Linux VMs
- The Modernization Advisor — deciding when to leave IaaS behind

## Storage Deep Dive

Storage is the single biggest performance lever on a SQL Server VM. Get the disk type wrong, misconfigure the cache, or skip the striping step, and you'll spend months chasing phantom performance issues. Azure gives you four disk types worth considering for SQL Server workloads, and each serves a different niche.

### Disk Type Selection

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/performance-guidelines-best-practices-storage.md -->

**Premium SSD** is the default for most SQL Server deployments. IOPS and throughput scale with disk size — a P30 (1 TiB) delivers 5,000 IOPS and 200 MB/s, while a P80 (32 TiB) hits 20,000 IOPS and 900 MB/s. Premium SSDs support host caching, which is critical for read-heavy data file workloads.

Use P30 or P40 disks for data files to stay within the caching-supported size range (disks 4 TiB and larger don't support caching). For log files, evaluate P30 through P80 based on your write throughput needs.

> **Tip:** Start with P30 disks for both data and log files. At 5,000 IOPS and 200 MB/s each, they cover most workloads. Scale up only when monitoring shows you're hitting limits.

**Premium SSD v2** is the next generation. Unlike Premium SSD, you configure capacity, IOPS, and throughput independently — no more overprovisioning disk size just to get more IOPS. A single disk scales up to 80,000 IOPS and 1,200 MB/s. Disks up to 6 GiB get a baseline of 3,000 IOPS and 125 MB/s for free. After 6 GiB, maximum IOPS increases by 500 per GiB, and throughput scales at 0.25 MB/s per configured IOP. You can adjust IOPS and throughput dynamically without downtime using Azure CLI or PowerShell.

> **Tip:** The 3,000 IOPS baseline applies *per disk*. In a storage pool, baselines stack: a 4-disk pool gets 12,000 IOPS free (3,000 × 4). Factor this into your sizing — pooling smaller disks can deliver substantial free IOPS before you pay for additional performance.

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/storage/storage-configuration-premium-ssd-v2.md -->

The trade-offs: Premium SSD v2 doesn't support host caching, it requires availability zones (no availability sets for the disks themselves), and portal-based deployment is currently limited to the Ebdsv5 and Ebsv5 VM series. You can manually install SQL Server on any VM series that supports Premium SSD v2 and register it with the SQL IaaS Agent extension.

> **Important:** When configured through the SQL VM resource, Premium SSD v2 doesn't support mixing with other disk types on the same VM. If you go Premium SSD v2, all your managed disks must be Premium SSD v2.

**Ultra Disk** targets workloads demanding submillisecond latency. Like Premium SSD v2, you configure capacity, IOPS, and throughput independently. Ultra Disk is ideal for the transaction log drive when you need single-digit I/O latency.

**Write Accelerator** achieves the same low-latency goal for the log drive without Ultra Disk pricing — but it's exclusive to M-series VMs. It provides a write-optimized cache for Premium SSD disks. If you're on M-series, prefer Write Accelerator over Ultra Disk for the log drive.

The following table summarizes your options:

| Disk Type | Max IOPS | Max Throughput | Caching |
|---|---|---|---|
| Premium SSD | 20,000 (P80) | 900 MB/s | Yes (≤4 TiB) |
| Premium SSD v2 | 80,000 | 1,200 MB/s | No |
| Ultra Disk | 400,000 | 10,000 MB/s | No |
| Write Accelerator | Per VM limits | Per VM limits | Write cache |

### Storage Spaces Striping and Caching Policies

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/storage/storage-configuration.md -->

Individual disks rarely deliver enough IOPS for production workloads. You stripe multiple disks into a **Storage Spaces** pool to aggregate their performance. Azure Marketplace SQL Server images create this pool automatically with these settings:

- **Stripe size (interleave):** 64 KB
- **Allocation unit size:** 64 KB NTFS
- **Columns:** Equal to the number of physical disks (up to 8)
- **Resiliency:** Simple (no mirroring — Azure managed disks handle redundancy)

> **Gotcha:** The column count is fixed for the life of the storage pool. If you create a pool with four disks, every subsequent expansion must add disks in multiples of four to maintain the striped configuration's integrity.

When creating pools manually with PowerShell, the key command looks like this:

```powershell
$PhysicalDisks = Get-PhysicalDisk | Where-Object {
    $_.FriendlyName -like "*2" -or $_.FriendlyName -like "*3"
}

New-StoragePool -FriendlyName "DataFiles" `
    -StorageSubsystemFriendlyName "Windows Storage on $env:COMPUTERNAME" `
    -PhysicalDisks $PhysicalDisks |
New-VirtualDisk -FriendlyName "DataFiles" `
    -Interleave 65536 `
    -NumberOfColumns $PhysicalDisks.Count `
    -ResiliencySettingName simple `
    -UseMaximumSize |
Initialize-Disk -PartitionStyle GPT -PassThru |
New-Partition -AssignDriveLetter -UseMaximumSize |
Format-Volume -FileSystem NTFS -NewFileSystemLabel "DataDisks" `
    -AllocationUnitSize 65536 -Confirm:$false
```

Always create separate pools for data and log files. The caching rules are non-negotiable:

| Drive | Caching | Why |
|---|---|---|
| Data files | ReadOnly | Faster reads; cached reads bypass IOPS limits |
| Log files | None | Sequential writes gain nothing from read cache |
| OS disk | ReadWrite | Default — leave it alone |

> **Warning:** Never use ReadWrite caching on disks hosting SQL Server files. SQL Server doesn't support data consistency with ReadWrite cache, and you risk data corruption.

To resize a storage pool, add more disks — don't resize existing disks in the pool. Resizing a disk that's already in a pool wastes the extra space because the storage pool can't use it.

### Tempdb on Local Ephemeral SSD

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/storage/tempdb-ephemeral-storage.md -->

Most Azure VMs include a local ephemeral SSD (the `D:\` drive) that's physically attached to the host. This drive offers far lower latency and higher IOPS than remote storage — perfect for `tempdb`, which is recreated every time SQL Server restarts anyway.

For Marketplace-deployed VMs, the SQL IaaS Agent extension automatically manages `tempdb` folder creation and permissions on the ephemeral drive. For manually installed SQL Server, you need to automate this yourself because the ephemeral drive's contents are wiped on every VM restart. The approach is straightforward:

1. Set SQL Server and SQL Agent services to **Manual** startup
2. Create a PowerShell script that creates the `tempdb` folder on `D:\` and starts the services
3. Schedule the script with Task Scheduler to run at system startup

```powershell
$SQLService = "SQL Server (MSSQLSERVER)"
$SQLAgentService = "SQL Server Agent (MSSQLSERVER)"
$tempfolder = "D:\SQLTEMP"
if (!(Test-Path -Path $tempfolder)) {
    New-Item -ItemType Directory -Path $tempfolder
}
Start-Service $SQLService
Start-Service $SQLAgentService
```

> **Gotcha:** Not all VMs have local ephemeral storage. VMs without a temp disk place `tempdb` in the data folder by default. Also, FXmdsv2-series VMs with uninitialized NVMe ephemeral disks don't support `tempdb` placement on the local disk — SQL Server can fail to start. Use a different VM series or place `tempdb` on remote storage.

You can also use the ephemeral drive for the **buffer pool extension**, which extends SQL Server's in-memory buffer pool to a file on disk. The recommended size is 4 to 8 times your `max server memory` setting (up to 4× for Standard edition, 32× for Enterprise):

```sql
ALTER SERVER CONFIGURATION
SET BUFFER POOL EXTENSION ON
(FILENAME = 'D:\SQLTEMP\ExtensionFile.BPE', SIZE = 64 GB);
```

### Azure Elastic SAN as Shared Block Storage

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/storage/storage-configuration-azure-elastic-san.md -->

Azure Elastic SAN is a network-attached storage service that connects to VMs over iSCSI. It's not typically cost-effective for a *single* SQL Server workload because achieving the required IOPS often means overprovisioning capacity. Where Elastic SAN shines is **storage consolidation** — pooling storage for multiple SQL Server workloads (or a mix of SQL and non-SQL workloads) that share provisioned performance dynamically.

The architecture maps cleanly to SQL Server best practices:

- Create a **volume group** that inherits network rules for the VM's virtual network
- Create separate **volumes** for data, log, and `tempdb` files
- Connect volumes via iSCSI with Multipath I/O (MPIO) for redundancy

Elastic SAN communicates over the network, so VM sizing must account for both production network traffic and storage throughput within the VM's network bandwidth limit. A Standard_E32ds_v5 VM caps disk throughput at 865 MB/s, but supports up to 2,000 MB/s network throughput — Elastic SAN lets you tap into that full network bandwidth for storage.

> **Tip:** Use zone-redundant storage (ZRS) with Elastic SAN for high availability. Enable CRC protection for Windows VMs. Use private endpoints to keep traffic off the public internet.

## HADR Deep Dive

High availability and disaster recovery on Azure VMs means Windows Server Failover Clustering (WSFC) with either Always On availability groups or failover cluster instances. The underlying technology is the same as on-premises, but the cloud environment introduces different failure modes, networking constraints, and tuning requirements.

### Cluster Tuning

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/hadr-cluster-best-practices.md -->

The default WSFC heartbeat and threshold settings are designed for low-latency on-premises networks. Azure's network introduces higher and more variable latency, plus maintenance events that can cause transient connectivity blips. Running with on-premises defaults in Azure leads to unnecessary failovers.

**Heartbeat and threshold settings.** Relax them. The heartbeat network uses UDP 3343, which is inherently less reliable than TCP and more prone to packet loss — which means a healthy node can miss enough heartbeats to trigger an unnecessary failover. For Windows Server 2012 and later, use these values:

| Setting | Recommended Value |
|---|---|
| SameSubnetDelay | 1 second |
| SameSubnetThreshold | 40 heartbeats |
| CrossSubnetDelay | 1 second |
| CrossSubnetThreshold | 40 heartbeats |

```powershell
(Get-Cluster).SameSubnetThreshold = 40
(Get-Cluster).CrossSubnetThreshold = 40
```

The cumulative tolerance is delay × threshold. With 1-second heartbeats and a 40-heartbeat threshold, the cluster tolerates 40 seconds of missed heartbeats before taking recovery action.

**Quorum options.** Every production cluster needs a quorum witness — without one, Microsoft won't support it, and cluster validation fails.

| Witness Type | When to Use |
|---|---|
| Cloud witness | Default choice (Windows Server 2016+); uses an Azure Storage account |
| Disk witness | Most resilient; use with Azure Shared Disks |
| File share witness | Fallback when cloud and disk aren't available |

Cloud witness is the default for most deployments. Use a disk witness when you're already using Azure Shared Disks and want the most resilient option.

**Multi-subnet deployment and availability zones.** Place cluster nodes in different availability zones for datacenter-level fault isolation, or in an availability set for lower-latency redundancy within a single datacenter. Use a single NIC per node — Azure networking has built-in redundancy, and adding NICs provides no benefit. Bandwidth limits are shared across all NICs on a VM.

### Availability Group Connectivity

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/availability-group-overview.md, sql-server-on-azure-vms/windows/concepts/best-practices/hadr-cluster-best-practices.md -->

**Multi-subnet vs. single-subnet.** Always prefer multi-subnet deployments. When each AG replica lives in a different subnet, the AG listener gets an IP address in each subnet and routes traffic directly to the current primary — no load balancer, no DNN, no extra moving parts.

In a **single-subnet** deployment, Azure's security model blocks the Gratuitous ARP broadcasts that on-premises clusters use to redirect listener traffic after failover. You need either:

- **Distributed Network Name (DNN):** A DNS-based listener that eliminates the load balancer dependency. Failover is faster because there's no load balancer probe delay. Available starting with SQL Server 2016 SP3, 2017 CU25, and 2019 CU8 on Windows Server 2016+. The DNN is the recommended single-subnet option.
- **Virtual Network Name (VNN):** The traditional approach, backed by an Azure Load Balancer with a health probe. Requires `MultiSubnetFailover=true` in connection strings even in a single subnet.

| Aspect | Multi-Subnet | DNN (Single) | VNN (Single) |
|---|---|---|---|
| Load balancer | No | No | Yes |
| Failover speed | Fast | Fast | Slower (probe) |
| Client driver | Standard | MSF=True¹ | MSF=True¹ |
| Min SQL version | 2012 | 2016 SP3 | 2012 |

¹ `MultiSubnetFailover=True` in the connection string.

> **Tip:** Set `MultiSubnetFailover=true` in every connection string, even for single-subnet deployments. It future-proofs you for subnet expansion and eliminates connection delays during failover.

**Portal-based vs. manual AG configuration.** The Azure portal can create the entire AG — cluster, AG, and listener — in one workflow for SQL Server 2016+ Enterprise Edition on Windows Server 2016+. It automatically configures a cloud witness and multi-subnet networking. For Standard Edition, older versions, or advanced topologies like distributed AGs, configure manually.

**Relaxed monitoring for availability groups.** If you're seeing spurious failovers after tuning heartbeat settings, you can relax AG-level monitoring:

| Parameter | Default | Relaxed Value |
|---|---|---|
| Health check timeout | 30 seconds | 60 seconds |
| Failure condition level | 3 | 2 |
| Lease timeout | 20 seconds | 40 seconds |
| Session timeout | 10 seconds | 20 seconds |
| Max failures in period | 2 | 6 |

```sql
ALTER AVAILABILITY GROUP AG1 SET (HEALTH_CHECK_TIMEOUT = 60000);
ALTER AVAILABILITY GROUP AG1 SET (FAILURE_CONDITION_LEVEL = 2);
```

> **Warning:** Relaxing monitoring masks symptoms — it doesn't fix root causes. Use it to stabilize the environment while you investigate the underlying issue (I/O bottlenecks, VM throttling, Azure maintenance events).

### FCI Storage Configuration

Failover cluster instances require shared storage accessible by all cluster nodes. Azure offers four options, each with distinct trade-offs:

<!-- Source: sql-server-on-azure-vms/windows/concepts/business-continuity/failover-cluster-instance-overview.md -->

Each storage option has its own version requirements:

- **Azure Shared Disks** — any Windows Server, any SQL Server version
- **Premium File Shares** — Windows Server 2012+, SQL Server 2012+
- **Storage Spaces Direct** — Windows Server 2016+, SQL Server 2016+
- **Azure Elastic SAN** — Windows Server 2019+, SQL Server 2022+

And each option supports a different set of features:

| Storage Option | AZ Support | FILESTREAM | MSDTC |
|---|---|---|---|
| Azure Shared Disks | ZRS (Premium) | Yes | Yes (2019+) |
| Premium File Shares | Yes | No | No |
| Storage Spaces Direct | No | Yes | No |
| Azure Elastic SAN | Yes | No | No |

**Azure Shared Disks** are the closest to traditional SAN behavior and the default choice for most FCIs. They're the only FCI storage option that supports both FILESTREAM and MSDTC. Premium SSD ZRS enables cross-zone deployments.

**Premium File Shares** trade feature breadth for operational simplicity — fully managed, burstable IOPS, cross-zone support. Choose them when you don't need FILESTREAM or MSDTC and want a hands-off storage layer.

**Storage Spaces Direct (S2D)** pools local storage across nodes. It requires identical disk capacity on both VMs and high network bandwidth for replication, making it the most expensive option. Choose S2D only when you need FILESTREAM support without shared disk dependencies.

**Azure Elastic SAN** is the newest option (Windows Server 2019+, SQL Server 2022+). It offers SCSI PR support and zone-redundant deployments. Consider it for storage consolidation scenarios where multiple workloads share a single SAN.

For FCI connectivity in a single subnet, the same DNN vs. VNN choice applies as with availability groups. Multi-subnet is always preferred.

## Security Hardening

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/security-considerations-best-practices.md -->

With an IaaS deployment, you own the full security stack from the OS up. That's more responsibility than PaaS — but it also means more control.

### Microsoft Defender for SQL on VMs

Microsoft Defender for SQL on machines provides two capabilities that matter:

- **Vulnerability Assessment** scans your SQL Server configuration for security weaknesses and provides remediation steps with actionable recommendations
- **Advanced Threat Protection** detects anomalous database activity — SQL injection attempts, brute-force logins, unusual data exfiltration patterns

Register your VM with the SQL IaaS Agent extension to surface Defender assessments directly in the SQL virtual machines resource in the Azure portal.

### Disk Encryption and Confidential VMs

Azure managed disks are encrypted at rest by default using Azure Storage Service Encryption with Microsoft-managed keys (256-bit AES, FIPS 140-2 compliant). For most workloads, this is sufficient.

When compliance requires customer-managed keys or end-to-end encryption including the ephemeral disk, use **Azure Disk Encryption (ADE)**, which uses BitLocker on Windows. ADE integrates with Azure Key Vault for key management.

**Confidential VMs** provide hardware-enforced isolation using AMD SEV-SNP technology. The processor encrypts VM memory with keys that the host can't access — protecting data in use, not just at rest. Confidential OS disk encryption binds the disk encryption keys to the VM's TPM chip. Encrypt data disks with BitLocker and enable automatic unlocking so the keys are stored on the (already protected) OS disk.

> **Note:** Disk encryption recommendations differ for confidential VMs. Don't use ADE on confidential VMs — use confidential OS disk encryption plus BitLocker auto-unlock instead.

### JIT Access, NSGs, and FIPS Compliance

**Just-In-Time (JIT) access** locks down management ports (RDP, SSH) by default and opens them only for a specific time window when a user requests access through Microsoft Defender for Cloud. Pair this with **Azure Bastion** to eliminate direct RDP exposure entirely.

**Network Security Groups** control traffic at the subnet or NIC level. For SQL Server VMs, restrict port 1433 to known application subnets and block all public internet access to the SQL port. Use Application Security Groups to logically group your database servers and apply rules by group rather than by individual IP.

**FIPS compliance** requires Windows Server 2022 (FIPS is enabled by default) or Windows Server 2019 with the FIPS policy manually enabled via STIG finding V-93511. SQL Server itself is FIPS-capable starting with SQL Server 2016. FIPS is not currently supported for SQL Server on Linux Azure VMs.

## Application Architecture Patterns

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/application-patterns-development-strategies.md -->

SQL Server on Azure VMs supports the same n-tier patterns you'd use on-premises, but you can leverage Azure infrastructure to improve each tier's scalability and resilience.

**1-tier (all-in-one).** Everything — web app, business logic, SQL Server — runs on a single VM. Use this for dev/test, quick proof-of-concept work, and small departmental apps. Not suitable for production workloads that need independently scalable tiers.

**2-tier.** Application server talks directly to the SQL Server VM. The app server handles both web and business logic. This is the classic client-server model and works well for internal line-of-business applications with a known user base.

**3-tier.** Web server, application server, and database server each on separate VMs (or VM groups). This is the production standard — each tier scales independently, and you can put a load balancer in front of the web and app tiers.

**N-tier with HADR.** The production-grade pattern: multiple web server instances behind Azure Load Balancer, multiple app server instances, and SQL Server with Always On availability groups or FCIs.

Place each tier in its own availability set or availability zone. Use Azure Virtual Network to keep inter-tier traffic private.

> **Tip:** Always put VMs in the same tier into the same availability set. This distributes them across fault and update domains, preventing a single hardware failure or maintenance event from taking down the entire tier.

For hybrid architectures that span on-premises and Azure, use Azure Virtual Network with site-to-site VPN or ExpressRoute. This lets your on-premises application tier communicate with SQL Server VMs in Azure via private IP addresses, and enables Windows authentication across the boundary when you extend your Active Directory domain.

## SQL Server on Linux VMs

<!-- Source: sql-server-on-azure-vms/linux/overview/sql-server-on-linux-vm-what-is-iaas-overview.md, sql-server-on-azure-vms/linux/concepts/sql-server-iaas-agent-extension-linux.md -->

SQL Server has run on Linux since SQL Server 2017. On Azure, you can deploy SQL Server on RHEL, SLES, and Ubuntu using Marketplace images that come with the database engine, command-line tools, SQL Agent, and full-text search pre-installed.

### Supported Versions and Distributions

| SQL Server Version | Distributions |
|---|---|
| SQL Server 2022 | Ubuntu 20.04 LTS |
| SQL Server 2019 | RHEL 8, SLES v12 SP5 |

All three distributions install the database engine, tools, SQL Agent, and full-text search. SSIS is supported on RHEL and Ubuntu but not SLES. The HA add-on (Pacemaker) is available on all three.

Which distro should you pick? It depends on your team's operational expertise and your organization's support agreements. RHEL is the most common in enterprise environments and has the broadest ecosystem of third-party tools. SLES has strong SAP integration if you're already in that world. Ubuntu is popular with teams that come from a developer-first background. There are no meaningful SQL Server performance differences between them — the choice is operational, not technical.

### SQL IaaS Agent Extension for Linux

The SQL IaaS Agent extension for Linux provides Azure portal integration and simplified license management (Azure Hybrid Benefit tracking, pay-as-you-go, DR replica licensing). It currently offers limited functionality — no automated storage configuration, no automated patching, and no automated backup management. If those capabilities matter for your workload, you'll handle them through standard Linux tooling or third-party solutions.

Register your Linux VM with the extension using Azure CLI:

```bash
az sql vm create --name <vm-name> \
    --resource-group <rg-name> \
    --location <region> \
    --license-type PAYG
```

> **Note:** The Linux SQL IaaS Agent extension supports only single-instance configurations and is currently available only for Ubuntu.

### Pacemaker HA with STONITH Fencing

Linux VMs don't use Windows Server Failover Clustering. Instead, high availability relies on **Pacemaker** as the cluster resource manager and **STONITH** (Shoot The Other Node In The Head) fencing to prevent split-brain scenarios. All three distributions use the `fence_azure_arm` fencing agent, but the tooling and setup differ significantly:

- **RHEL:** Uses `pcs` for cluster management.
  - **Install:** `yum install pacemaker pcs fence-agents-all resource-agents`
  - **Bootstrap:** `pcs cluster setup` and `pcs cluster start`
  - **Resources:** `pcs resource create` and `pcs constraint` commands
- **SLES:** Uses `crm` (crmsh) instead of `pcs`.
  - **Install:** `zypper install ha-cluster-bootstrap` plus `fence-agents` and `python3-azure-mgmt-compute` separately
  - **Bootstrap:** `crm cluster init` on the first node, `crm cluster join` on additional nodes
  - **Resources:** `crm configure` interactive shell
- **Ubuntu:** Also uses `crm` (crmsh).
  - **Install:** `apt-get install pacemaker pacemaker-cli-utils crmsh resource-agents fence-agents`
  - **Bootstrap:** Direct `corosync` configuration rather than a helper like `ha-cluster-bootstrap`
  - **Resources:** Same `crm configure` workflow as SLES

The architecture is an Always On availability group managed by Pacemaker instead of WSFC. Each node runs the Pacemaker stack, the SQL Server HA add-on integrates the AG resources with Pacemaker, and the fencing agent ensures that a failed node is forcibly isolated before failover proceeds.

> **Tip:** If your team is new to Pacemaker, start with whichever distro matches your existing Linux skills. The `pcs` CLI on RHEL is generally considered more approachable than `crm` on SLES/Ubuntu, but both get the job done.

The key architectural difference from Windows: Linux AGs don't use a Windows-style listener with floating IP addresses. Instead, you configure an AG listener through an **Azure Load Balancer** that probes the Pacemaker-managed virtual IP resource.

> **Gotcha:** Third-party clustering solutions like DH2i DxEnterprise provide an alternative to Pacemaker with a different management experience. Evaluate both options based on your team's Linux operational expertise.

## Modernization Advisor

<!-- Source: sql-server-on-azure-vms/windows/overview/modernization-advisor.md -->

Not every workload should stay on a VM forever. The **Modernization Advisor** is a built-in Azure portal tool (currently in preview) that assesses whether your SQL Server on Azure VM would benefit from migrating to Azure SQL Managed Instance.

It evaluates your VM's vCores, memory per vCore, storage size, and storage type, then matches them against a suitable Managed Instance configuration. If your workload is a migration candidate, you see a **Compare** button that generates a side-by-side comparison including estimated cost savings.

The potential benefits of moving to Managed Instance include:

- Fully automated backups, patching, and high availability
- Dynamic online scaling without downtime
- Zone-redundant storage for a higher SLA than the VM-level SLA
- Long-term backup retention up to 10 years
- No OS-level management overhead

If the Compare button doesn't appear, your workload uses features that Managed Instance doesn't support — FILESTREAM, linked servers to non-Azure sources, multiple instances on the same machine, or other IaaS-only capabilities. That's fine. The Advisor helps you make a data-driven decision rather than assuming IaaS is always the right answer.

To access it, open your SQL virtual machines resource in the Azure portal, then navigate to **Modernization Advisor (preview)** under **Settings**. Your VM must be registered with the SQL IaaS Agent extension.

For workloads that do qualify, migration paths include backup/restore, Log Replay Service, and the Managed Instance link (→ see Chapters 23 and 27 for migration and MI Link details).

In the next chapter, we move beyond individual deployment options to the appendices — starting with the complete resource limits reference that every Azure SQL developer keeps bookmarked.
