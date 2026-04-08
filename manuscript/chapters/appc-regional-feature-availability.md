# Appendix C: Regional Feature Availability

Not every Azure SQL feature is available in every Azure region. When you're choosing a region for a new deployment — or evaluating whether a feature is an option for an existing one — you need to know what's actually available where. This appendix consolidates the regional availability picture across hardware SKUs, serverless compute, maintenance windows, vector search, and zone redundancy.

<!-- Source: reference/feature-availability-by-region/region-availability.md -->

> **Important:** Regional availability changes frequently as Microsoft expands capacity. Treat the tables here as a point-in-time snapshot. Always confirm against the official [Azure SQL Database feature availability by region](https://learn.microsoft.com/azure/azure-sql/database/region-availability) page and the [Azure products by region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/table) tool before making deployment decisions.

## Hardware SKU Availability

Azure SQL Database offers several hardware configurations in the vCore purchasing model. Which ones you can use depends on your region.

### Standard-Series (Gen5)

Standard-series (Gen5) is the baseline hardware for Azure SQL Database. It's available in **all public regions** where Azure SQL Database is offered — no exceptions, no gaps. If a region has SQL Database, it has Gen5.

This is also the only hardware that supports the serverless compute tier.

<!-- Source: reference/feature-availability-by-region/region-availability.md -->

### Hyperscale Premium-Series

Premium-series hardware targets Hyperscale workloads that need more compute muscle — faster CPUs (Intel Ice Lake), higher memory-to-vCore ratios, and better I/O. It's available for both single databases and elastic pools, but only in select regions.

<!-- Source: reference/feature-availability-by-region/region-availability.md -->

**Americas:**

| Region | Premium-series | Memory optimized |
|---|---|---|
| Brazil South | ✔ | — |
| Canada Central | ✔ | ✔ |
| Canada East | ✔ | ✔ |
| Central US | ✔ | ✔ |
| East US | ✔ | ✔ |
| East US 2 | ✔ | ✔ |
| North Central US | ✔ | ✔ |
| South Central US | ✔ | ✔ |
| West Central US | ✔ | ✔ |
| West US | ✔ | ✔ |
| West US 2 | ✔ | ✔ |
| West US 3 | ✔ | ✔ |

**Asia Pacific:**

| Region | Premium-series | Memory optimized |
|---|---|---|
| East Asia | ✔ | ✔ |
| Southeast Asia | ✔ | ✔ |
| Australia East | ✔ | ✔ |
| Australia Southeast | ✔ | ✔ |
| Central India | ✔ | ✔ |
| South India | ✔ | ✔ |
| Japan East | ✔ | ✔ |
| Japan West | ✔ | ✔ |

**Europe, Middle East, and Africa:**

| Region | Premium-series | Memory optimized |
|---|---|---|
| North Europe | ✔ | ✔ |
| West Europe | ✔ | ✔ |
| France Central | ✔ | ✔ |
| Germany West Central | ✔ | ✔ |
| Sweden Central | ✔ | — |
| Switzerland North | ✔ | ✔ |
| UK South | ✔ | ✔ |

> **Note:** Premium-series memory optimized is not currently available in Brazil South, Sweden Central, or UK West. The column is labeled "Memory optimized" above for brevity.

#### High-vCore Premium-Series (Preview)

160-vCore and 192-vCore configurations for Hyperscale premium-series are in preview in a limited set of regions: Australia East, Canada Central, East US 2, South Central US, West US 2, Southeast Asia, North Europe, UK South, and West Europe.

**Government cloud:** US Gov Arizona supports Hyperscale premium-series up to 80 vCores. US Gov Texas and US Gov Virginia support it up to 128 vCores.

### Fsv2-Series

Fsv2-series hardware is optimized for compute-intensive workloads — high CPU clock speeds with lower memory per vCore. It's available in a smaller set of regions:

- **Americas:** Brazil South, Canada Central, East US, West US 2
- **Asia Pacific:** East Asia, Southeast Asia, Australia Central, Australia Central 2, Australia East, Australia Southeast, Central India, Korea Central, Korea South
- **EMEA:** North Europe, West Europe, France Central, South Africa North, UK South, UK West

### DC-Series

DC-series supports Intel SGX-based secure enclaves for Always Encrypted with secure enclaves. Availability is narrow:

- **Americas:** Canada Central, East US, West US
- **Asia Pacific:** Southeast Asia
- **EMEA:** North Europe, West Europe, UK South

> **Tip:** If you need DC-series in a region that doesn't currently support it, submit an Azure support request. Microsoft may be able to accommodate the request depending on capacity.

### Managed Instance Hardware

SQL Managed Instance supports three hardware configurations: standard-series (Gen5), premium-series, and premium-series memory optimized. These map to the same underlying Intel processors as their SQL Database counterparts.

When specifying hardware in templates or scripts, use these names:

| Hardware | Template name |
|---|---|
| Standard-series (Gen5) | `Gen5` |
| Premium-series | `G8IM` |
| Memory optimized premium-series | `G8IH` |

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/service-tiers-managed-instance-vcore.md -->

Standard-series (Gen5) is broadly available. Premium-series and premium-series memory optimized availability for Managed Instance follows a similar pattern to SQL Database — check the Azure portal's **Compute + storage** blade for your target region to confirm availability.

## Serverless Compute

Serverless is a compute tier for single databases in Azure SQL Database. It automatically scales compute based on workload demand and bills per second. It supports both the General Purpose and Hyperscale service tiers, but **only on Standard-series (Gen5) hardware**.

<!-- Source: reference/feature-availability-by-region/region-availability.md, azure-sql-database-sql-db/concepts/serverless-tier-overview.md -->

### Where It's Available

Serverless is available in almost every region worldwide. The exceptions are a handful of legacy or sovereign regions:

- China East
- China North
- Germany Central
- Germany Northeast

All regions with serverless support offer at least 40 vCores. Many also support up to 80 vCores for both General Purpose and Hyperscale.

### 80-vCore Serverless Availability

The following table shows which regions support the higher 80-vCore maximum and whether availability zone support is included at that scale.

**Americas:**

| Region | 80 vCores | AZ support (80 vCores) |
|---|---|---|
| Brazil South | ✔ | ✔ |
| Brazil Southeast | ✔ | — |
| Canada Central | ✔ | ✔ |
| Canada East | ✔ | — |
| Mexico Central | ✔ | — |
| Central US | ✔ | ✔ |
| East US | ✔ | ✔ |
| East US 2 | ✔ | ✔ |
| North Central US | ✔ | — |
| South Central US | ✔ | ✔ |
| West Central US | ✔ | — |
| West US | ✔ | — |
| West US 2 | ✔ | ✔ |
| West US 3 | ✔ | ✔ |

**Asia Pacific:**

| Region | 80 vCores | AZ support (80 vCores) |
|---|---|---|
| East Asia | ✔ | ✔ |
| Southeast Asia | ✔ | ✔ |
| Australia Central | ✔ | — |
| Australia Central 2 | ✔ | — |
| Australia East | ✔ | ✔ |
| Australia Southeast | ✔ | — |
| Central India | ✔ | ✔ |
| South India | ✔ | — |
| Japan East | ✔ | ✔ |
| Japan West | ✔ | — |
| Korea Central | ✔ | ✔ |
| Korea South | ✔ | — |

**EMEA:**

| Region | 80 vCores | AZ support (80 vCores) |
|---|---|---|
| North Europe | ✔ | ✔ |
| West Europe | ✔ | ✔ |
| France Central | ✔ | ✔ |
| France South | ✔ | — |
| Germany West Central | ✔ | ✔ |
| Sweden Central | ✔ | ✔ |
| Switzerland North | ✔ | — |
| UAE North | ✔ | ✔ |
| UK South | ✔ | ✔ |
| UK West | ✔ | — |
| South Africa North | ✔ | ✔ |

## Maintenance Windows

Maintenance windows let you schedule Azure's planned maintenance to predictable off-hours slots. By default, the maintenance policy *blocks* updates during 8 AM–5 PM local time (protecting business hours), so most maintenance lands in the 5 PM–8 AM window every day. That default window is wide and unpredictable. Non-default maintenance windows narrow it to one of two slots:

- **Weekday:** 10 PM–6 AM local time, Monday–Thursday
- **Weekend:** 10 PM–6 AM local time, Friday–Sunday

<!-- Source: azure-sql-database-sql-db/concepts/scheduled-maintenance/maintenance-window.md, azure-sql-managed-instance-sql-mi/concepts/scheduled-maintenance/maintenance-window.md -->

### SQL Database

Maintenance window availability for SQL Database depends on two factors: your hardware/tier combination and whether your database is zone-redundant.

**For databases that are not zone-redundant**, non-default maintenance windows are broadly available. Standard-series and DTU-tier databases can configure maintenance windows in nearly every region. However, Hyperscale premium-series maintenance window support is narrower — limited to the larger regions like East US, West US 2, West Europe, North Europe, and similar major hubs.

**For zone-redundant databases**, the list is smaller still. Only the regions that support both zone redundancy and maintenance windows for your specific tier qualify. Major regions like East US, East US 2, West US 3, Canada Central, Australia East, Southeast Asia, Japan East, North Europe, West Europe, Sweden Central, UAE North, and UK South have full support across all tiers.

> **Tip:** If you're deploying with geo-replication or failover groups and your regions are *not* an Azure paired region combo, use *different* maintenance windows for your primary and secondary — for example, weekday for the primary and weekend for the secondary. Azure paired regions are already guaranteed not to be upgraded at the same time, so this trick is only needed for unpaired region combinations.

### SQL Managed Instance

Maintenance windows for SQL Managed Instance are simpler: non-default maintenance windows are **available in all regions**. The MI `maintenance-window` doc lists instance pools as an exception, but the `instance-pools-configure` doc shows a **Maintenance** pane in the portal and PowerShell/CLI commands for configuring pool maintenance windows — suggesting the restriction may have been lifted. Confirm in the Azure portal before relying on either statement.

## Vector Search

Vector search uses DiskANN indexes to enable approximate nearest neighbor queries directly in Azure SQL Database. This is a relatively new capability and regional availability is limited.

<!-- Source: reference/feature-availability-by-region/region-availability.md -->

As of this writing, vector search is available in:

- **North Europe**
- **UK South**

It's not yet available in any Americas or Asia Pacific regions. Expect this list to grow — check the official docs for current status.

> **Note:** Vector search is also supported in SQL database in Microsoft Fabric, which has its own regional availability. See the Fabric region availability documentation if you're using that platform.

## Zone Redundancy

Zone redundancy distributes your database replicas across multiple availability zones within a region, protecting against datacenter-level outages. It's available across all service tiers in the vCore model (General Purpose, Business Critical, and Hyperscale) and in the Premium DTU tier — but not in the Basic or Standard DTU tiers.

<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-sla-local-zone-redundancy.md -->

### SQL Database

Zone redundancy availability depends on the service tier and hardware. Here are the regions with availability zone support for Hyperscale premium-series:

**Americas:** Brazil South, Canada Central, Central US, East US, East US 2, West US 2, West US 3

**Asia Pacific:** Southeast Asia, Australia East, Japan East

**EMEA:** North Europe, West Europe, Germany West Central, Sweden Central, UK South

For Standard-series (Gen5) in General Purpose, Business Critical, or Hyperscale, zone redundancy is supported in a broader set of regions. The general rule: if a region has availability zones, SQL Database zone redundancy is likely supported there.

### SQL Managed Instance

Zone redundancy is available for both the General Purpose and Business Critical tiers in SQL Managed Instance, but in select regions only.

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/instance-zone-redundancy-configure.md -->

Key requirements for MI zone redundancy:

- Backup storage redundancy must be set to **zone-redundant** or **geo-zone-redundant** — you can't enable zone redundancy with locally redundant backups.
- Zone redundancy is **not** currently available for the Next-gen General Purpose service tier.
- The operation to enable or disable zone redundancy is a fully online scaling operation.

> **Gotcha:** You must configure zone-redundant or geo-zone-redundant backup storage *before* you can enable zone redundancy on a Managed Instance. If your instance uses locally redundant backups, you'll need to change that first — and that operation takes time to complete before you can flip the zone redundancy toggle.

### SQL Server on Azure VMs

SQL Server on Azure VMs doesn't have a built-in zone redundancy toggle the way the PaaS services do. Instead, you achieve zone-level resilience by deploying VMs across availability zones and configuring Always On availability groups or failover cluster instances yourself. Zone support depends on the underlying VM SKU availability in each region — check the [Azure products by region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/table) tool for VM availability.
