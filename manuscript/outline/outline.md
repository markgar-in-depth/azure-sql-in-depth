# Azure SQL In Depth — Outline

> This outline is the source of truth for chapter structure, scope, and
> cross-reference checks. The book-writer agent follows it; the book-reviewer
> agent checks against it.

---

## Frontmatter

### Preface
- Who This Book Is For
- How This Book Is Organized
- Conventions Used in This Book
- Setting Up Your Environment (tooling prerequisites)

---

## Part I: The Azure SQL Landscape

*What Azure SQL is, why it exists, and how to choose the right deployment option. No code, no setup — just mental models.*

### Chapter 1: What Is Azure SQL?

- The SQL Server Family in the Cloud
  - Three products, one engine: SQL Database, Managed Instance, SQL Server on Azure VMs
  - The spectrum from fully managed (PaaS) to full control (IaaS)
  - What "managed" actually means: patching, backups, HA — what you give up, what you gain
- IaaS vs. PaaS: The Real Trade-offs ✶ CANONICAL
  - When full control matters (and when it doesn't)
  - The hidden cost of "just run it yourself"
  - Compliance, regulatory, and feature-parity considerations
- A Brief Tour of Each Deployment Option
  - Azure SQL Database: elastic, serverless, multi-tenant
  - Azure SQL Managed Instance: near-100% SQL Server compatibility in PaaS
  - SQL Server on Azure VMs: the full engine, your responsibility
- When to Use What: The Decision Framework ✶ CANONICAL ✶ EXPAND HERE
  - The service selection decision tree
  - Workload characteristics that push you toward each option
  - Common mistakes in choosing a deployment model
  - Anti-patterns: choosing VMs because "it's what we know"
- Modernization and Migration at a Glance
  - Cost optimization paths (Azure Hybrid Benefit, reservations)
  - End-of-support SQL Server: what your options are
  - Where migration guidance lives in this book (→ see Part VII)

### Chapter 2: Core Concepts and Terminology

- The Azure SQL Glossary ✶ CANONICAL
  - Terms that mean different things in Azure SQL vs. on-premises SQL Server
  - Purchasing models: DTU vs. vCore — what they are, how they differ
  - Service tiers: General Purpose, Business Critical, Hyperscale (vCore); Basic, Standard, Premium (DTU)
  - Compute tiers: provisioned vs. serverless
  - Deployment models: single database, elastic pool, managed instance, VM
- The Logical Server (SQL Database) ✶ CANONICAL
  - What a logical server is (and isn't)
  - The management boundary: logins, firewall rules, auditing
  - How logical servers differ from SQL Server instances
- Single Databases and Elastic Pools ✶ CANONICAL
  - Single database: isolated, dedicated resources
  - Elastic pools: shared resources for variable workloads
  - When to pool and when not to — the decision framework
  - Anti-patterns: pooling databases with incompatible workload profiles
- The vCore Purchasing Model ✶ CANONICAL
  - Compute, storage, and backup — how each is billed
  - Hardware generations and configuration choices
  - Service tiers under vCore: General Purpose, Business Critical, Hyperscale
  - Provisioned vs. serverless compute
- The DTU Purchasing Model
  - The bundled model: compute + storage + I/O as a single unit
  - DTU benchmark methodology: how DTUs are calibrated
  - Service tiers under DTU: Basic, Standard, Premium
  - eDTUs for elastic pools
  - When DTU still makes sense (and when to move to vCore)
- Migrating Between Purchasing Models
  - DTU-to-vCore conversion: mapping queries and tooling
- Resource Limits and Governance ✶ CANONICAL
  - What happens when you hit CPU, memory, storage, I/O, session, and worker limits
  - Resource Governor internals: pools, workload groups, FSRM
  - Log rate governance and wait types
  - Tempdb sizing across tiers
  - Understanding the limit tables: how to read them (→ see Appendix A for full reference tables)
- The Feature Comparison Matrix
  - SQL Database vs. Managed Instance vs. SQL Server on VMs: what's supported where (→ see Appendix B)

---

## Part II: Getting Started

*Hands-on setup. Create your first resources, connect, and run queries. The "proof of life" chapters.*

### Chapter 3: Creating Your First Azure SQL Resources

- Provisioning an Azure SQL Database ✶ CANONICAL
  - Portal walkthrough: server, database, firewall
  - The free-tier offer: what you get, limits, and when it resets
  - Choosing a service tier and compute size for your first database
- Provisioning with Infrastructure as Code
  - ARM templates, Bicep, and Terraform for SQL Database
  - When to use IaC vs. portal (spoiler: always IaC for production)
- Provisioning an Azure SQL Managed Instance
  - VNet and subnet requirements: sizing, delegation, NSG, route tables
  - Instance creation: portal, CLI, PowerShell, IaC
  - The free-tier MI offer: 12-month trial with 720 vCore hours and 64 GB storage
  - Instance pools: when shared VMs make sense
  - Why MI provisioning takes longer (and what's happening under the hood) ✶ EXPAND HERE
- Provisioning SQL Server on an Azure VM
  - Marketplace images: editions, versions, OS choices (Windows and Linux)
  - VM sizing for SQL Server: memory-optimized series, vCore customization
  - The SQL IaaS Agent extension: what it does and why you need it
  - Confidential VMs for SQL Server
- Setting Up a Local Development Environment
  - Dev Containers for Azure SQL Database
  - SQL Database Projects in VS Code
  - The inner-loop / outer-loop development lifecycle

### Chapter 4: Connecting and Querying

- Connection Architecture ✶ CANONICAL
  - Gateway routing: Redirect vs. Proxy connection policies
  - Regional gateway IPs and port requirements (1433, 11000–11999)
  - How connections differ across SQL Database, Managed Instance, and SQL Server VMs
- Connectivity Settings
  - Public vs. private network access
  - Minimum TLS version enforcement
  - TLS root certificate rotation: preparing for CA changes
  - Connection types for Managed Instance (redirect vs. proxy)
- Tools for Interactive Queries
  - Azure portal query editor
  - SQL Server Management Studio (SSMS)
  - VS Code with the mssql extension
  - sqlcmd and bcp command-line utilities
- Connecting from Application Code ✶ CANONICAL
  - Connection libraries overview: ADO.NET, JDBC, ODBC, Node.js, Python, PHP, Go, Ruby
  - Building a connection string — the right way
  - Connection pooling fundamentals
  - Retry logic for transient faults ✶ EXPAND HERE
  - Common connectivity errors and how to fix them (→ see Appendix G for full troubleshooting reference)
- Connecting SQL Server on Azure VMs
  - Public, private, and local access modes
  - TCP/IP enablement and NSG rules
  - DNS labels for public connectivity
- Managed Instance Application Connectivity
  - Same-VNet, peered-VNet, on-premises, and App Service connectivity patterns

### Chapter 5: Your First Database Design

- Designing a Schema in Azure SQL ✶ EXPAND HERE
  - Creating tables, foreign keys, and indexes
  - Walk-through: a sample application schema
- Loading Data
  - Bulk loading with bcp
  - Loading CSV data
  - Restoring from BACPAC files
  - Restoring from backup files (Managed Instance and VMs)
- T-SQL Compatibility: What's Different ✶ CANONICAL
  - Unsupported and partially supported T-SQL in SQL Database
  - T-SQL differences in Managed Instance
  - The compatibility surface: where SQL Database and MI diverge from SQL Server
  - Anti-patterns: assuming full T-SQL parity without checking

---

## Part III: Security

*Defense in depth: network, identity, encryption, auditing, and threat detection. Covered early because security decisions affect everything else.*

### Chapter 6: Network Security

- Network Access Controls ✶ CANONICAL
  - IP firewall rules (server-level and database-level)
  - VNet service endpoints and virtual network rules
  - Private Link (private endpoints): eliminating public exposure
  - The "Allow Azure Services" toggle and why it's risky
- Outbound Firewall Rules
  - Restricting egress to approved storage accounts and servers
- Network Security Perimeter (Preview)
  - PaaS-to-PaaS boundary controls
- DNS Aliases
  - Friendly-name indirection for seamless server swaps
- Managed Instance Networking ✶ CANONICAL
  - Virtual clusters and subnet architecture
  - Traffic management: user-managed vs. service-managed flows
  - Public endpoint hardening
  - Private Link endpoints for MI
  - Service-aided subnet configuration
  - Service endpoint policies for storage egress control
- SQL Server VM Networking
  - NSG configuration, firewall rules, and port requirements (→ see Ch4 for connectivity details)

### Chapter 7: Authentication and Identity

- Authentication Methods ✶ CANONICAL
  - SQL authentication: logins, passwords, and why you should stop using them
  - Microsoft Entra (Azure AD) authentication: the modern path
  - Windows Authentication for Entra principals (Managed Instance)
- Microsoft Entra Authentication Deep Dive ✶ CANONICAL
  - Identity types: users, groups, service principals, managed identities
  - Auth flows: password, MFA interactive, integrated, default (passwordless), token-based
  - The Microsoft Entra admin role
  - Directory Readers role and Microsoft Graph permissions
  - Conditional Access policies for Azure SQL
- Creating Entra Principals
  - Server-level logins (CREATE LOGIN)
  - Contained database users
  - Guest users (B2B)
  - Service principal and managed identity users
- Entra-Only Authentication ✶ EXPAND HERE
  - Disabling SQL auth entirely
  - Azure Policy enforcement at scale
  - What happens to existing SQL logins
- Migrating to Passwordless Connections ✶ EXPAND HERE
  - .NET, Node.js, and Python walk-throughs
  - DefaultAzureCredential and managed identity patterns
  - Anti-patterns: storing connection strings with passwords in app settings
- Identity for SQL Server on Azure VMs
  - Microsoft Entra auth (SQL Server 2022+)
  - Managed identity EKM for Key Vault access

### Chapter 8: Data Protection and Encryption

- Transparent Data Encryption (TDE) ✶ CANONICAL
  - Service-managed keys: enabled by default, zero configuration
  - Customer-managed keys (BYOK): Azure Key Vault and Managed HSM
  - Managed identities for Key Vault access
  - Database-level CMK for multi-tenant isolation
  - Cross-tenant key access via workload identity federation
  - Key rotation: automatic and manual
  - TDE protector inheritance across geo-replication and restores
  - Incident response: revoking a compromised key
- Always Encrypted ✶ CANONICAL
  - Client-side column encryption: key management and cryptography
  - Column master keys and column encryption keys
  - Getting started with Always Encrypted via SSMS
- Always Encrypted with Secure Enclaves
  - Intel SGX vs. VBS enclaves: trade-offs and hardware requirements
  - Attestation via Azure Attestation
  - Rich queries on encrypted data
  - When to use enclaves (and when plain Always Encrypted suffices)
- Dynamic Data Masking
  - Policy-based obfuscation for non-privileged users
  - Masking rules and built-in masking functions
- Row-Level Security
  - Tenant isolation in multi-tenant databases (→ see Ch17 for SaaS patterns)
- Azure Key Vault Integration for SQL Server VMs
  - EKM provider setup for TDE, CLE, and backup encryption

### Chapter 9: Auditing, Compliance, and Threat Detection

- SQL Auditing ✶ CANONICAL
  - Server-level vs. database-level audit policies
  - Destination choices: Azure Storage, Log Analytics, Event Hubs
  - Managed identity authentication for auditing
  - Audit log schema and analysis (KQL, SSMS, Power BI)
  - Auditing Microsoft support operations (DevOps audit logs)
  - Best practices: geo-replication auditing, storage key rotation, Key Vault-encrypted storage
  - Auditing on Managed Instance
- Microsoft Defender for SQL
  - Vulnerability Assessment: scan configuration and storage behind firewalls
  - Advanced Threat Protection: SQL injection, brute force, anomalous access detection
- Data Discovery and Classification ✶ EXPAND HERE
  - Automated sensitive-data discovery and labeling
  - Built-in and custom classification labels (sensitivity labels, information types)
  - Compliance reporting and audit integration
- Ledger Tables
  - Blockchain-inspired tamper-evidence for relational data
  - Append-only and updatable ledger tables
  - Database-level ledger configuration
  - Digest management and cryptographic verification
  - When to use ledger (and when it's overkill)
- Azure Policy for Azure SQL
  - Built-in policy definitions: TDE, Entra-only auth, TLS, private endpoints, auditing
  - Regulatory compliance controls (FedRAMP, PCI DSS, ISO 27001, NIST, SOC)
  - Blocking T-SQL CRUD for ARM-only governance

---

## Part IV: Hyperscale, High Availability, Disaster Recovery, and Backups

*The Hyperscale deep dive, then keeping your data alive, recoverable, and resilient.*

### Chapter 10: The Hyperscale Service Tier

- Hyperscale Architecture ✶ CANONICAL
  - Distributed design: compute nodes, page servers, log service, Azure Storage
  - How Hyperscale differs from General Purpose and Business Critical
  - Scaling model: independent compute and storage, up to 128 TB
- Hyperscale Replicas ✶ CANONICAL
  - HA replicas: hot standby and automatic failover
  - Named replicas: independent read scale-out (up to 30)
  - Geo-replicas for cross-region DR
  - Named replica security isolation
- Hyperscale Elastic Pools
  - Shared compute and log resources across pooled Hyperscale databases
  - Independent page servers per database
  - Creating and scaling Hyperscale elastic pools
- Migrating To and From Hyperscale
  - Online conversion from other service tiers
  - Reverse migration to General Purpose (45-day window)
- Hyperscale Serverless
  - Auto-scaling vCores and auto-pause in Hyperscale
- Hyperscale Performance Diagnostics ✶ EXPAND HERE
  - Log rate waits and page server reads
  - Virtual file stats and local SSD cache analysis
  - Diagnostics unique to the distributed architecture
- When to Choose Hyperscale ✶ EXPAND HERE
  - Decision criteria: database size, I/O profile, read scale-out needs
  - What you lose: no reverse migration after 45 days
  - Anti-patterns: choosing Hyperscale for small databases just for the name

### Chapter 11: Backups and Restore

- Automated Backups ✶ CANONICAL
  - Backup frequency: full, differential, log
  - Storage redundancy options: LRS, ZRS, GRS, GZRS
  - Short-term retention (1–35 days) and configuration
  - How backups differ across SQL Database, Managed Instance, and VMs
- Long-Term Retention (LTR) ✶ CANONICAL
  - Policy-based archival: weekly, monthly, yearly for up to 10 years
  - Configuration via portal, PowerShell, CLI
- Backup Immutability (SQL Database)
  - WORM storage for regulatory compliance (SEC 17a-4, FINRA 4511)
  - Time-based and legal hold modes
- Accelerated Database Recovery (ADR) ✶ EXPAND HERE
  - How ADR redesigns crash recovery: persistent version store, logical revert, aggressive log truncation
  - ADR is enabled by default in Azure SQL Database — what this means for your workloads
  - Impact on long-running transactions, transaction log growth, and recovery time
  - When ADR makes a difference (and when it's invisible)
- Restore Paths ✶ CANONICAL
  - Point-in-time restore (PITR)
  - Deleted-database restore
  - Geo-restore from geo-redundant backups
  - Long-term retention restore
  - Deleted-server restore (Preview)
  - Cross-instance and cross-subscription restore (Managed Instance)
  - Restore to SQL Server from Managed Instance
- Hyperscale Backup and Restore
  - Snapshot-based near-instant backups
  - Size-independent PITR
  - How Hyperscale backups differ from other tiers (→ see Ch10)
- Backup Transparency (Managed Instance)
  - Querying backup history via msdb tables
- SQL Server VM Backup Strategies
  - Automated Backup via the IaaS Agent extension
  - Azure Backup (enterprise-grade)
  - Manual backup-to-URL and managed backup
  - File-snapshot backup for near-instant recovery
  - Managed identity for backup/restore to URL

### Chapter 12: High Availability

- Availability Architectures ✶ CANONICAL
  - The three HA models: remote storage (GP), local storage (BC), Hyperscale
  - Local redundancy vs. zone redundancy
  - SLA implications of each architecture
  - Read scale-out on Business Critical and Hyperscale tiers
- Zone Redundancy
  - Enabling zone redundancy for SQL Database (single and pooled)
  - Zone redundancy for Managed Instance
  - Zone redundancy for Hyperscale
  - Cost implications and reservation considerations
- Planned Maintenance and Maintenance Windows ✶ CANONICAL
  - Reconfiguration behavior and expected downtime
  - Choosing a maintenance window (weekday, weekend, default)
  - Advance notifications via Azure Service Health
  - Retry logic during maintenance events
- SQL Server VM High Availability ✶ CANONICAL
  - Windows Server Failover Clustering on Azure VMs
  - Always On Availability Groups
    - Overview: replicas, synchronization modes, and automatic failover
    - Cross-region replicas for DR
  - Failover Cluster Instances (FCI)
    - Shared storage concepts and when to choose FCI
  - When to use AG vs. FCI vs. log shipping
  - Anti-patterns: single-subnet AG with load balancer when multi-subnet is available
  - Deep cluster tuning, AG connectivity, and FCI storage configuration (→ see Ch28)

### Chapter 13: Disaster Recovery

- Active Geo-Replication (SQL Database) ✶ CANONICAL
  - Async replication to up to four readable secondaries
  - Planned and forced failover
  - Security configuration for geo-replicas
  - Geo-replication for rolling upgrades with zero downtime
- Failover Groups ✶ CANONICAL
  - Multi-database coordinated geo-failover
  - DNS listener endpoints: read-write and read-only
  - Customer-managed vs. Microsoft-managed failover policies
  - Failover groups for SQL Database (single and pooled)
  - Failover groups for Managed Instance
  - License-free standby replicas for cost savings
- DR Design Patterns ✶ EXPAND HERE
  - Multi-region DR with Traffic Manager
  - Elastic pool DR strategies for multi-tenant SaaS (→ see Ch17 for SaaS tenancy patterns)
  - Choosing between geo-replication and failover groups
  - Decision framework: RTO/RPO targets → mechanism selection
- Outage Response ✶ EXPAND HERE
  - Detecting service outages
  - Deciding when to initiate failover
  - Recovery escalation: waiting → failover group → forced failover → geo-restore
- DR Drills
  - Validating recovery readiness: geo-restore and failover-group tests
- HA/DR Readiness Checklist
  - Consolidated checklist for SQL Database, Managed Instance, and VMs
- Cross-Region Migration
  - Moving databases and instances to a new Azure region using failover groups
- SQL Server VM DR Options
  - Log shipping for async DR
  - Backup/restore and Azure Site Recovery
  - Cross-region AG replicas

---

## Part V: Performance and Monitoring

*Understanding, measuring, and improving the performance of your Azure SQL workloads.*

### Chapter 14: Monitoring and Observability

- The Azure SQL Monitoring Stack ✶ CANONICAL
  - Azure Monitor: platform metrics, resource logs, activity logs
  - Diagnostic settings: streaming to Log Analytics, Event Hubs, Storage
  - Key metrics: CPU, DTU/vCore, I/O, storage, sessions, workers, connections
  - Elastic pool-specific metrics
  - Serverless billing metrics
  - Availability metric
- Database Watcher (Preview)
  - Architecture: managed, agentless monitoring from 70+ DMVs
  - Data store: Azure Data Explorer or Fabric Real-Time Analytics
  - Dashboards: estate-level and resource-level workbooks
  - Alert rule templates
- Query Store ✶ CANONICAL
  - Enabled by default: what it captures and why it matters
  - Configuring Query Store: storage size, capture mode, stale query cleanup
  - Reading Query Store data: top resource consumers, regressed queries, plan history
  - Forced plans: pinning a known-good plan to prevent regression
  - Query Store as the foundation for automatic tuning, Query Performance Insight, and deadlock analysis
- Query Performance Insight
  - Portal dashboard: top queries by CPU, duration, execution count
  - Built on Query Store data
- DMV-Based Diagnostics ✶ CANONICAL
  - sys.dm_db_resource_stats and sys.resource_stats
  - Concurrent requests, sessions, and workers
  - CPU, I/O, and tempdb diagnostics
  - Memory grants, blocking, deadlocks, and long-running transactions
  - Elastic pool resource stats
- Extended Events ✶ CANONICAL
  - Ring buffer target for ad-hoc troubleshooting
  - Event file target with Azure Blob Storage
  - Azure-specific scoping and T-SQL differences
- Alerting
  - Metric and activity-log alerts via Azure Monitor
  - CPU, DTU, size, and resource-health event alerts
- Azure Resource Health
  - Health states: Available, Degraded, Unavailable, Unknown
  - Connectivity diagnostics and downtime reasons
- Monitoring Managed Instance
  - Instance-level metrics and resource logs
  - Backup monitoring via msdb and Extended Events
- Monitoring SQL Server VMs
  - SQL best practices assessment via SQL Assessment API
  - I/O performance analysis: VM-level and disk-level throttling detection

### Chapter 15: Performance Tuning

- Query Performance Bottleneck Detection ✶ CANONICAL
  - Running vs. waiting states
  - Suboptimal query plans and plan regression
  - Parameter-sensitive plan (PSP) problems
  - Missing indexes and improper parameterization
  - Resource limit bottlenecks
  - Wait category analysis
- Automatic Tuning ✶ CANONICAL
  - FORCE_LAST_GOOD_PLAN: automatic plan regression correction
  - CREATE_INDEX and DROP_INDEX recommendations
  - Auto-validation and rollback
  - Server-level vs. database-level configuration
- Database Advisor
  - Index and query-plan recommendations
  - Viewing, applying, and discarding recommendations via portal
- Intelligent Insights (Preview)
  - AI-based anomaly detection: 15 performance degradation patterns
  - Diagnostics log format and integration
- High-CPU Diagnosis ✶ EXPAND HERE
  - Identifying top CPU-consuming queries
  - Plan regression and excessive parallelism
  - MAXDOP configuration
- Blocking and Deadlock Analysis ✶ CANONICAL
  - RCSI and snapshot isolation defaults in Azure SQL
  - Identifying and resolving long-held locks
  - Deadlock graphs and Query Store analysis
  - Optimized locking: TID-based locking and lock-after-qualification
- Application-Level Tuning Guidance
  - Chatty-app anti-patterns
  - Client-side batching: TVPs, SqlBulkCopy, BULK INSERT
  - Missing index identification and creation
  - Sharding, caching, and query hint strategies

### Chapter 16: In-Memory Technologies

- In-Memory OLTP ✶ CANONICAL
  - Memory-optimized tables: architecture and data durability
  - Natively compiled stored procedures and inline functions
  - Migration path: the Memory Optimization Advisor
  - Storage caps and resource governance per service tier
- Columnstore Indexes ✶ CANONICAL
  - Clustered vs. nonclustered columnstore
  - Batch-mode execution and analytics acceleration
  - HTAP: combining rowstore and columnstore for operational analytics
- Monitoring In-Memory Workloads
  - XTP-specific DMVs and wait types
  - Memory consumption tracking and limits
  - Columnstore segment health and dictionary pressure
- When to Use In-Memory (and When Not To) ✶ EXPAND HERE
  - Decision framework: OLTP acceleration vs. analytics vs. HTAP
  - Anti-patterns: forcing in-memory on workloads that don't benefit

---

## Part VI: Data Management and Application Patterns

*Moving data, building applications, and designing for real-world patterns.*

### Chapter 17: Data Modeling and Multi-Tenant Patterns

- Multi-Model Data Capabilities
  - JSON: FOR JSON, OPENJSON, scalar functions, JSON indexing
  - Graph data, XML, and spatial data
  - Temporal tables: system-versioned history tracking
  - Temporal history retention policies ✶ EXPAND HERE
    - Per-table retention periods for automatic history cleanup
    - Managing history growth at scale: when and how to configure age-out
- SaaS Tenancy Patterns ✶ CANONICAL ✶ EXPAND HERE
  - Standalone single-tenant
  - Database-per-tenant
  - Single multitenant database with row-level security
  - Sharded multitenant
  - Hybrid models
  - Comparison matrix: scalability, isolation, cost, complexity
  - Anti-patterns: choosing a model without understanding the trade-offs
- Putting It All Together: Choosing Your Data Architecture ✶ EXPAND HERE
  - Decision framework: relational-only vs. multi-model vs. sharded
  - Matching tenancy patterns to workload characteristics
  - Common anti-patterns in Azure SQL data architecture

### Chapter 18: Moving Data

- BACPAC Import and Export ✶ CANONICAL
  - Portal, SqlPackage, SSMS, and managed identity workflows
  - Import/export with Azure services access disabled
  - Import/export over Private Link
- Database Copy
  - Transactionally consistent snapshots within or across servers
- Change Data Capture (CDC)
  - Row-level change tracking via an in-database scheduler
  - vCore model requirements (or S3+ in DTU)
- Transactional Replication
  - SQL Server or Managed Instance as publisher, SQL Database as subscriber
  - MI-to-MI and MI-to-SQL Server topologies
- Database Copy and Move (Managed Instance)
  - Online cross-instance replication using Always On AGs
- SQL Data Sync (Retiring September 2027)
  - Hub-and-spoke bi-directional sync
  - Migration alternatives: ADF, transactional replication, Fabric mirroring
- Elastic Database Transactions
  - Distributed two-phase-commit across multiple databases
  - System.Transactions and .NET integration
- Distributed Transaction Coordinator (Managed Instance)
  - Managed DTC for SQL MI, SQL Server, and external RDBMS

### Chapter 19: Scaling Out with Elastic Database Tools

- Horizontal Sharding Architecture ✶ CANONICAL
  - Horizontal vs. vertical scaling
  - Single-tenant and multi-tenant shard patterns
- The Elastic Database Client Library
  - Shard map management: list and range shard maps
  - Data-dependent routing: connecting to the correct shard
  - Multi-shard fan-out queries
- Split-Merge Service
  - Online shardlet movement, splitting, and merging
  - Deployment and security configuration
- Cross-Database Elastic Queries (Preview)
  - Vertical partitioning: querying across databases with different schemas
  - Horizontal partitioning via shard maps (shard map manager mode end-of-support March 2027)
- ORM Integration
  - Entity Framework with data-dependent routing
  - Dapper with OpenConnectionForKey
- Shard Map Recovery and Operations
  - GSM/LSM inconsistency repair after failover or restore
  - Performance counters and client library upgrades
- When to Shard (and When Not To) ✶ EXPAND HERE
  - Anti-patterns: sharding prematurely, poor shard key selection
  - Hyperscale as an alternative to sharding for large databases

### Chapter 20: Building Applications on Azure SQL

- Application Connectivity Fundamentals (→ see Ch4 for connection setup)
  - ADO.NET port architecture for direct-route connections
  - Service principal authentication for app-to-database access
- Kubernetes Application Development
  - Python/Flask with Docker, AKS, and Azure SQL Database backend
- CI/CD Integration
  - GitHub Actions for dacpac schema deployment
  - OIDC and service-principal authentication workflows
- DR-Aware Application Design ✶ EXPAND HERE
  - Multi-region patterns with failover groups and Traffic Manager
  - Rolling upgrades via geo-replication
  - Elastic pool DR strategies for SaaS applications
- Azure Stream Analytics Integration (Preview)
  - Real-time event ingestion from Event Hubs / IoT Hub into SQL Database
- Automation and Job Scheduling
  - Elastic jobs: cross-database T-SQL execution at scale ✶ CANONICAL
    - Job agents, target groups, scheduling, and authentication
    - Managed private endpoints for secure connectivity
  - SQL Agent on Managed Instance
    - Multi-step workflows, retries, Database Mail notifications
  - Azure Automation runbooks
  - Comparing elastic jobs, SQL Agent, Synapse pipelines, and Fabric
- AI and Copilot Integration
  - RAG patterns with Azure OpenAI and vector data
  - Vector data type, vector functions, and embeddings
  - SQL MCP Server for agent-driven data access
  - Microsoft Copilot in Azure for SQL Database: natural-language administration

---

## Part VII: Migration

*Moving workloads to Azure SQL — from planning to post-migration optimization.*

### Chapter 21: Migration Planning

- The Migration Decision Framework ✶ CANONICAL ✶ EXPAND HERE
  - Choosing the right target: SQL Database vs. Managed Instance vs. VM
  - Workload assessment and compatibility analysis
  - SKU recommendations and right-sizing
  - Cost estimation: Azure Hybrid Benefit, reservations, licensing models
- Pre-Migration Assessment
  - Azure Migrate and Data Migration Assistant
  - Assessment rules: compatibility checks and blocking-issue detection
  - Performance baselining: capturing source workload metrics
- Migration Methods Overview
  - Backup/restore, log shipping, DMS, Azure Migrate, detach/attach, VHD upload
  - Lift-and-shift vs. modernize: which path for which workload
- Migrating from Non-Microsoft Databases
  - SQL Server Migration Assistant (SSMA) for Access, Db2, MySQL, Oracle, SAP ASE
  - Schema conversion, data type mapping, and data migration lifecycle

### Chapter 22: Migrating to Azure SQL Database

- Migration Paths for SQL Database
  - Azure Database Migration Service (online and offline)
  - BACPAC import
  - Transactional replication
  - Custom RBAC roles for migration workflows
- Post-Migration Operations ✶ CANONICAL
  - Monitoring, BCDR, and security configuration
  - Authentication, firewall, auditing, TDE, Always Encrypted
  - Data movement via BCP/BACPAC/elastic query
- T-SQL Compatibility Gaps (→ see Ch5 for the full reference)
  - Critical differences and workarounds

### Chapter 23: Migrating to Azure SQL Managed Instance

- Migration Paths for Managed Instance ✶ CANONICAL
  - Log Replay Service (LRS): free log-shipping-based migration
  - The Managed Instance Link: near-real-time replication via distributed AGs
    - Environment preparation and configuration (SSMS and scripts)
    - Online migration with planned failover cutover
    - Best practices and troubleshooting
    - Ongoing hybrid DR and bidirectional failover (→ see Ch27)
  - Azure Database Migration Service
  - Native backup/restore from Azure Blob Storage
  - LRS vs. MI Link: choosing the right approach
- TDE Certificate Migration
  - Exporting and uploading the TDE certificate before restoring encrypted databases
- Windows-to-Entra Identity Migration
  - Remapping on-premises Windows users/groups to Entra logins
- Post-Migration Validation
  - Performance baselining comparison
  - Compatibility assessment rule resolution

### Chapter 24: Migrating to SQL Server on Azure VMs

- Migration Strategies ✶ CANONICAL
  - Lift-and-shift via Azure Migrate (preserving OS and SQL version)
  - Migrate: backup/restore, log shipping, detach/attach, VHD conversion
  - Distributed availability group migration (near-zero downtime for large databases)
  - Azure Database Migration Service
- Migrating High-Availability Configurations
  - Always On availability group migration
  - Failover cluster instance migration
- Migrating BI Services
  - SSIS, SSRS, SSAS migration considerations
- Server Object Migration
  - Logins, Agent jobs, linked servers

---

## Part VIII: Operations and Administration

*Day-to-day management, cost optimization, and advanced operational patterns.*

### Chapter 25: Day-to-Day Administration

- SQL Database Administration ✶ CANONICAL
  - Creating, scaling, and configuring single databases
  - Elastic pool lifecycle: create, scale, move databases
  - Dense elastic pool resource management and noisy-neighbor mitigation
  - File space management: allocated vs. used, reclaiming unused space
  - Database restart for transient issues
  - Quota management: checking limits, requesting increases, capacity planning
- Managed Instance Administration
  - Management operations: create, update, delete — phases and durations
  - Operation cancellation and monitoring
  - Instance stop/start for cost savings (General Purpose)
  - Database copy and move across instances
  - File space management
  - Update policy: SQL Server 2022, 2025, or Always-up-to-date
  - Time zone selection
  - Tempdb tuning
- SQL Server VM Administration
  - Portal-based management via the SQL VM resource
  - License model switching (PAYG, AHB, DR replica)
  - In-place edition and version changes
  - Servicing and patching: Azure Update Manager, automated patching
  - Storage migration to Ultra Disk
  - Cross-region VM migration via Azure Site Recovery

### Chapter 26: Cost Management and Optimization

- Understanding Azure SQL Billing ✶ CANONICAL
  - vCore vs. DTU cost structures
  - Provisioned vs. serverless metering
  - Storage and backup billing
  - Elastic pool cost sharing
- Saving Money ✶ EXPAND HERE
  - Azure Hybrid Benefit: license portability
  - Azure Reservations: 1- and 3-year compute commitments
  - Serverless auto-pause: paying only when active
  - License-free standby replicas
  - VM pricing: pay-as-you-go, AHB, free editions, auto-shutdown
  - Dedicated hosts for license-dense deployments
  - Extended Security Updates: free on Azure VMs
  - Right-sizing: using metrics to downsize over-provisioned resources
  - Anti-patterns: over-provisioning "just in case"
- Budget Monitoring and Alerts
  - Azure Cost Management integration

### Chapter 27: Azure SQL Managed Instance — Advanced Topics

- The Managed Instance Link ✶ CANONICAL
  - Link architecture: distributed availability groups
  - Bidirectional failover for hybrid DR (SQL Server 2022+) ✶ CANONICAL
  - Ongoing hybrid replication scenarios
  - Migration use of MI Link (→ see Ch23)
- Data Virtualization
  - Querying Parquet/CSV in Azure Blob Storage and ADLS Gen2
  - OPENROWSET and external tables without data movement
- SQL Server Engine Features in Managed Instance
  - Transactional replication: publisher/distributor/subscriber topologies
  - Service Broker, Database Mail, and linked servers
  - Server trust groups for distributed transactions
- Machine Learning Services
  - In-database Python and R via sp_execute_external_script
  - Model training, PREDICT scoring, and operationalization
  - SQL MI vs. SQL Server ML differences
- Next-gen General Purpose Service Tier
  - Elastic SAN-backed storage with independent vCore/memory/IOPS scaling
- Windows Authentication for Entra Principals
  - Kerberos-based auth for lift-and-shift of legacy apps

### Chapter 28: SQL Server on Azure VMs — Advanced Topics

- Storage Deep Dive ✶ CANONICAL
  - Disk type selection: Premium SSD, Premium SSD v2, Ultra Disk
  - Storage Spaces striping and caching policies
  - Tempdb on local ephemeral SSD
  - Azure Elastic SAN as shared block storage
- HADR Deep Dive ✶ CANONICAL
  - Cluster Tuning
    - Heartbeat and threshold settings
    - Quorum options: cloud witness, disk witness, file-share witness
    - Multi-subnet deployment and availability-zone placement
  - Availability Group Connectivity
    - Multi-subnet vs. single-subnet deployment patterns
    - VNN vs. DNN listeners: trade-offs and configuration
    - Portal-based vs. manual AG configuration
  - FCI Storage Configuration
    - Shared storage options: Azure shared disks, premium file shares, Storage Spaces Direct, Elastic SAN
    - FCI VM preparation and connectivity (VNN, DNN)
- Security Hardening
  - Microsoft Defender for SQL on VMs
  - Disk encryption and confidential VMs
  - JIT access, NSGs, and FIPS compliance
- Application Architecture Patterns
  - 1-tier, 2-tier, 3-tier, and n-tier topologies
- SQL Server on Linux VMs
  - Supported versions and distributions
  - SQL IaaS Agent extension for Linux
  - Pacemaker HA with STONITH fencing (RHEL, SLES, Ubuntu)
  - AG listener via Azure Load Balancer
- Modernization Advisor
  - Assessing VM workloads for migration to Managed Instance

---

## Appendices

### Appendix A: Resource Limits Quick Reference ✶ CANONICAL
- Single database limits: DTU and vCore (complete reference tables)
- Elastic pool limits: DTU and vCore (complete reference tables)
- Managed Instance resource limits by service tier and hardware (complete reference tables)
- SQL Server VM sizing recommendations
- This appendix is the sole location for detailed limit tables; Chapter 2 covers the concepts

### Appendix B: Feature Comparison Matrix
- Azure SQL Database vs. Managed Instance vs. SQL Server on VMs ✶ CANONICAL
- Detailed feature-by-feature support status

### Appendix C: Regional Feature Availability
- Hardware SKU availability by region
- Serverless, maintenance windows, vector search, zone redundancy by region

### Appendix D: Client Drivers and Connection Libraries
- ADO.NET, JDBC, ODBC, Node.js, Python, PHP, Go, Ruby — version and feature matrix

### Appendix E: Azure CLI and PowerShell Quick Reference
- Common CLI commands for SQL Database, Managed Instance, and SQL Server VMs
- Common PowerShell cmdlets

### Appendix F: ARM Template, Bicep, and Terraform Samples
- Infrastructure-as-code templates for provisioning across all deployment options

### Appendix G: Troubleshooting Reference
- Transient fault handling and retry patterns (→ see Ch4)
- Common connectivity errors and resolution steps
- Capacity provisioning errors and quota increase requests
- Out-of-memory diagnostics
- Transaction log full errors
- Import/export performance issues
- Geo-replication redo lag diagnostics
- SQL Managed Instance known issues
