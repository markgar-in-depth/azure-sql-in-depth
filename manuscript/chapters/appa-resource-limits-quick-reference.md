# Appendix A: Resource Limits Quick Reference

Every Azure SQL resource has hard limits — on storage, compute, sessions, workers, and IOPS. Hit one, and your workload stalls. This appendix is the single place in the book where those numbers live. Chapter 2 explains the concepts behind tiers and purchasing models; here you get the tables.

> **Tip:** Limits change as Microsoft updates the platform. If a number here doesn't match what you see in the portal, check the official docs — they're the final authority.

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/resource-limits-logical-server.md -->

## Logical Server Limits

Before you look at individual databases, know the server-level ceiling:

| Resource | Limit |
|---|---|
| Databases per server | 5,000 |
| Servers per subscription per region | 250 |

Subscription vCore quotas also apply. The defaults depend on your subscription type:

| Subscription type | Default vCore limit |
|---|---|
| Enterprise Agreement | 2,000 |
| Pay-as-you-go | 150 |
| Free trial | 10 |
| MSDN / MPN / Imagine / AzurePass / Azure for Students | 40 |
| Microsoft for Startups | 100 |

DTU databases count against this quota too — each vCore equals 100 DTUs for quota purposes. Need more? Submit a support request in the portal.

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/resource-limits-logical-server.md -->

---

## Single Database Limits: DTU Model

The DTU model bundles CPU, memory, and I/O into a single unit. You pick a tier and a DTU level; everything else follows.

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/single-database-resources/resource-limits-dtu-single-databases.md -->

### Basic Tier

| Metric | Basic |
|---|---|
| Max DTUs | 5 |
| Max storage (GB) | 2 |
| Max workers | 30 |
| Max sessions | 300 |

> **Note:** Basic provides less than one vCore. It's for dev/test and prototyping — not production workloads.

### Standard Tier

**S0 – S4:**

| Metric | S0 | S1 | S2 | S3 | S4 |
|---|---|---|---|---|---|
| Max DTUs | 10 | 20 | 50 | 100 | 200 |
| Max storage (GB) | 250 | 250 | 250 | 1,024 | 1,024 |
| Max workers | 60 | 90 | 120 | 200 | 400 |
| Max sessions | 600 | 900 | 1,200 | 2,400 | 4,800 |

**S6 – S12:**

| Metric | S6 | S7 | S9 | S12 |
|---|---|---|---|---|
| Max DTUs | 400 | 800 | 1,600 | 3,000 |
| Max storage (GB) | 1,024 | 1,024 | 1,024 | 1,024 |
| Max workers | 800 | 1,600 | 3,200 | 6,000 |
| Max sessions | 9,600 | 19,200 | 30,000 | 30,000 |

### Premium Tier

| Metric | P1 | P2 | P4 | P6 | P11 | P15 |
|---|---|---|---|---|---|---|
| Max DTUs | 125 | 250 | 500 | 1,000 | 1,750 | 4,000 |
| Max storage (GB) | 1,024 | 1,024 | 1,024 | 1,024 | 4,096 | 4,096 |
| In-memory OLTP (GB) | 1 | 2 | 4 | 8 | 14 | 32 |
| Max workers | 200 | 400 | 800 | 1,600 | 2,800 | 6,400 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 |

> **Gotcha:** P11 and P15 storage above 1 TB isn't available in every region. Check regional availability before counting on 4 TB.

---

## Single Database Limits: vCore Model

The vCore model gives you independent control over compute and storage. Tables below cover the standard-series (Gen5) hardware — the most commonly deployed option.

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/single-database-resources/resource-limits-vcore-single-databases.md -->

### General Purpose — Provisioned Compute

**2 – 16 vCores:**

| Metric | 2 | 4 | 8 | 16 |
|---|---|---|---|---|
| Memory (GB) | 10.4 | 20.8 | 41.5 | 83 |
| Max data (GB) | 1,024 | 1,024 | 2,048 | 3,072 |
| Max log (GB) | 307 | 307 | 461 | 922 |
| Max data IOPS | 640 | 1,280 | 2,560 | 5,120 |
| Max log rate (MiB/s) | 9 | 18 | 36 | 50 |
| tempdb (GB) | 64 | 128 | 256 | 512 |
| Max workers | 200 | 400 | 800 | 1,600 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 |

**24 – 128 vCores:**

| Metric | 24 | 32 | 40 | 80 | 128 |
|---|---|---|---|---|---|
| Memory (GB) | 124.6 | 166.1 | 207.6 | 415.2 | 625 |
| Max data (GB) | 4,096 | 4,096 | 4,096 | 4,096 | 4,096 |
| Max log (GB) | 1,024 | 1,024 | 1,024 | 1,024 | 1,024 |
| Max data IOPS | 7,680 | 10,240 | 12,800 | 12,800 | 16,000 |
| Max log rate (MiB/s) | 50 | 50 | 50 | 50 | 50 |
| tempdb (GB) | 768 | 1,024 | 1,280 | 2,560 | 2,560 |
| Max workers | 2,400 | 3,200 | 4,000 | 8,000 | 12,800 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 |

General Purpose uses remote SSD storage. Read latency is typically 5–10 ms; write latency 5–7 ms. No In-memory OLTP support. No read scale-out.

### General Purpose — Serverless Compute

Serverless auto-scales vCores between a minimum and maximum. You set the range; Azure bills for what you use.

**1 – 8 max vCores:**

| Metric | 1 | 2 | 4 | 8 |
|---|---|---|---|---|
| Min vCores | 0.5 | 0.5 | 0.5 | 1.0 |
| Max memory (GB) | 3 | 6 | 12 | 24 |
| Max data (GB) | 512 | 1,024 | 1,024 | 2,048 |
| Max data IOPS | 320 | 640 | 1,280 | 2,560 |
| Max log rate (MiB/s) | 4.5 | 9 | 18 | 36 |
| Max workers | 75 | 150 | 300 | 600 |

**16 – 80 max vCores:**

| Metric | 16 | 24 | 40 | 80 |
|---|---|---|---|---|
| Min vCores | 2.0 | 3.0 | 5.0 | 10.0 |
| Max memory (GB) | 48 | 72 | 120 | 240 |
| Max data (GB) | 3,072 | 4,096 | 4,096 | 4,096 |
| Max data IOPS | 5,120 | 7,680 | 12,800 | 12,800 |
| Max log rate (MiB/s) | 50 | 50 | 50 | 50 |
| Max workers | 1,200 | 1,800 | 3,000 | 6,000 |

Auto-pause delay ranges from 15 minutes to 10,080 minutes (7 days), or you can disable it entirely.

> **Tip:** After auto-pause triggers, the first connection incurs a cold start — typically 10–30 seconds while Azure warms the compute. If that latency matters, disable auto-pause or keep the delay short and use a keep-alive query.
<!-- TODO: source needed for "cold start — typically 10–30 seconds" -->

### Business Critical — Provisioned Compute

Business Critical uses local SSD storage and maintains four replicas (one readable). This is where you get sub-2 ms latency and In-memory OLTP.

**2 – 16 vCores:**

| Metric | 2 | 4 | 8 | 16 |
|---|---|---|---|---|
| Memory (GB) | 10.4 | 20.8 | 41.5 | 83 |
| Max data (GB) | 1,024 | 1,024 | 2,048 | 3,072 |
| Max log (GB) | 307 | 307 | 461 | 922 |
| Max data IOPS | 8,000 | 16,000 | 32,000 | 64,000 |
| Max log rate (MiB/s) | 24 | 48 | 96 | 96 |
| In-memory OLTP (GB) | 1.57 | 3.14 | 6.28 | 15.77 |
| tempdb (GB) | 64 | 128 | 256 | 512 |
| Max workers | 200 | 400 | 800 | 1,600 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 |
| Replicas | 4 | 4 | 4 | 4 |

**24 – 128 vCores:**

| Metric | 24 | 32 | 40 | 80 | 128 |
|---|---|---|---|---|---|
| Memory (GB) | 124.6 | 166.1 | 207.6 | 415.2 | 625 |
| Max data (GB) | 4,096 | 4,096 | 4,096 | 4,096 | 4,096 |
| Max log (GB) | 1,024 | 1,024 | 1,024 | 1,024 | 1,024 |
| Max data IOPS | 96,000 | 128,000 | 160,000 | 204,800 | 327,680 |
| Max log rate (MiB/s) | 96 | 96 | 96 | 96 | 96 |
| In-memory OLTP (GB) | 25.25 | 37.94 | 52.23 | 131.64 | 227.02 |
| tempdb (GB) | 768 | 1,024 | 1,280 | 2,560 | 2,560 |
| Max workers | 2,400 | 3,200 | 4,000 | 8,000 | 12,800 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 |
| Replicas | 4 | 4 | 4 | 4 | 4 |

Read/write latency: 1–2 ms. Local storage size capped at 4,829 GB across data, log, and tempdb combined.

### Hyperscale — Provisioned Compute (Standard-Series)

Hyperscale breaks the storage ceiling. Data scales to 128 TB, log is unlimited, and you can add up to four readable secondary replicas.

**2 – 16 vCores:**

| Metric | 2 | 4 | 8 | 16 |
|---|---|---|---|---|
| Memory (GB) | 10.4 | 20.8 | 41.5 | 83 |
| Max data (TB) | 128 | 128 | 128 | 128 |
| Max log | Unlimited | Unlimited | Unlimited | Unlimited |
| Local SSD IOPS | 8,000 | 16,000 | 32,000 | 64,000 |
| Max log rate (MiB/s) | 100 | 100 | 100 | 100 |
| tempdb (GB) | 64 | 128 | 256 | 512 |
| Max workers | 200 | 400 | 800 | 1,600 |
| Secondary replicas | 0–4 | 0–4 | 0–4 | 0–4 |

**24 – 80 vCores:**

| Metric | 24 | 32 | 40 | 80 |
|---|---|---|---|---|
| Memory (GB) | 124.6 | 166.1 | 207.6 | 415.2 |
| Max data (TB) | 128 | 128 | 128 | 128 |
| Max log | Unlimited | Unlimited | Unlimited | Unlimited |
| Local SSD IOPS | 96,000 | 128,000 | 160,000 | 204,800 |
| Max log rate (MiB/s) | 100 | 100 | 100 | 100 |
| tempdb (GB) | 768 | 1,024 | 1,280 | 2,560 |
| Max workers | 2,400 | 3,200 | 4,000 | 8,000 |
| Secondary replicas | 0–4 | 0–4 | 0–4 | 0–4 |

Hyperscale also supports premium-series and premium-series memory optimized hardware, both of which scale up to 128 vCores and deliver higher log rates (150 MiB/s). Local read latency: 1–2 ms. Remote read latency: 1–4 ms.

> **Important:** Hyperscale IOPS figures are for local SSD. Workloads also hit remote page servers, so actual IOPS depend on your data's hot/cold distribution.

---

## Elastic Pool Limits: DTU Model

Elastic pools share resources across multiple databases. Per-database limits match the equivalent single-database tier, but the pool imposes aggregate caps.

> **Note:** The single-database DTU tables above are complete. The elastic pool tables below show representative sizes to illustrate the progression. DTU pools have many more eDTU options — check the docs for the full matrix.

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/elastic-pool-resources/resource-limits-dtu-elastic-pools.md -->

### Basic Pools

Basic DTU pools still make sense for dev/test or lightweight internal apps with many small databases. You pay one low price for the pool instead of per-database vCore charges.

| Metric | 50 | 100 | 200 | 400 | 800 | 1,600 |
|---|---|---|---|---|---|---|
| Max storage (GB) | 5 | 10 | 20 | 39 | 78 | 156 |
| Max DBs | 100 | 200 | 500 | 500 | 500 | 500 |
| Max workers | 100 | 200 | 400 | 800 | 1,600 | 3,200 |
| Max DTU/DB | 5 | 5 | 5 | 5 | 5 | 5 |
| Max storage/DB (GB) | 2 | 2 | 2 | 2 | 2 | 2 |

### Standard Pools (Selected Sizes)

Standard DTU pools suit workloads that outgrow Basic but don't need the per-database control of vCore — think multi-tenant SaaS with moderate, predictable demand.

| Metric | 100 | 200 | 400 | 800 | 1,200 | 3,000 |
|---|---|---|---|---|---|---|
| Max storage (GB) | 100 | 200 | 400 | 800 | 1,200 | 3,000 |
| Max DBs | 200 | 500 | 500 | 500 | 500 | 500 |
| Max workers | 200 | 400 | 800 | 1,600 | 2,400 | 6,000 |

### Premium Pools (Selected Sizes)

| Metric | 125 | 500 | 1,000 | 1,750 | 4,000 |
|---|---|---|---|---|---|
| Max storage (GB) | 250 | 750 | 1,024 | 4,096 | 4,096 |
| Max DBs | 50 | 100 | 100 | 100 | 100 |
| Max workers | 200 | 800 | 1,600 | 2,800 | 6,400 |

> **Gotcha:** Setting a nonzero min DTU per database limits how many databases the pool can hold. A 400-eDTU pool with min DTU = 100 caps you at four databases.

---

## Elastic Pool Limits: vCore Model

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/elastic-pool-resources/resource-limits-vcore-elastic-pools.md -->

### General Purpose Pools — Standard-Series (Gen5)

| Metric | 2 | 4 | 8 | 16 | 32 | 80 |
|---|---|---|---|---|---|---|
| Memory (GB) | 10.4 | 20.8 | 41.5 | 83 | 166.1 | 415.2 |
| Max data (GB) | 512 | 756 | 2,048 | 2,048 | 4,096 | 4,096 |
| Max DBs | 100 | 200 | 500 | 500 | 500 | 500 |
| Max data IOPS (pool) | 1,400 | 2,800 | 5,600 | 11,200 | 22,400 | 32,000 |
| Max workers (pool) | 210 | 420 | 840 | 1,680 | 3,360 | 8,400 |
| Max sessions | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 | 30,000 |

Per-database limits in a pool match the equivalent single-database tier. For example, a database in a `GP_Gen5_8` pool gets up to 800 workers — same as a standalone `GP_Gen5_8` database.

---

## Managed Instance Limits

SQL Managed Instance is a full SQL Server engine running in a managed VNet. Limits depend on service tier, hardware generation, and vCore count.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/architecture/resource-limits.md -->

### Hardware Generations

| Feature | Standard (Gen5) | Premium | Memory opt. premium |
|---|---|---|---|
| CPU | Broadwell / Cascade Lake | Ice Lake 2.8 GHz | Ice Lake 2.8 GHz |
| Max vCores | 80 | 128 | 128 |
| Mem per vCore | 5.1 GB | 7 GB | 13.6 GB (≤64 vCores) |
| Max memory | 408 GB | 560 GB | 870.4 GB |

- **Standard-series (Gen5):** Cost-sensitive default — cheapest option.
- **Premium-series:** More vCores (up to 128) and higher per-core performance.
- **Memory optimized premium:** Large buffer pools, columnstore, or in-memory OLTP.

### Available vCore Counts

| Hardware | General Purpose | Next-gen GP | Business Critical |
|---|---|---|---|
| Standard-series | 2, 4, 8, 16, 24, 32, 40, 64, 80 | 4, 8, 16, 24, 32, 40, 64, 80 | 4, 8, 16, 24, 32, 40, 64, 80 |
| Premium-series | 2, 4, 8, 16, 24, 32, 40, 64, 80 | 4–128 (many sizes) | 4–128 (many sizes) |
| Memory optimized | 4, 8, 16, 24, 32, 40, 64, 80 | 4–128 (many sizes) | 4–128 (many sizes) |

> **Note:** 2-vCore instances are only available inside an instance pool.

### Maximum Instance Storage

Storage depends on tier, hardware, and vCore count. Here are the maximums:

| Tier | Standard-series | Premium-series | Memory optimized |
|---|---|---|---|
| General Purpose | Up to 16 TB | Up to 16 TB | Up to 16 TB |
| Next-gen GP | Up to 32 TB | Up to 32 TB | Up to 32 TB |
| Business Critical | Up to 4 TB | Up to 16 TB | Up to 16 TB |

Storage allocation depends on vCore count. For example, a General Purpose standard-series instance gets 2 TB at 4 vCores, 8 TB at 8 vCores, and 16 TB at 16+ vCores. Business Critical is more constrained — check the docs for the exact mapping at your vCore count.

### Service Tier Comparison

| Feature | General Purpose | Next-gen GP | Business Critical |
|---|---|---|---|
| Max DBs per instance | 100 | 500 | 100 |
| Max files per instance | 280 | 4,096/DB | 32,767/DB |
| Max data file size | 8 TB | Instance size | Instance size |
| Max log file size | 2 TB | 2 TB | 2 TB |
| tempdb max size | 24 GB/vCore | 24 GB/vCore | Instance storage |
| tempdb files | Up to 128 | Up to 128 | Up to 128 |
| Max sessions | 30,000 | 30,000 | 30,000 |
| Max workers | 105 × vCores + 800 | 105 × vCores + 800 | 105 × vCores + 800 |
| Storage I/O latency | 5–10 ms | 3–5 ms | 1–2 ms |
| In-memory OLTP | No | No | Yes |
| Read replicas | 0 | 0 | 1 (built-in) |

**Log write throughput by tier:** General Purpose gets 4.5 MiB/s per vCore (max 120 MiB/s). Next-gen GP also gets 4.5 MiB/s per vCore but raises the cap to 192 MiB/s. Business Critical depends on hardware — standard-series gets 4.5 MiB/s per vCore (max 96 MiB/s); premium-series gets 12 MiB/s per vCore (max 192 MiB/s).

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/architecture/resource-limits.md -->

### IOPS by Tier

**General Purpose:** IOPS scales with file size in four steps:

| File size | IOPS per file | Throughput per file |
|---|---|---|
| 0–129 GiB | 500 | 100 MiB/s |
| 129–513 GiB | 2,300 | 150 MiB/s |
| 513–1,025 GiB | 5,000 | 200 MiB/s |
| Above 1,025 GiB | 7,500 | 250 MiB/s |

Instance-level log throughput is capped at 4.5 MiB/s per vCore (max 120 MiB/s).

**Next-gen General Purpose:** 3 IOPS per GB of reserved storage, with a 300 IOPS minimum. You can purchase additional IOPS up to the vCore-level cap:

| vCores | Max IOPS | Max throughput (MB/s) |
|---|---|---|
| 4 | 6,400 | 145 |
| 8 | 12,800 | 290 |
| 16 | 25,600 | 600 |
| 32 | 51,200 | 865 |
| 64 | 80,000 | 1,200 |
| 128 | 80,000 | 1,200 |

**Business Critical:** 4,000 IOPS per vCore. Throughput is unlimited (local SSD). At 80 vCores you get 320,000 IOPS; the cap stays at 320,000 for 96 and 128 vCores.

---

## SQL Server on Azure VMs — Sizing Recommendations

SQL Server on Azure VMs doesn't have the same kind of fixed limit tables — you're choosing a VM series and size, then configuring storage independently. Here's how to think about it.

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/performance-guidelines-best-practices-vm-size.md -->

### Recommended VM Series

| Series | Mem:vCore | Max vCores | Max memory |
|---|---|---|---|
| Ebdsv5 | 8:1 | 112 | 672 GB |
| Easv7 | 8:1 | 160 | 1,280 GB |
| Mbdsv3 | 8:1–22:1 | 176 | ~3.8 TB |
| Msv3/Mdsv3 MM | 20:1–22:1 | 176 | ~3.8 TB |
| Msv3/Mdsv3 HM | 14:1–18:1 | 832 | ~14.8 TB |
| Fasv7 | 4:1 | 80 | 320 GB |
| ECadsv5 | 7:1–8:1 | 96 | 672 GB |

- **Ebdsv5:** Most production OLTP — strong I/O and the right memory ratio.
- **Easv7:** Cost-conscious production with 8:1 memory.
- **Mbdsv3:** Mission-critical OLAP and large warehouses.
- **Msv3/Mdsv3 MM/HM:** High-memory and very large in-memory databases.
- **Fasv7:** Dev/test and CPU-bound workloads (4:1 memory).
- **ECadsv5:** Confidential computing with hardware-based enclaves.

### Quick Sizing Rules

- **Start with Ebdsv5** for most production workloads. It has the right memory ratio, local temp storage for tempdb, and strong I/O throughput per vCore.
- **Use 4+ vCores minimum.** Smaller sizes lack the memory and I/O headroom for production.
- **Memory-optimized first.** SQL Server performs best with an 8:1 memory-to-vCore ratio or higher. Only drop to 4:1 (D-series, F-series) for dev/test.
- **Match storage to workload before choosing a VM.** Get your IOPS and throughput requirements right first — resizing storage later often means redeployment.
- **Plan for 20% growth.** Size storage for where you'll be, not where you are.

> **Important:** SQL Server isn't supported on VMs with more than 64 vCores per NUMA node. If you pick a VM with 128+ vCores, you must disable SMT/hyperthreading. Use the configurable constrained core feature in the portal.

### Storage Performance by Disk Type

<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/performance-guidelines-best-practices-storage.md, sql-server-on-azure-vms/windows/how-to-guides/storage/storage-configuration-premium-ssd-v2.md -->
<!-- TODO: source needed for "Premium SSD P80 900 MB/s" and "Ultra Disk 400,000 IOPS / 10,000 MB/s per disk" — these are Azure Managed Disks specs (azure.microsoft.com/azure/virtual-machines/disks-types) not in the docs mirror -->

| Disk type | Max IOPS/disk | Max throughput/disk | Latency |
|---|---|---|---|
| Premium SSD (P30) | 5,000 | 200 MB/s | ~1 ms |
| Premium SSD (P80) | 20,000 | 900 MB/s | ~1 ms |
| Premium SSD v2 | 80,000 | 1,200 MB/s | Sub-ms |
| Ultra Disk | 400,000 | 10,000 MB/s | Sub-ms |

Strip multiple disks together for aggregate IOPS and throughput. Premium SSD v2 and Ultra Disk let you configure IOPS and throughput independently of capacity — a significant advantage for SQL Server workloads.

---

## How to Read These Tables

A few principles that apply across all the limit tables:

- **Workers ≠ sessions.** Sessions are connections; workers are OS threads executing queries. A single session can spawn multiple parallel workers. You'll usually hit the worker limit before the session limit.
- **External connections aren't your app connections.** The "max concurrent external connections" limit applies to *outbound* connections from Azure SQL to external REST endpoints via `sp_invoke_external_rest_endpoint`. It's capped at 10% of worker threads (hard cap 150). Your inbound client connections are governed by the session and worker limits above.
- **Log rate caps are real.** If you're doing heavy writes (bulk inserts, index rebuilds), the log rate limit — not IOPS — is often the bottleneck. Business Critical and Hyperscale are significantly more generous here.
- **IOPS assume 8–64 KB I/O sizes.** Larger I/O sizes consume proportionally more IOPS. The published numbers reflect the typical SQL Server I/O pattern.
- **"Max data size" is the data file ceiling.** It doesn't include the transaction log, tempdb, or backup storage. Those have their own limits.
- **Reducing max data size reduces max log size proportionally.** If you provision a smaller database than the tier's maximum, the log size ceiling drops too.

> **Gotcha:** The 30,000-session limit looks generous, but connection pooling misconfiguration can exhaust it. Monitor `sys.dm_exec_sessions` and `sys.dm_os_workers` — these tell you which ceiling you're approaching.
