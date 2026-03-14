# Stage 1: S2I build — provisions EAP 8, runs Maven, bakes CLI config, deploys WAR
#
# The assemble script:
#   1. Runs `mvn package` → wildfly-maven-plugin provisions EAP into target/server
#      with the cloud-server + web-clustering Galleon layers
#   2. Executes any *.cli files found under extensions/ against the provisioned server
#      (this is where postconfigure.cli runs and writes HotRod config into standalone.xml)
#   3. Copies the deployed WAR into the server's deployments/ directory
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-builder-openshift-rhel9:latest AS builder
COPY --chown=jboss:root . /tmp/src/
RUN /usr/local/s2i/assemble

# Stage 2: Runtime — minimal image; receives the fully-configured server from stage 1
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-runtime-openshift-rhel9:latest
COPY --from=builder /opt/server /opt/server
