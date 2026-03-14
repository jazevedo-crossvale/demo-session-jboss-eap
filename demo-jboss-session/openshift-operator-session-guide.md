# OpenShift EAP 8 Operator + Data Grid Operator — HotRod Session Guide

**Last updated:** March 2026
**Applies to:** Red Hat EAP 8 Operator (WildFlyServer CRD) + Red Hat Data Grid Operator 8.3–8.5 on OpenShift 4.12+

> **Companion guide:** This document covers the Operator-based OpenShift deployment path.
> For standalone/Docker setup see [`hotrod-external-infinispan-guide.md`](./hotrod-external-infinispan-guide.md).

---

## 1. Overview

This guide shows how to wire Red Hat EAP 8 (deployed via the EAP Operator) to a Red Hat Data Grid cluster (deployed via the Data Grid Operator) for external HTTP session storage over the HotRod protocol on OpenShift 4.x.

### Architecture

```
  ┌──────────────────────────────────────────────┐
  │         OpenShift Route (HAProxy)             │
  │   haproxy.router.openshift.io/balance: roundrobin │
  │   + sticky-session cookie annotation          │
  └───────────────────┬──────────────────────────┘
                      │  HTTPS / HTTP
          ┌───────────┴───────────┐
          ▼                       ▼
  ┌───────────────────┐   ┌───────────────────┐
  │  EAP Pod 1        │   │  EAP Pod 2        │   WildFlyServer CR
  │  (WildFly 31)     │   │  (WildFly 31)     │   spec.replicas: 2
  └────────┬──────────┘   └────────┬──────────┘
           │      HotRod port 11222 │
           └──────────┬────────────┘
                      ▼
  ┌────────────────────────────────────────────┐
  │  Data Grid Cluster (Infinispan CR)         │
  │  <infinispan-cr-name>.<ns>.svc.cluster.local:11222 │
  │  Cache CR: session-demo.war (distributed)  │
  └────────────────────────────────────────────┘
```

No JGroups clustering between EAP pods is required. Each EAP pod connects independently to Data Grid via HotRod.

---

## 2. Compatibility Matrix

| EAP Operator (wildfly.org/v1alpha1) | WildFly / EAP Version | Data Grid Operator | Infinispan Server | OpenShift |
|---|---|---|---|---|
| 1.x | WildFly 31 / EAP 8.0 | 8.3.x | 14.x | OCP 4.12+ |
| 1.x | WildFly 31 / EAP 8.0 | 8.4.x | 14.x–15.x | OCP 4.13+ |
| 1.x | WildFly 31 / EAP 8.0 | 8.5.x | 15.x | OCP 4.14+ |

> **Note:** The `Cache` service type (as opposed to `DataGrid`) was deprecated in Data Grid Operator 8.3 and removed in 8.4. Always use `spec.service.type: DataGrid` for production clusters.

---

## 3. Data Grid Operator Setup

### 3.1 Install via OperatorHub

Create a `Subscription` in the `openshift-operators` namespace (or a dedicated namespace):

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: datagrid
  namespace: openshift-operators
spec:
  channel: 8.5.x
  name: datagrid
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Apply and wait for the operator pod to reach `Running`:

```bash
oc apply -f datagrid-subscription.yaml
oc get csv -n openshift-operators | grep datagrid
```

### 3.2 Infinispan CR (cluster definition)

The `Infinispan` CR defines the Data Grid cluster. Use `spec.service.type: DataGrid` (not `Cache`) to get the full HotRod endpoint and persistent caches.

```yaml
apiVersion: infinispan.org/v1
kind: Infinispan
metadata:
  name: data-grid
  namespace: session-demo
spec:
  replicas: 2
  service:
    type: DataGrid
  security:
    endpointSecretName: dg-credentials
  expose:
    type: ClusterIP
  container:
    storage:
      ephemeral: false
      size: 2Gi
```

> `spec.expose.type: ClusterIP` keeps the Data Grid endpoint internal to the cluster. EAP pods connect via the in-cluster DNS name (see §3.5). Do not use `NodePort` or `LoadBalancer` unless external access is required.

Wait for the cluster to be ready:

```bash
oc get infinispan data-grid -n session-demo -w
# Condition ready: True
```

### 3.3 Authentication Secret

The Data Grid Operator reads credentials from a secret containing an `identities.yaml` file.

Create `identities.yaml`:

```yaml
# identities.yaml
credentials:
  - username: developer
    password: changeme
    roles:
      - admin
```

> The user must have the `admin` role (which includes `CREATE_CACHE`) so that WildFly can auto-create the session cache on first deployment.

Create the secret:

```bash
oc create secret generic dg-credentials \
  --from-file=identities.yaml \
  -n session-demo
```

If you let the operator generate credentials instead, retrieve them with:

```bash
# Secret name pattern: <infinispan-cr-name>-generated-secret
oc get secret data-grid-generated-secret \
  -n session-demo \
  -o jsonpath='{.data.identities\.yaml}' | base64 -d
```

### 3.4 Cache CR (session cache)

The `Cache` CR provisions a named cache on the Data Grid cluster. The cache name **must match** the deployed WAR name (e.g., `session-demo.war`) so that WildFly's HotRod session management can locate it automatically.

This Cache CR mirrors the `distributed-cache` configuration from `version2-external/infinispan/infinispan.xml` — `NON_XA` transaction mode with `PESSIMISTIC` locking and `owners: 2` for one replica:

```yaml
apiVersion: infinispan.org/v2alpha1
kind: Cache
metadata:
  name: session-demo-war
  namespace: session-demo
spec:
  clusterName: data-grid
  name: session-demo.war
  adminAuth:
    secretName: dg-credentials
    username: developer
    passwordKey: password
  template: |
    distributedCache:
      mode: "SYNC"
      owners: 2
      encoding:
        mediaType: "application/octet-stream"
      transaction:
        mode: "NON_XA"
        locking: "PESSIMISTIC"
      statistics: true
```

Verify the cache was created:

```bash
oc get cache session-demo-war -n session-demo
# STATUS should be Ready
```

### 3.5 DNS Name for HotRod Clients

The Data Grid Operator creates a headless Service named after the Infinispan CR. EAP pods connect using:

```
<infinispan-cr-name>.<namespace>.svc.cluster.local:11222
```

For the example above:

```
data-grid.session-demo.svc.cluster.local:11222
```

This is the value to use for the `ISPN_HOST` environment variable in the WildFlyServer CR (§4.4).

---

## 4. EAP 8 Operator Setup

### 4.1 Install via OperatorHub

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: eap
  namespace: session-demo
spec:
  channel: stable
  name: eap
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

```bash
oc apply -f eap-subscription.yaml
oc get csv -n session-demo | grep eap
```

### 4.2 Build the Application Image

Galleon layers are baked at image build time — they are **not** applied by the operator at deploy time. The application image must include the `web-clustering` layer, which provides the `distributable-web` subsystem and HotRod session management integration.

#### WildFly Maven Plugin (pom.xml)

```xml
<plugin>
    <groupId>org.wildfly.plugins</groupId>
    <artifactId>wildfly-maven-plugin</artifactId>
    <version>5.0.0.Final</version>
    <configuration>
        <feature-packs>
            <feature-pack>
                <!-- Use eap-galleon-pack for Red Hat EAP 8 -->
                <location>org.jboss.eap:eap-galleon-pack:8.0.0.GA-redhat-00001</location>
            </feature-pack>
            <feature-pack>
                <location>org.jboss.eap.cloud:eap-cloud-galleon-pack:1.0.0.Final-redhat-00001</location>
            </feature-pack>
        </feature-packs>
        <layers>
            <layer>cloud-server</layer>
            <layer>web-clustering</layer>
        </layers>
        <galleon-options>
            <jboss-fork-embedded>true</jboss-fork-embedded>
        </galleon-options>
    </configuration>
    <executions>
        <execution>
            <id>provision-server</id>
            <phase>package</phase>
            <goals>
                <goal>provision</goal>
                <goal>package</goal>
            </goals>
        </execution>
    </executions>
</plugin>
```

#### Dockerfile (S2I-compatible)

```dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-17:latest AS builder
COPY . /workspace
WORKDIR /workspace
RUN mvn -B package -DskipTests

FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-builder-openshift-rhel9:latest AS server-builder
COPY --from=builder /workspace/target/*.war /tmp/artifacts/
# S2I assemble installs the WAR and runs maven provisioning
RUN /usr/local/s2i/assemble

FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-runtime-openshift-rhel9:latest
COPY --from=server-builder $JBOSS_HOME $JBOSS_HOME
ENV WILDFLY_SERVER_CONFIGURATION=standalone.xml
```

Build and push to your OpenShift registry:

```bash
oc new-build --binary --name=session-demo -n session-demo
oc start-build session-demo --from-dir=. --follow
# Image lands at: image-registry.openshift-image-registry.svc:5000/session-demo/session-demo:latest
```

### 4.3 ConfigMap with CLI Configuration

The operator can run a CLI script at pod startup via the `CLI_LAUNCH_SCRIPT` environment variable. Mount the project's `configure-node.cli` as a ConfigMap.

The CLI script (`version2-external/scripts/configure-node.cli`) uses `${env.ISPN_HOST:localhost}` for the socket binding host, and hardcoded `auth_username`/`auth_password` properties. In the Operator deployment, inject credentials from a Secret into the CLI properties at runtime (see §4.5).

```bash
oc create configmap eap-hotrod-config \
  --from-file=configure-node.cli=demo-jboss-session/version2-external/scripts/configure-node.cli \
  -n session-demo
```

The ConfigMap will be mounted at:

```
/etc/configmaps/eap-hotrod-config/configure-node.cli
```

> **Note on CLI script credential injection:** The static `configure-node.cli` file uses hardcoded `auth_password=changeme`. For production, create a separate CLI script that reads `${env.ISPN_PASS}` instead, and reference the Secret-injected environment variable. See §4.5.

For a production-ready CLI script that reads credentials from environment variables:

```
# configure-node-env.cli
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
        infinispan.client.hotrod.auth_username=${env.ISPN_USER:developer}, \
        infinispan.client.hotrod.auth_password=${env.ISPN_PASS:changeme}, \
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

Create a configmap from this env-aware script:

```bash
oc create configmap eap-hotrod-config \
  --from-file=configure-node.cli=configure-node-env.cli \
  -n session-demo
```

### 4.4 WildFlyServer CR (EAP deployment)

```yaml
apiVersion: wildfly.org/v1alpha1
kind: WildFlyServer
metadata:
  name: session-demo
  namespace: session-demo
spec:
  applicationImage: >-
    image-registry.openshift-image-registry.svc:5000/session-demo/session-demo:latest
  replicas: 2

  # Mount the CLI configuration script
  configMaps:
    - name: eap-hotrod-config

  env:
    # Data Grid endpoint — matches the Infinispan CR DNS name (§3.5)
    - name: ISPN_HOST
      value: "data-grid.session-demo.svc.cluster.local"

    # Data Grid credentials injected from the dg-credentials Secret
    - name: ISPN_USER
      valueFrom:
        secretKeyRef:
          name: dg-credentials-eap
          key: username
    - name: ISPN_PASS
      valueFrom:
        secretKeyRef:
          name: dg-credentials-eap
          key: password

    # Tell the operator which CLI script to run at startup
    - name: CLI_LAUNCH_SCRIPT
      value: /etc/configmaps/eap-hotrod-config/configure-node.cli

  storage:
    volumeClaimTemplate:
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```

> `spec.storage.volumeClaimTemplate` provides persistent storage for WildFly transaction recovery logs. This is important when `NON_XA` transactions are used — without it, transaction recovery state is lost on pod restart.

Wait for the pods to be ready:

```bash
oc get wildflyserver session-demo -n session-demo -w
oc get pods -n session-demo -l app.kubernetes.io/name=session-demo
```

### 4.5 Credentials Wiring

The `dg-credentials` Secret created in §3.3 uses the `identities.yaml` format for the Data Grid Operator. EAP needs the same credentials as flat key/value entries. Create a separate Secret for EAP:

```bash
oc create secret generic dg-credentials-eap \
  --from-literal=username=developer \
  --from-literal=password=changeme \
  -n session-demo
```

The WildFlyServer CR references `dg-credentials-eap` to inject `ISPN_USER` and `ISPN_PASS` into each EAP pod. The CLI script reads these via WildFly expression syntax `${env.ISPN_USER:developer}` and `${env.ISPN_PASS:changeme}`.

---

## 5. Application Configuration

These requirements are identical to the bare-metal guide. See [`hotrod-external-infinispan-guide.md §5`](./hotrod-external-infinispan-guide.md#5-application-configuration) for full details.

### 5.1 `web.xml` — Enable Distributable Sessions

`<distributable/>` is **mandatory**. Without it, sessions remain node-local regardless of server configuration.

```xml
<!-- src/main/webapp/WEB-INF/web.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://jakarta.ee/xml/ns/jakartaee
             https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd"
         version="6.0">
    <distributable/>
</web-app>
```

### 5.2 `distributable-web.xml` — Optional Per-Application Override

Use this to pin a specific application to the `remote-sm` session management profile:

```xml
<!-- src/main/webapp/WEB-INF/distributable-web.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<distributable-web xmlns="urn:jboss:distributable-web:2.0">
    <hotrod-session-management name="remote-sm"/>
</distributable-web>
```

---

## 6. OpenShift Route — Sticky Sessions

With `affinity=local` in the `hotrod-session-management` profile, EAP prefers to serve requests on the node that has a local cached copy of the session. Sticky sessions at the Route level reduce cross-pod session reads.

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: session-demo
  namespace: session-demo
  annotations:
    # Enable cookie-based sticky sessions
    haproxy.router.openshift.io/disable_cookies: "false"
    haproxy.router.openshift.io/cookie_name: "JROUTE"
    # Round-robin with affinity; use "source" for IP-hash stickiness
    haproxy.router.openshift.io/balance: "roundrobin"
spec:
  to:
    kind: Service
    name: session-demo
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

> The `affinity=local` setting in WildFly corresponds to `JSESSIONID`-based affinity at the load balancer. The `haproxy.router.openshift.io/cookie_name` annotation sets the cookie that HAProxy uses to track pod affinity. If the target pod is unavailable, HAProxy falls back to round-robin, and WildFly transparently reloads the session from Data Grid.

---

## 7. End-to-End Deployment Order

1. **Install Data Grid Operator** — apply the `Subscription` from §3.1 and wait for the CSV to reach `Succeeded`.

2. **Create the credentials Secret** — `oc create secret generic dg-credentials --from-file=identities.yaml` (§3.3).

3. **Apply Infinispan CR** — `oc apply -f infinispan.yaml` and wait for `Status.Conditions[Ready]=True` (§3.2).

4. **Apply Cache CR** — `oc apply -f cache.yaml` for the `session-demo.war` distributed cache (§3.4).

5. **Install EAP Operator** — apply the `Subscription` from §4.1 and wait for the CSV to reach `Succeeded`.

6. **Build and push the application image** — include `cloud-server` + `web-clustering` Galleon layers (§4.2). The image must be pushed to a registry accessible from the cluster before the WildFlyServer CR is applied.

7. **Create the EAP credentials Secret** — `oc create secret generic dg-credentials-eap --from-literal=...` (§4.5).

8. **Create the ConfigMap with the CLI script** — `oc create configmap eap-hotrod-config --from-file=...` (§4.3).

9. **Apply WildFlyServer CR** — `oc apply -f wildflyserver.yaml` with `ISPN_HOST` pointing to the Data Grid Service DNS name (§4.4).

10. **Create the Route with sticky session annotations** — `oc apply -f route.yaml` (§6).

11. **Test** — use curl with a cookie jar across multiple requests to verify session persistence:

```bash
# Create a session on the first request
curl -c /tmp/cookies.txt \
  https://session-demo-session-demo.apps.cluster.example.com/session-demo/session

# Hit again — counter should increment, not reset
curl -b /tmp/cookies.txt \
  https://session-demo-session-demo.apps.cluster.example.com/session-demo/session

# Scale down one pod and verify the session survives
oc scale wildflyserver session-demo --replicas=1 -n session-demo
curl -b /tmp/cookies.txt \
  https://session-demo-session-demo.apps.cluster.example.com/session-demo/session
# Counter must continue from last value, not reset — session is in Data Grid
```

---

## 8. Troubleshooting

### `WFLYCLU0003: Remote cache does not exist`

The HotRod session manager cannot find the cache named `session-demo.war` on the Data Grid cluster.

**Causes and fixes:**
- Cache CR was not applied, or its `spec.name` does not match the WAR name exactly (including `.war` suffix).
- The Data Grid credentials user lacks the `CREATE_CACHE` permission (needed for auto-creation). Add the `admin` role in `identities.yaml`.
- Check with: `oc get cache -n session-demo` and verify `STATUS: Ready`.

### Authentication Failures (SASL / credential errors)

```
org.infinispan.client.hotrod.exceptions.HotRodClientException: Authentication failed
```

**Causes and fixes:**
- `ISPN_USER` / `ISPN_PASS` environment variables not injected — check `oc describe pod <eap-pod>` for the env values and confirm the Secret keys match.
- SASL mechanism mismatch — the CLI script uses `SCRAM-SHA-256`. Verify the Data Grid Server allows this mechanism in its endpoint configuration.
- Secret key name mismatch — confirm the `secretKeyRef.key` values (`username`, `password`) match the keys in `dg-credentials-eap`.

### WildFlyServer Pods Stuck in `Init` State

**Causes and fixes:**
- Image pull failure — verify the `spec.applicationImage` registry path is correct and an `ImagePullSecret` is configured if the registry requires authentication.
- ConfigMap mount failure — confirm `eap-hotrod-config` exists in the same namespace: `oc get configmap eap-hotrod-config -n session-demo`.
- CLI script error — check the init container logs: `oc logs <pod> -c jboss-eap-config -n session-demo`.

### Data Grid Operator Channel Deprecation

If you see warnings about a deprecated channel:
- The `Cache` service type (`spec.service.type: Cache`) was deprecated in DG 8.3 and removed in 8.4. Use `DataGrid` (§3.2).
- Operator subscription channels follow the pattern `8.5.x`. Do not use the `stable` channel for Data Grid — it may point to an older version. Check available channels with:

```bash
oc get packagemanifest datagrid -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
```

### Sessions Not Persisting After Pod Restart

If sessions disappear after an EAP pod restarts:
- Confirm `<distributable/>` is present in `web.xml` — its absence causes node-local sessions silently (see the companion guide §10).
- Confirm the CLI script ran successfully — check server logs: `oc logs <eap-pod> -n session-demo | grep -i 'hotrod\|distributable\|WFLY'`.
- Confirm the `Cache` CR is in `Ready` state before the EAP pod starts.

---

## 9. References

- [WildFly Operator User Guide](https://github.com/wildfly/wildfly-operator/blob/main/doc/user-guide.adoc)
- [WildFly Operator API Reference — WildFlyServer spec](https://github.com/wildfly/wildfly-operator/blob/main/doc/apis.adoc)
- [Red Hat Data Grid Operator Guide 8.5](https://access.redhat.com/documentation/en-us/red_hat_data_grid/8.5/html/data_grid_operator_guide/)
- [Red Hat Data Grid — Cache CR API reference](https://access.redhat.com/documentation/en-us/red_hat_data_grid/8.5/html/data_grid_operator_guide/cache-cr)
- [Red Hat EAP 8 — Configuring Distributed HTTP Sessions with HotRod](https://access.redhat.com/documentation/en-us/red_hat_jboss_enterprise_application_platform/8.0/html/configuring_distributed_http_sessions/)
- [OpenShift Route — Configuring Route Cookie (HAProxy annotations)](https://docs.openshift.com/container-platform/4.14/networking/routes/route-configuration.html#nw-route-specific-annotations_route-configuration)
- [Infinispan Operator — Identities Secret format](https://infinispan.org/docs/infinispan-operator/main/operator.html#securing-connections)
