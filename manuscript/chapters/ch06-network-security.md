# Chapter 6: Network Security

Your database can have perfect encryption, flawless authentication, and row-level security on every table — but if the network path to it is wide open, none of that matters. Network security is the first gate. Azure SQL gives you multiple layers of controls, from simple IP allowlists to fully private connectivity that never touches the public internet. The right combination depends on your deployment model — SQL Database, Managed Instance, and SQL Server on VMs each have fundamentally different network architectures — so this chapter walks through every option, starting with the broadest controls and working toward the tightest.

## Network Access Controls for SQL Database
<!-- Source: azure-sql-database-sql-db/concepts/security/network-access-controls-overview.md -->

When you create a logical server in Azure SQL Database, you get a public endpoint: `yourservername.database.windows.net`. By default, the server's firewall blocks all connections. Nothing gets through until you explicitly open the door — and you have several ways to do it.

### IP Firewall Rules

IP firewall rules are the simplest access control. They allow specific IP addresses or ranges, and come in two flavors:

- **Server-level rules** apply to every database on the logical server. You can manage them through the Azure portal, PowerShell, Azure CLI, or T-SQL (`sp_set_firewall_rule`).
- **Database-level rules** apply to individual databases and can only be managed through T-SQL (`sp_set_database_firewall_rule`).
<!-- Source: azure-sql-database-sql-db/how-to/security/firewall-configure.md -->

The server supports up to 256 server-level IP firewall rules. Each database supports up to 256 database-level rules. Changes to IP rules can take up to five minutes to propagate.

When a connection comes in, the firewall checks database-level rules first. If no match, it falls back to server-level rules. If neither matches, the connection is denied.

```sql
-- View existing server-level rules
SELECT * FROM sys.firewall_rules ORDER BY name;

-- Add a server-level rule
EXEC sp_set_firewall_rule
    @name = N'CorpOffice',
    @start_ip_address = '203.0.113.0',
    @end_ip_address = '203.0.113.255';

-- Add a database-level rule (run in the target database)
EXEC sp_set_database_firewall_rule
    @name = N'AppServerPool',
    @start_ip_address = '10.1.4.0',
    @end_ip_address = '10.1.4.255';
```

> **Tip:** Use database-level rules when different databases on the same server need different access profiles. They give you per-database isolation without touching the server-wide configuration.

### The "Allow Azure Services" Toggle

The Azure portal shows a setting called **Allow Azure services and resources to access this server**. Behind the scenes, this creates a server-level firewall rule with start and end IP of `0.0.0.0`.
<!-- Source: azure-sql-database-sql-db/concepts/security/network-access-controls-overview.md, azure-sql-database-sql-db/how-to/security/firewall-configure.md -->

This sounds convenient. It's also dangerously broad.

> **Warning:** The "Allow Azure services" setting opens your server to *all* Azure IP addresses across *all* tenants — not just your subscription, resource group, or VNet. Any VM, Function App, or service anywhere in Azure with outbound connectivity can reach your server's public endpoint. In production, turn it off and use VNet service endpoints or Private Link instead.

Disabling this toggle breaks a few features that depend on it — notably the Import/Export Service and Data Sync. For Import/Export, use `SqlPackage` from a VM in your VNet instead. For Data Sync, add individual IP rules using the `Sql` service tag for your region.

### VNet Service Endpoints and Virtual Network Rules
<!-- Source: azure-sql-database-sql-db/concepts/security/vnet-service-endpoint-rule-overview.md -->

**Virtual network rules** let you allow traffic from specific subnets in your Azure virtual network. They're tighter than IP rules because they're identity-aware at the network level — traffic comes from your subnet, not just an IP range that might be shared.

To use them, you first enable a **VNet service endpoint** for `Microsoft.Sql` on the subnet. Then you create a virtual network rule on the server that references that subnet.

Virtual network rules apply at the server level — you can't scope them to individual databases. Each server supports up to 128 virtual network ACL entries. The subnet and the server must be in the same Azure region, and both subscriptions must be in the same Microsoft Entra tenant.

> **Gotcha:** VNet service endpoints don't work with site-to-site VPNs or ExpressRoute. If your on-premises clients connect through those, use IP firewall rules for their NAT addresses or switch to Private Link.

Setting up a virtual network rule requires cooperation between two roles: a **Network Admin** (Network Contributor) enables the service endpoint on the subnet, and a **Database Admin** (SQL Server Contributor) creates the virtual network rule on the server. Plan your deployment accordingly.

### Private Link (Private Endpoints)
<!-- Source: azure-sql-database-sql-db/concepts/security/private-endpoint-overview.md -->

**Private Link** is the strongest network isolation option for SQL Database. It creates a **private endpoint** — a network interface with a private IP address in your VNet — that maps directly to your logical server. Traffic between your VNet and the server travels entirely over the Microsoft backbone network. The public endpoint never enters the picture.

Private endpoints can be accessed from:

- The same VNet
- Peered VNets (same region or cross-region)
- On-premises networks via ExpressRoute, private peering, or VPN tunneling

> **Important:** Always connect using the server's fully qualified domain name (`yourserver.database.windows.net`), not the private IP or the `privatelink.database.windows.net` FQDN. Connections to the IP address or the privatelink FQDN fail because the SQL Gateway needs the correct FQDN to route logins.

Adding a private endpoint doesn't automatically block public access. You must explicitly set **Deny public network access** on the server's networking page to close off the public endpoint. Without this step, your server is reachable through both paths.

#### Redirect with Private Endpoints

For the best performance, use the **Redirect** connection policy with private endpoints. Redirect sends the first packet through the gateway, then subsequent traffic flows directly to the database node — cutting latency and improving throughput.

To use Redirect with private endpoints, your network must allow **inbound** traffic on ports 1433–65535 to the VNet hosting the private endpoint, and **outbound** traffic on ports 1433–65535 from the VNet hosting the client. If you can't open that range, set the connection policy to **Proxy** (which uses only port 1433) and accept the performance tradeoff.

#### Data Exfiltration Prevention

Private Link is also your best tool against data exfiltration. With VNet service endpoints, a compromised insider can still reach any server in the same region. With Private Link, each private endpoint maps to exactly one logical server. Combined with NSGs on the private endpoint's subnet, you can lock down access to a single server and nothing else.

## Outbound Firewall Rules
<!-- Source: azure-sql-database-sql-db/concepts/security/outbound-firewall-rule-overview.md -->

Inbound rules control who can talk to your database. **Outbound firewall rules** control where your database can talk to. They restrict egress traffic from your logical server to a customer-defined list of Azure Storage accounts and other Azure SQL Database logical servers.

Outbound rules apply to these features only:

- Auditing
- Vulnerability assessment
- Import/Export Service
- `OPENROWSET`
- `BULK INSERT`
- `sp_invoke_external_rest_endpoint`

Other outbound traffic is unaffected.

To enable outbound restrictions, go to **Security → Networking → Outbound networking** and check **Restrict outbound networking**. Then add the fully qualified domain names of allowed storage accounts and SQL servers.

```azurecli
# Enable outbound restrictions
az sql server update -n myserver -g mygroup \
    --set restrictOutboundNetworkAccess="Enabled"

# Allow a specific storage account
az sql server outbound-firewall-rule create \
    -g mygroup -s myserver \
    --outbound-rule-fqdn mystorage.blob.core.windows.net
```

> **Gotcha:** Outbound firewall rules are defined at the logical server level. If you're using geo-replication or failover groups, define the same rules on both the primary and all secondaries.

## Network Security Perimeter (Preview)
<!-- Source: azure-sql-database-sql-db/concepts/security/network-security-perimeter.md -->

**Network Security Perimeter** is a preview feature that draws a boundary around multiple Azure PaaS services — SQL Database, Azure Storage, Key Vault, and others — and controls traffic between them as a group. Any communication with resources outside the perimeter is blocked unless you create explicit access rules.

Think of it as a virtual DMZ for PaaS. Instead of configuring firewall rules on each service individually, you define inbound and outbound access rules on the perimeter itself. Source types for inbound rules include IP addresses, subscriptions, and other network security perimeters.

The perimeter starts in **Learning Mode**, which logs all traffic without blocking anything. Once you're confident in the rules, switch to **Enforced** mode. Denied connections in Enforced mode return `Error 42118: Login failed because the network security perimeter denied inbound access.`

> **Note:** Network Security Perimeter can't be used with a logical server that contains dedicated SQL pools (formerly SQL DW). This is a current limitation of the preview.

This feature is still in preview, so don't rely on it for production workloads yet. But it's worth watching — it addresses a real gap in PaaS-to-PaaS boundary control that today requires a patchwork of Private Link, service endpoints, and outbound rules.

## DNS Aliases
<!-- Source: azure-sql-database-sql-db/concepts/security/dns-alias-overview.md -->

**DNS aliases** provide friendly-name indirection for your logical server. Instead of connecting to `myserver.database.windows.net`, clients connect to `myalias.database.windows.net`. You can re-point the alias to a different server at any time without changing client connection strings.

This isn't a security feature per se, but it matters here because aliases decouple client configuration from server identity. When you swap servers during a security incident, a DR failover, or a migration, your firewall rules, Private Link connections, and client connection strings all stay intact. That makes aliases a critical enabler for two security-adjacent scenarios:

- **Disaster recovery server swaps.** After a geo-restore to a new server in a different region, update the alias instead of tracking down every client.
- **Zero-downtime migrations.** Move a database to a new server, then swing the alias. No client config changes required.

Each alias name is globally unique across all servers. Updating or removing an alias takes up to two minutes to propagate. You manage aliases through PowerShell cmdlets or the REST API — there's no portal UI for them.

```powershell
# Create a DNS alias pointing to server1
New-AzSqlServerDnsAlias -ResourceGroupName "mygroup" `
    -ServerName "server1" -Name "myalias"

# Swing the alias to server2 (atomic operation)
Set-AzSqlServerDnsAlias -ResourceGroupName "mygroup" `
    -TargetServerName "server2" -Name "myalias" `
    -SourceServerResourceGroup "mygroup" `
    -SourceServerName "server1"
```

> **Tip:** Managing a DNS alias requires the Server Contributor role or higher. Plan your RBAC assignments accordingly.

## Managed Instance Networking

SQL Managed Instance has a fundamentally different network architecture from SQL Database. Instead of a shared public endpoint on a logical server, each MI lives inside your VNet, deployed into a dedicated subnet. This gives you deep network control — NSGs, route tables, service endpoints — but it also means more moving parts to get right.

### Virtual Clusters and Subnet Architecture
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/architecture/virtual-cluster-architecture.md, azure-sql-managed-instance-sql-mi/concepts/architecture/connectivity-architecture-overview.md -->

When you deploy the first Managed Instance into a subnet, Azure automatically creates a **virtual cluster** — a collection of dedicated, isolated VMs joined to an Azure Service Fabric cluster. The virtual cluster manages the compute resources: creating VMs, placing instances, handling scale operations.

Instances within the cluster are organized into **VM groups** based on shared configuration attributes — hardware generation and maintenance window. A subnet can have up to 9 VM groups (3 hardware configurations × 3 maintenance window configurations), though in practice large deployments can exceed this due to per-group size limits.

The virtual cluster auto-scales. New instances add VMs; deleting the last instance in a subnet eventually removes the cluster (which can take up to 1.5 hours). You never manage the cluster directly.

#### Subnet Sizing
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/vnet-subnet-determine-size.md -->

Every MI subnet needs a minimum of 32 IP addresses (a /27 mask). But the minimum is almost never enough. The actual formula:

`5 + (gp × 4) + (bc × 10) + (bc_zr × 2) + (vmg × 8)`

Where:
- 5 = Azure-reserved addresses
- gp = General Purpose instances (4 IPs each: 2 for deployment + 2 for scaling)
- bc = Business Critical instances (10 IPs each: 5 + 5)
- bc_zr = zone-redundant Business Critical instances (2 additional each)
- vmg = number of VM groups (8 IPs each)

For example, 3 General Purpose + 2 Business Critical instances in a single VM group:
`5 + (3 × 4) + (2 × 10) + 0 + (1 × 8) = 45 IPs` → minimum /26 subnet (64 addresses).

> **Important:** You can't resize a subnet while instances are deployed in it. Always over-provision. A /24 (256 addresses) is a safe starting point for most production deployments.

### Traffic Management: Service-Aided Subnet Configuration
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/configure/subnet-service-aided-configuration-enable.md -->

When you delegate a subnet to `Microsoft.Sql/managedInstances`, Azure applies a **network intent policy** that automatically manages critical NSG rules and route table entries. This is called **service-aided subnet configuration**.

The policy adds mandatory rules for internal health probes, node-to-node communication, and management traffic. These rules have reserved names starting with `Microsoft.Sql-managedInstances_UseOnly_mi-` — don't modify or delete them.

| Rule type | Name pattern | Purpose |
|---|---|---|
| NSG inbound | `mi-healthprobe-in` | Load balancer health probes |
| NSG inbound | `mi-internal-in` | Internal node connectivity |
| NSG outbound | `mi-internal-out` | Internal node connectivity |
| Route | `mi-subnet-*-to-vnetlocal` | Node-to-node routing |

The policy also adds **optional** rules (prefixed `mi-optional-`) for outbound Azure connectivity. These are slated for retirement — replace them with your own explicit rules.

> **Gotcha:** Don't reuse the same NSG or route table across multiple MI subnets. The autoconfigured rules reference specific subnet ranges and will conflict. Each delegated subnet should have its own NSG and route table.

Beyond these managed rules, you have full control. You can add your own NSG rules, route traffic through virtual appliances, configure custom DNS, and set up VNet peering or VPN.

### Connection Type NSG Requirements
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/connection-types-overview.md -->

MI's VNet-local endpoint supports **Redirect** (default) and **Proxy** (legacy) connection types. For the full explanation of how each works — TDS version requirements, gateway behavior, performance tradeoffs — see Chapter 4. From a network-security standpoint, what matters is the NSG configuration:

- **Redirect** requires inbound traffic on port 1433 across the *entire subnet range*. After the initial gateway handshake, packets flow directly to the database node, so your NSG must allow that broader range.
- **Proxy** only needs port 1433 open to the gateway. All traffic is proxied, so the NSG footprint is smaller but latency is higher.

### Public Endpoint Hardening
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/public-endpoint-configure.md -->

By default, MI's public endpoint is disabled. When you enable it, the instance becomes reachable at `<mi_name>.public.<dns_zone>.database.windows.net` on port **3342** (not 1433). The public endpoint always uses the Proxy connection type.

Enabling the public endpoint is a two-step process that enforces separation of duties:

1. The **SQL admin** enables the endpoint on the instance.
2. A **network admin** adds an inbound NSG rule allowing traffic on port 3342.

```powershell
# Enable the public endpoint
$mi = Get-AzSqlInstance -ResourceGroupName "mygroup" -Name "myinstance"
$mi | Set-AzSqlInstance -PublicDataEndpointEnabled $true -Force
```

Then add an NSG rule with destination port 3342, priority lower than the `deny_all_inbound` rule (e.g., 1300), and source scoped as tightly as possible — a specific IP range, a service tag like `AzureCloud`, or your corporate NAT address.

> **Warning:** Don't leave the source as "Any" for a public endpoint NSG rule. Scope it to the minimum set of IP addresses or service tags that need access. The public endpoint is visible on the internet.

Also verify that routing is symmetric. If you've overridden the default `0.0.0.0/0` route (for example, to send traffic through a virtual appliance), make sure return traffic from the public endpoint goes back out through the internet, not through your appliance. Asymmetric routing breaks connections.

### Private Link for Managed Instance
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/private-endpoint-overview.md -->

Private endpoints for MI work similarly to SQL Database but with some important differences. A private endpoint creates a fixed private IP in another VNet that routes traffic to your instance over Private Link. This is unidirectional — the endpoint's VNet can reach MI, but MI can't see resources in the endpoint's VNet.

Key scenarios where MI private endpoints shine:

- **Hub-and-spoke topologies** — endpoint in the spoke, MI in the hub
- **Cross-tenant access** — ISVs making instances available to customer VNets
- **PaaS integration** — services like Azure Data Factory creating managed private endpoints

Private endpoints for MI connect on port 1433 and always use the **Proxy** connection type, regardless of the instance's connection type setting. They can't be used for failover groups, distributed transactions, or Managed Instance link — those require the VNet-local endpoint.

> **Important:** After creating a private endpoint, you must configure DNS resolution manually. Without it, connections fail. For endpoints in a different VNet, create a private DNS zone named `privatelink.<dns-zone>.database.windows.net` and add an A record for the instance name pointing to the endpoint's IP.

> **Gotcha:** If the private endpoint is in the *same* VNet as the MI, don't name the DNS zone `privatelink.<dns-zone>.database.windows.net` — that breaks the instance's internal management connectivity. Use a different zone name like `privatelink.site` and configure the client connection string with `HostNameInCertificate` set to the VNet-local endpoint domain name.

### Service Endpoint Policies for Storage Egress
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/service-endpoint-policies-configure.md -->

**Service endpoint policies** let you restrict which Azure Storage accounts your MI subnet can reach. This closes a data exfiltration vector: without policies, any code running on MI (through `BULK INSERT`, `OPENROWSET`, backups, or extended events) could send data to any storage account accessible via the service endpoint.

To configure them:

1. Create a service endpoint policy with the `/Services/Azure/ManagedInstance` alias (required for MI subnets).
2. Add resource definitions scoping allowed storage accounts by subscription, resource group, or individual account.
3. Associate the policy with the MI subnet.

> **Tip:** Start by allowing entire subscriptions, validate that all workflows work (backups, auditing, imports), then tighten to individual storage accounts.

Service endpoint policies only control traffic through the Azure Storage service endpoint. They don't affect other egress paths — if you need broader egress control, layer in user-defined routes and Azure Firewall.

## SQL Server VM Networking

SQL Server on Azure VMs operates in standard IaaS networking — you're responsible for everything above the physical wire. The VM sits in a VNet and subnet of your choosing, and network security is entirely in your hands.

### NSG Configuration and Port Requirements

At minimum, your SQL Server VM needs inbound access on:

| Port | Protocol | Purpose |
|---|---|---|
| 1433 | TCP | Default SQL Server instance |
| 3389 | TCP | RDP (restrict or disable in production) |
| 5022 | TCP | Always On availability group endpoint |

Lock down port 1433 to the specific VNets, subnets, or IP ranges that need database access. Never leave it open to `0.0.0.0/0`. For RDP, use **Azure Bastion** or **Just-in-time (JIT) access** instead of opening port 3389 to the internet.
<!-- Source: sql-server-on-azure-vms/windows/concepts/best-practices/security-considerations-best-practices.md -->

Use NSG rules with service tags to scope access. The `VirtualNetwork` tag covers all VNet traffic. For SQL-specific outbound traffic, the `Sql` service tag covers all Azure SQL Database gateway IP addresses.

> **Tip:** Use Application Security Groups to tag your database VMs and web/app VMs separately. Then write NSG rules referencing ASGs instead of IP addresses — when you add a new app server, it automatically inherits the right network rules.

### Firewall Rules on the VM

In addition to NSGs (which operate at the Azure network level), configure Windows Firewall or `firewalld` on the VM itself. This gives you defense in depth — even if an NSG rule is misconfigured, the OS firewall is a second barrier.

For availability groups, ensure port 5022 is open between all replicas. For multi-subnet deployments, allow ICMP if your clustering relies on it, and configure listener connectivity through either a distributed network name (DNN) or a virtual network name (VNN) with Azure Load Balancer.

For detailed connectivity architecture — connection string patterns, driver behavior, gateway routing — see Chapter 4.

## Choosing the Right Network Controls

The options are layered, and mixing them is common. Here's how to think about the decision for each deployment model:

**SQL Database:**

- **Quick dev/test access** — IP firewall rules
- **VNet-only access** — VNet service endpoints
- **Cross-VNet or on-prem** — Private Link
- **Zero public exposure** — Private Link + deny public
- **PaaS-to-PaaS boundary** — Network Security Perimeter
- **Egress control** — Outbound firewall rules

**Managed Instance:**

- **Quick dev/test access** — Public endpoint + NSG
- **VNet-only access** — VNet-local endpoint (default)
- **Cross-VNet or on-prem** — Private endpoints or VNet peering
- **Zero public exposure** — Disable public endpoint
- **PaaS-to-PaaS boundary** — Service endpoint policies
- **Egress control** — Service endpoint policies + UDR

**SQL VM:**

- **Quick dev/test access** — NSG + JIT
- **VNet-only access** — NSG rules
- **Cross-VNet or on-prem** — VNet peering or VPN
- **Zero public exposure** — No public IP on VM
- **Egress control** — NSG + Azure Firewall

The strongest posture for any deployment model is: private connectivity only, no public endpoint, egress locked down to named destinations.

In the next chapter, we'll move from network security to identity — how to authenticate the connections that your network rules allow through.
