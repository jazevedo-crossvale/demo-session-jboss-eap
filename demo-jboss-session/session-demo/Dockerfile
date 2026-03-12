# Stage 1: S2I build — runs Maven and deploys WAR into WildFly at /opt/server
FROM quay.io/wildfly/wildfly-s2i:latest AS builder
COPY --chown=jboss:root . /tmp/src/
RUN /usr/local/s2i/assemble

# Stage 2: Runtime — copy the provisioned WildFly server with the deployed WAR
FROM quay.io/wildfly/wildfly-runtime:latest
COPY --from=builder /opt/server /opt/server
