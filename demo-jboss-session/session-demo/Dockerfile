# Use the official Red Hat JBoss EAP 8 application builder image
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-builder-openshift-rhel9:latest AS builder

# Note: The S2I tools usually do the build automatically, but keeping it simple for a Dockerfile.
# You can also use a generic Maven builder and then copy the WAR to the EAP runtime.
USER root
RUN mkdir -p /tmp/src
WORKDIR /tmp/src
COPY pom.xml .
COPY src ./src
RUN mvn clean package

# Use the official Red Hat EAP 8 runtime image
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-runtime-openshift-rhel9:latest

# Copy the generated WAR file into the WildFly deployments folder
COPY --from=builder /tmp/src/target/session-demo.war /opt/eap/standalone/deployments/
