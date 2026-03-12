# JBoss EAP HTTP Session Storage PoC

Side-by-side demonstration of two session replication architectures on
WildFly 31 / EAP 8.

| | Version 1 — Embedded | Version 2 — External |
|---|---|---|
| **Session store** | Embedded Infinispan (in-process) | Standalone Infinispan Server |
| **Replication transport** | JGroups (peer-to-peer) | Hot Rod protocol |
| **Extra infrastructure** | None | Infinispan Server (Docker) |
| **Survives node failure** | Yes | Yes |
| **Survives full cluster restart** | **No** | **Yes** |
| **EAP config profile** | `standalone-ha.xml` | `standalone-ha.xml` (or `standalone.xml`) |

## Repository Layout

```
demo-jboss-session/
├── session-demo/                  # Shared Maven WAR project
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/example/SessionServlet.java
│       └── webapp/WEB-INF/
│           ├── web.xml                  # <distributable/>
│           └── distributable-web.xml   # Version 2: references "remote-sm"
│
├── version1-embedded/             # Embedded Infinispan replication
│   ├── README.md
│   ├── scripts/
│   │   ├── configure-node.cli
│   │   ├── start-node1.sh
│   │   └── start-node2.sh
│   ├── docker-compose.yml         # Optional HAProxy LB
│   └── haproxy.cfg
│
└── version2-external/             # External Infinispan via Hot Rod
    ├── README.md
    ├── docker-compose.yml         # Infinispan Server
    ├── infinispan/
    │   └── infinispan.xml         # Distributed cache config
    └── scripts/
        ├── configure-node.cli
        ├── start-node1.sh
        └── start-node2.sh
```

## Prerequisites

| Software | Version | Notes |
|----------|---------|-------|
| Java | 17+ | `java -version` |
| Maven | 3.8+ | `mvn -version` |
| WildFly / EAP | WildFly 31.x or EAP 8.0 | Set `WILDFLY_HOME` |
| Docker | 20+ | Version 2 only |

```bash
# Required environment variable
export WILDFLY_HOME=/path/to/wildfly-31.x.y.Final
```

## Quick Start

### Build the shared WAR (required for both versions)

```bash
cd session-demo
mvn clean package
ls -lh target/session-demo.war
```

### Run Version 1 (embedded)

See [version1-embedded/README.md](version1-embedded/README.md) for full instructions.

```bash
# Terminal 1
./version1-embedded/scripts/start-node1.sh

# Terminal 2
./version1-embedded/scripts/start-node2.sh

# Test
curl -c /tmp/c.txt http://localhost:8080/session-demo/session
curl -b /tmp/c.txt http://localhost:8180/session-demo/session
```

### Run Version 2 (external)

See [version2-external/README.md](version2-external/README.md) for full instructions.

```bash
# Start Infinispan
cd version2-external && docker compose up -d

# Configure and start EAP nodes (see README)
# Test — including full-restart survival:
curl -c /tmp/c.txt http://localhost:8080/session-demo/session   # counter=1
# Stop both EAP nodes, restart node1
curl -b /tmp/c.txt http://localhost:8080/session-demo/session   # counter=2 ✓
```

## Key Technical Points

- **`<distributable/>`** in `web.xml` is mandatory — without it sessions stay local
- **`org.wildfly.clustering.web.hotrod`** module must be declared in the
  remote-cache-container config (Version 2) — omitting it causes marshalling errors
- **`SCRAM-SHA-256`** is the recommended SASL mechanism for Hot Rod auth
- **ProtoStream** marshalling (`application/x-protostream`) is required for
  WildFly's Hot Rod session serialization
- Session attributes stored as `Integer` and `String` are already `Serializable` —
  custom objects must implement `java.io.Serializable`
