# Stage 1: Build the WAR with Maven using the WildFly S2I builder image
FROM quay.io/wildfly/wildfly-s2i:latest AS builder
USER root
WORKDIR /tmp/src
COPY pom.xml .
COPY src ./src
RUN mvn clean package

# Stage 2: Lightweight WildFly runtime image (auto-configures HotRod from Service Binding)
FROM quay.io/wildfly/wildfly-runtime:latest
COPY --from=builder /tmp/src/target/session-demo.war /opt/server/standalone/deployments/
