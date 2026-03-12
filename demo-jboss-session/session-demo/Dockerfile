# Stage 1: Build the WAR with Maven using the EAP 8 builder image
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-builder-openshift-rhel9:latest AS builder
USER root
WORKDIR /tmp/src
COPY pom.xml .
COPY src ./src
RUN mvn clean package

# Stage 2: Lightweight EAP 8 runtime image (auto-configures HotRod from Service Binding)
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-runtime-openshift-rhel9:latest
COPY --from=builder /tmp/src/target/session-demo.war /opt/eap/standalone/deployments/
