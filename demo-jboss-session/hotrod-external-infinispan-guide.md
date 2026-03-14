# HotRod External Infinispan with JBoss EAP / WildFly

**Last updated:** March 2026
**Applies to:** WildFly 31+ / Red Hat EAP 8 + Infinispan 15.x / Red Hat Data Grid 8.x

---

## 1. Overview

**HotRod** is a binary, TCP-based client/server protocol developed by Infinispan for high-performance access to a remote Infinispan Server cluster. When used for HTTP session storage in JBoss EAP or WildFly, each application server node connects to an external Infinispan Server cluster as a client — sessions are stored, replicated, and persisted entirely outside the EAP process.

### Architecture (text diagram)

```
  ┌──────────────────────────────────────────────────┐
  │               Load Balancer (HAProxy / OpenShift) │
  └───────────────────┬──────────────────────────────┘
                      │  HTTP
          ┌───────────┴───────────┐
          ▼                       ▼
  ┌───────────────┐       ┌───────────────┐
  │  EAP Node 1   │       │  EAP Node 2   │   (no JGroups needed)
  │  port 8080    │       │  port 8180    │
  └──────┬────────┘       └────────┬──────┘
         │   HotRod (port 11222)   │
         └────────────┬────────────┘
                      ▼
         ┌────────────────────────┐
         │  Infinispan Server     │   ← sessions stored here
         │  Cluster (1–N nodes)   │
         │  port 11222            │
         └────────────────────────┘
```

### Embedded vs. External Sessions

| | Embedded Infinispan | External HotRod |
|---|---|---|
| Session store location | In-process (EAP heap) | Standalone Infinispan Server |
| Transport | JGroups (peer-to-peer) | HotRod TCP protocol |
| Extra infrastructure | None | Infinispan Server required |
| Survives node failure | Yes | Yes |
| **Survives full EAP cluster restart** | **No** | **Yes** |
| Independent scalability | No | Yes — scale EAP and Infinispan separately |
| EAP config profile | `standalone-ha.xml` | `standalone.xml` or `standalone-ha.xml` |

---

## 2. Compatibility Matrix

| EAP / WildFly | Infinispan Server | Red Hat Data Grid | Approach |
|---|---|---|---|
| WildFly 31+ / EAP 8.0+ | 15.x | 8.x | `distributable-web` + `hotrod-session-management` (**RECOMMENDED**) |
| EAP 7.4.x | 13.x–14.x | 8.x | `invalidation-cache` + `store=hotrod` (legacy) |
| EAP 7.3 and earlier | 11.x–12.x | 7.x | Legacy approach (see §5.2) |

> **Note:** The `distributable-web` subsystem and `hotrod-session-management` resource were introduced in WildFly 17 / EAP 8. Any WildFly 17+ or EAP 8+ deployment should use this approach exclusively.

---

## 3. Infinispan Server Setup

### 3.1 Installation

```bash
# Download Infinispan Server 15.x
wget https://downloads.jboss.org/infinispan/15.x.y.Final/infinispan-server-15.x.y.Final.zip
unzip infinispan-server-15.x.y.Final.zip
export ISPN_HOME=$PWD/infinispan-server-15.x.y.Final
```

Or via Docker (recommended for dev/PoC):

```bash
docker run -d \
  --name infinispan \
  -p 11222:11222 \
  -e USER=admin \
  -e PASS=changeme \
  quay.io/infinispan/server:15.0
```

### 3.2 infinispan.xml

The following configuration defines a distributed cache for session storage. The cache name **must match** the deployed WAR name (e.g., `session-demo.war`) when using automatic cache creation, or you can use a named cache configuration template.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<infinispan
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="urn:infinispan:config:15.0 https://infinispan.org/schemas/infinispan-config-15.0.xsd
                            urn:infinispan:server:15.0 https://infinispan.org/schemas/infinispan-server-15.0.xsd"
        xmlns="urn:infinispan:config:15.0"
        xmlns:server="urn:infinispan:server:15.0">

    <cache-container name="default" statistics="true">
        <!-- JGroups transport for multi-node Infinispan clustering -->
        <transport cluster="infinispan-cluster"/>

        <!--
            Cache name must match the deployed WAR file name.
            Infinispan 9.2+ (protocol 2.7+) can auto-create caches on first access
            if a default cache-configuration is defined.
        -->
        <distributed-cache name="session-demo.war">
            <transaction mode="NON_XA" locking="PESSIMISTIC"/>
        </distributed-cache>
    </cache-container>

    <server xmlns="urn:infinispan:server:15.0">
        <interfaces>
            <interface name="public">
                <inet-address value="${infinispan.bind.address:0.0.0.0}"/>
            </interface>
        </interfaces>

        <socket-bindings default-interface="public"
                         port-offset="${infinispan.socket.binding.port-offset:0}">
            <socket-binding name="default" port="11222"/>
        </socket-bindings>

        <security>
            <credential-stores>
                <credential-store name="credentials" path="credentials.pfx">
                    <clear-text-credential clear-text="secret"/>
                </credential-store>
            </credential-stores>
            <security-realms>
                <!--
                    Property realm: credentials managed via USER/PASS environment
                    variables (Docker Compose). Server auto-generates
                    users.properties / groups.properties on first boot.
                -->
                <security-realm name="default">
                    <properties-realm groups-attribute="Roles">
                        <user-properties path="users.properties"
                                         relative-to="infinispan.server.config.path"
                                         plain-text="true"/>
                        <group-properties path="groups.properties"
                                          relative-to="infinispan.server.config.path"/>
                    </properties-realm>
                </security-realm>
            </security-realms>
        </security>

        <endpoints>
            <endpoint socket-binding="default" security-realm="default">
                <hotrod-connector name="hotrod">
                    <authentication>
                        <sasl mechanisms="SCRAM-SHA-256 SCRAM-SHA-512 DIGEST-MD5 PLAIN"
                              server-name="infinispan"
                              qop="auth"/>
                    </authentication>
                </hotrod-connector>
                <rest-connector name="rest"/>
            </endpoint>
        </endpoints>
    </server>

</infinispan>
```

### 3.3 User / Credential Setup (CLI)

```bash
# Add a user with the 'admin' role
$ISPN_HOME/bin/cli.sh user create admin -p changeme -g admin

# Verify connectivity
$ISPN_HOME/bin/cli.sh -c http://localhost:11222 --trustall \
    -u admin -w changeme -- describe
```

### 3.4 Multi-Node Infinispan Clustering (JGroups TCP)

For a production Infinispan cluster, add JGroups TCP stack configuration to avoid multicast issues in containerized environments:

```xml
<jgroups>
    <stack name="tcp" extends="tcp">
        <TCP bind_addr="${infinispan.bind.address:0.0.0.0}"
             bind_port="7800"/>
        <TCPPING initial_hosts="${jgroups.tcpping.initial_hosts:localhost[7800]}"
                 port_range="1"/>
    </stack>
</jgroups>
```

Start a second node with a port offset:

```bash
$ISPN_HOME/bin/server.sh \
    -Dinfinispan.socket.binding.port-offset=100 \
    -Dinfinispan.bind.address=0.0.0.0 \
    -Djgroups.tcpping.initial_hosts="node1[7800],node2[7800]"
```

---

## 4. JBoss EAP / WildFly Configuration

### 4.1 Modern Approach — EAP 8 / WildFly 17+ (RECOMMENDED)

This approach uses the `distributable-web` subsystem introduced in WildFly 17. EAP nodes do **not** need to form a JGroups cluster with each other — each node communicates independently with the Infinispan Server via HotRod.

#### Step 1: Outbound Socket Binding

The socket binding resolves the Infinispan Server address. Use the `env.ISPN_HOST` expression to allow environment variable override at runtime (useful for containers).

**CLI:**
```
/socket-binding-group=standard-sockets/remote-destination-outbound-socket-binding=remote-infinispan:add(\
    host=${env.ISPN_HOST:localhost}, \
    port=11222)
```

**standalone.xml XML:**
```xml
<outbound-socket-binding name="remote-infinispan">
    <remote-destination host="${env.ISPN_HOST:localhost}" port="11222"/>
</outbound-socket-binding>
```

#### Step 2: Remote Cache Container

Defines the HotRod client connection pool, authentication, and marshaller. The `modules` attribute loads the WildFly clustering integration.

**CLI:**
```
/subsystem=infinispan/remote-cache-container=web-sessions:add(\
    default-remote-cluster=ispn-cluster, \
    marshaller=PROTOSTREAM, \
    modules=[org.wildfly.clustering.web.hotrod], \
    statistics-enabled=true, \
    properties={\
        infinispan.client.hotrod.auth_username=admin, \
        infinispan.client.hotrod.auth_password=changeme, \
        infinispan.client.hotrod.sasl_mechanism=SCRAM-SHA-256\
    })

/subsystem=infinispan/remote-cache-container=web-sessions/remote-cluster=ispn-cluster:add(\
    socket-bindings=[remote-infinispan])
```

**standalone.xml XML:**
```xml
<subsystem xmlns="urn:jboss:domain:infinispan:14.0">
    <!-- ... other cache containers ... -->
    <remote-cache-container name="web-sessions"
                            default-remote-cluster="ispn-cluster"
                            marshaller="PROTOSTREAM"
                            statistics-enabled="true">
        <remote-cluster name="ispn-cluster">
            <remote-socket-binding name="remote-infinispan"/>
        </remote-cluster>
        <property name="infinispan.client.hotrod.auth_username">admin</property>
        <property name="infinispan.client.hotrod.auth_password">changeme</property>
        <property name="infinispan.client.hotrod.sasl_mechanism">SCRAM-SHA-256</property>
        <modules>
            <module name="org.wildfly.clustering.web.hotrod"/>
        </modules>
    </remote-cache-container>
</subsystem>
```

#### Step 3: HotRod Session Management Profile

**CLI:**
```
/subsystem=distributable-web/hotrod-session-management=remote-sm:add(\
    remote-cache-container=web-sessions, \
    granularity=SESSION)

/subsystem=distributable-web/hotrod-session-management=remote-sm/affinity=local:add()

# Make remote-sm the server-wide default
/subsystem=distributable-web:write-attribute(name=default-session-management, value=remote-sm)
```

**standalone.xml XML:**
```xml
<subsystem xmlns="urn:jboss:domain:distributable-web:3.0"
           default-session-management="remote-sm">
    <hotrod-session-management name="remote-sm"
                               remote-cache-container="web-sessions"
                               granularity="SESSION">
        <local-affinity/>
    </hotrod-session-management>
</subsystem>
```

#### Complete CLI Script (run against each EAP node)

```bash
$WILDFLY_HOME/bin/jboss-cli.sh --connect --controller=localhost:9990 \
    --file=configure-node.cli
```

`configure-node.cli`:
```
batch

/socket-binding-group=standard-sockets/remote-destination-outbound-socket-binding=remote-infinispan:add(\
    host=${env.ISPN_HOST:localhost}, \
    port=11222)

/subsystem=infinispan/remote-cache-container=web-sessions:add(\
    default-remote-cluster=ispn-cluster, \
    marshaller=PROTOSTREAM, \
    modules=[org.wildfly.clustering.web.hotrod], \
    statistics-enabled=true, \
    properties={\
        infinispan.client.hotrod.auth_username=admin, \
        infinispan.client.hotrod.auth_password=changeme, \
        infinispan.client.hotrod.sasl_mechanism=SCRAM-SHA-256\
    })

/subsystem=infinispan/remote-cache-container=web-sessions/remote-cluster=ispn-cluster:add(\
    socket-bindings=[remote-infinispan])

/subsystem=distributable-web/hotrod-session-management=remote-sm:add(\
    remote-cache-container=web-sessions, \
    granularity=SESSION)

/subsystem=distributable-web/hotrod-session-management=remote-sm/affinity=local:add()

/subsystem=distributable-web:write-attribute(name=default-session-management, value=remote-sm)

run-batch
```

---

### 4.2 Legacy Approach — EAP 7.x

> **Deprecated.** Use the modern approach for all EAP 8+ / WildFly 17+ deployments.

In EAP 7.x, sessions are stored via a HotRod cache store attached to an invalidation-cache in the `infinispan` subsystem. The `shared=true` flag is **mandatory** — it tells EAP that all nodes share the same backing store.

**CLI:**
```
/subsystem=infinispan/cache-container=web/invalidation-cache=hotrod:add(\
    mode=SYNC)

/subsystem=infinispan/cache-container=web/invalidation-cache=hotrod/store=hotrod:add(\
    remote-servers=[remote-infinispan], \
    shared=true, \
    cache=web-sessions)

/subsystem=infinispan/cache-container=web:write-attribute(\
    name=default-cache, value=hotrod)
```

**standalone-ha.xml XML:**
```xml
<cache-container name="web" default-cache="hotrod">
    <invalidation-cache name="hotrod" mode="SYNC">
        <hotrod-store remote-servers="remote-infinispan"
                      cache="web-sessions"
                      shared="true"/>
    </invalidation-cache>
</cache-container>
```

---

## 5. Application Configuration

### 5.1 `web.xml` — Enable Distributable Sessions

`<distributable/>` is **mandatory**. Without it, the servlet container treats sessions as local and ignores all session management configuration.

```xml
<!-- src/main/webapp/WEB-INF/web.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://jakarta.ee/xml/ns/jakartaee
             https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd"
         version="6.0">

    <distributable/>

    <servlet>
        <servlet-name>SessionServlet</servlet-name>
        <servlet-class>com.example.SessionServlet</servlet-class>
    </servlet>
    <servlet-mapping>
        <servlet-name>SessionServlet</servlet-name>
        <url-pattern>/session</url-pattern>
    </servlet-mapping>
</web-app>
```

### 5.2 `distributable-web.xml` — Per-Application Session Management Profile

Use this file to bind a specific application to a named session management profile, overriding the server-wide default.

```xml
<!-- src/main/webapp/WEB-INF/distributable-web.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<distributable-web xmlns="urn:jboss:distributable-web:2.0">
    <hotrod-session-management name="remote-sm"/>
</distributable-web>
```

### 5.3 `jboss-deployment-structure.xml` — Module Dependencies

Normally not needed when `modules=[org.wildfly.clustering.web.hotrod]` is declared on the `remote-cache-container`. Include only if you encounter `ClassNotFoundException` for marshalling classes:

```xml
<!-- src/main/webapp/WEB-INF/jboss-deployment-structure.xml -->
<jboss-deployment-structure>
    <deployment>
        <dependencies>
            <module name="org.wildfly.clustering.web.hotrod" services="import"/>
            <module name="org.infinispan.protostream"/>
        </dependencies>
    </deployment>
</jboss-deployment-structure>
```

---

## 6. Authentication & Security

### 6.1 SCRAM-SHA-256 / SCRAM-SHA-512

SCRAM-SHA-256 is the recommended mechanism. Set it on the EAP side via HotRod client properties:

```
infinispan.client.hotrod.auth_username=admin
infinispan.client.hotrod.auth_password=changeme
infinispan.client.hotrod.sasl_mechanism=SCRAM-SHA-256
```

On the Infinispan Server side, ensure the mechanism is listed in the SASL configuration:

```xml
<sasl mechanisms="SCRAM-SHA-256 SCRAM-SHA-512 DIGEST-MD5 PLAIN"
      server-name="infinispan"
      qop="auth"/>
```

> The `server-name` value (`infinispan`) must match the SNI hostname used by the client. For TLS-enabled setups this is also the certificate CN/SAN.

### 6.2 Optional TLS via Elytron

To encrypt the HotRod connection, configure a `client-ssl-context` in the Elytron subsystem and reference it from the `remote-cache-container`:

```
# Create a trust store referencing the Infinispan server certificate
/subsystem=elytron/key-store=ispn-trust:add(\
    path=ispn-truststore.jks, \
    relative-to=jboss.server.config.dir, \
    type=JKS, \
    credential-reference={clear-text=trustpass})

/subsystem=elytron/trust-manager=ispn-trust-mgr:add(\
    key-store=ispn-trust)

/subsystem=elytron/client-ssl-context=ispn-ssl:add(\
    trust-manager=ispn-trust-mgr)

# Reference from the remote-cache-container
/subsystem=infinispan/remote-cache-container=web-sessions:write-attribute(\
    name=ssl-context, value=ispn-ssl)
```

---

## 7. Key Attributes Reference

### 7.1 `remote-cache-container` Attributes

| Attribute | Description | Default |
|---|---|---|
| `name` | Container name referenced by `hotrod-session-management` | — |
| `default-remote-cluster` | Name of the `remote-cluster` child resource to use | — |
| `marshaller` | Serialization format: `PROTOSTREAM` (required) or `JAVA` (legacy) | `JAVA` |
| `modules` | WildFly modules to load; use `[org.wildfly.clustering.web.hotrod]` | — |
| `statistics-enabled` | Expose JMX/management statistics | `false` |
| `connection-timeout` | Socket connect timeout (ms) | `60000` |
| `max-retries` | Retry attempts on server failure | `10` |
| `ssl-context` | Elytron `client-ssl-context` name for TLS | — |

HotRod client properties (set via `<property>` or the `properties` map):

| Property | Description |
|---|---|
| `infinispan.client.hotrod.auth_username` | Authentication username |
| `infinispan.client.hotrod.auth_password` | Authentication password |
| `infinispan.client.hotrod.sasl_mechanism` | SASL mechanism (e.g., `SCRAM-SHA-256`) |
| `infinispan.client.hotrod.connect_timeout` | TCP connect timeout (ms) |
| `infinispan.client.hotrod.socket_timeout` | TCP socket read timeout (ms) |

### 7.2 `hotrod-session-management` Attributes

| Attribute | Description | Default |
|---|---|---|
| `name` | Profile name referenced by `distributable-web.xml` or the default | — |
| `remote-cache-container` | Name of the `remote-cache-container` to use | — |
| `granularity` | `SESSION` or `ATTRIBUTE` — controls how session data is partitioned in the cache | `SESSION` |
| `cache-configuration` | Named cache configuration template on Infinispan Server | (WAR name) |

---

## 8. Session Granularity & Affinity

### Granularity

| Value | Description | When to use |
|---|---|---|
| `SESSION` | Entire session serialized as one cache entry | Default; simple, lower overhead |
| `ATTRIBUTE` | Each session attribute stored as a separate cache entry | Large sessions where only a few attributes change per request |

### Affinity

| Affinity | CLI resource | Description |
|---|---|---|
| `local` | `affinity=local:add()` | Prefer the node that owns the session (sticky sessions). Requires a load balancer that supports session affinity (HAProxy `balance source`, OpenShift route annotation). |
| `none` | `affinity=none:add()` | No affinity — any node can serve any session. Simpler for stateless LB setups. |

> With `granularity=SESSION` and `affinity=local`, every request causes at most one remote read (cache hit on the local in-memory copy) and one remote write. With `affinity=none` every request reads from and writes to Infinispan Server directly.

---

## 9. Container / OpenShift Patterns

### Environment Variable Substitution

The socket binding uses `${env.ISPN_HOST:localhost}` — this is a WildFly expression that reads the `ISPN_HOST` OS environment variable and falls back to `localhost` if unset. Override it in your container manifest:

```yaml
# Kubernetes / OpenShift Deployment
env:
  - name: ISPN_HOST
    value: "infinispan-service.my-namespace.svc.cluster.local"
```

Or in `docker-compose.yml`:

```yaml
environment:
  - ISPN_HOST=infinispan
```

### Galleon Layers (WildFly Provisioning)

When building a custom WildFly server image with Galleon, include the following layers:

```xml
<!-- galleon/provisioning.xml -->
<layers>
    <include name="cloud-server"/>       <!-- base server + management -->
    <include name="web-clustering"/>     <!-- distributable-web + hotrod integration -->
</layers>
```

Or with the WildFly Maven Plugin:

```xml
<plugin>
    <groupId>org.wildfly.plugins</groupId>
    <artifactId>wildfly-maven-plugin</artifactId>
    <configuration>
        <feature-packs>
            <feature-pack>
                <location>wildfly@maven(org.jboss.universe:community-universe)#31.0.0.Final</location>
            </feature-pack>
        </feature-packs>
        <layers>
            <layer>cloud-server</layer>
            <layer>web-clustering</layer>
        </layers>
    </configuration>
</plugin>
```

### OpenShift Route — Sticky Sessions

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  annotations:
    haproxy.router.openshift.io/balance: "source"
    haproxy.router.openshift.io/disable_cookies: "false"
spec:
  to:
    kind: Service
    name: eap-service
```

---

## 10. Troubleshooting / Gotchas

### PROTOSTREAM is Mandatory (LEGACY Deprecated)

```
# WRONG — will cause marshalling errors on WildFly 17+ / EAP 8+
marshaller=JAVA

# CORRECT
marshaller=PROTOSTREAM
```

The `JAVA` (JavaSerializer) marshaller is deprecated and was removed/disabled by default in recent WildFly versions. Always use `PROTOSTREAM`.

### `<distributable/>` is Required

Omitting `<distributable/>` from `web.xml` causes sessions to remain node-local. No error is thrown — sessions simply won't replicate. Verify with:

```bash
curl -c /tmp/cookies.txt http://node1:8080/session-demo/session
# Stop node1
curl -b /tmp/cookies.txt http://node2:8080/session-demo/session
# If counter resets to 1, <distributable/> is missing or misspelled
```

### Automatic Cache Creation (Infinispan 9.2+ / Protocol 2.7+)

By default, WildFly creates the remote cache automatically on first deployment using the WAR name as the cache name (e.g., `session-demo.war`). This requires the Infinispan Server user to have the `CREATE_CACHE` permission. If automatic creation is disabled or fails:

```bash
# Create the cache manually via REST API
curl -X POST \
  -u admin:changeme \
  -H "Content-Type: application/json" \
  -d '{"distributed-cache":{"transaction":{"mode":"NON_XA","locking":"PESSIMISTIC"}}}' \
  http://localhost:11222/rest/v2/caches/session-demo.war
```

To use a custom cache name instead of the WAR name, set `cache-configuration` on `hotrod-session-management`:

```
/subsystem=distributable-web/hotrod-session-management=remote-sm:write-attribute(\
    name=cache-configuration, value=my-session-cache)
```

### `shared=true` Required in Legacy Approach

In the EAP 7.x legacy approach with `store=hotrod`, omitting `shared=true` causes each EAP node to treat the cache store as node-local, resulting in session corruption when requests are served by different nodes.

### EAP Nodes Do NOT Need JGroups When Using HotRod Session Management

With the modern `hotrod-session-management` approach, each EAP node communicates independently with Infinispan Server. There is **no need** to configure JGroups clustering between EAP nodes. You can run each node with `standalone.xml` instead of `standalone-ha.xml`:

```bash
$WILDFLY_HOME/bin/standalone.sh -c standalone.xml \
    -Djboss.socket.binding.port-offset=100
```

The Infinispan Server cluster itself still uses JGroups for intra-cluster replication between its own nodes.

### Connection Refused / Authentication Failures

```bash
# Check Infinispan is listening
nc -zv localhost 11222

# Test auth via CLI
$ISPN_HOME/bin/cli.sh -c http://localhost:11222 -u admin -w changeme \
    -- ls caches

# Check WildFly log for HotRod errors
grep -i hotrod $WILDFLY_HOME/standalone/log/server.log | tail -20
```

Common error patterns:

| Error | Cause | Fix |
|---|---|---|
| `org.infinispan.client.hotrod.exceptions.HotRodClientException: Authentication required` | Wrong credentials or SASL mechanism mismatch | Verify `auth_username`, `auth_password`, `sasl_mechanism` match Infinispan Server config |
| `java.lang.ClassNotFoundException: org.infinispan.protostream.*` | Missing module declaration | Add `modules=[org.wildfly.clustering.web.hotrod]` to `remote-cache-container` |
| `WFLYCLU0003: Remote cache ... does not exist` | Cache not created and auto-creation disabled | Create cache manually or enable `CREATE_CACHE` permission for the auth user |
| Sessions not persisting across EAP restart | `<distributable/>` missing from `web.xml` | Add `<distributable/>` |

---

## 11. References

- [WildFly High Availability Guide — Distributable Web](https://docs.wildfly.org/31/High_Availability_Guide.html#Distributable_Web)
- [WildFly Model Reference — distributable-web](https://wildscribe.github.io/WildFly/34.0.0/subsystem/distributable-web/)
- [WildFly Model Reference — infinispan/remote-cache-container](https://wildscribe.github.io/WildFly/34.0.0/subsystem/infinispan/remote-cache-container/)
- [Red Hat EAP 8 — Configuring Distributed HTTP Sessions](https://access.redhat.com/documentation/en-us/red_hat_jboss_enterprise_application_platform/8.0/html/configuring_distributed_http_sessions/)
- [Red Hat Data Grid 8 — Getting Started Guide](https://access.redhat.com/documentation/en-us/red_hat_data_grid/8.4/html/getting_started_with_data_grid_server/)
- [Infinispan 15 Documentation — HotRod Java Client](https://infinispan.org/docs/stable/titles/hotrod_java/hotrod_java.html)
- [Infinispan Server Configuration Schema 15.0](https://infinispan.org/schemas/infinispan-server-15.0.xsd)
