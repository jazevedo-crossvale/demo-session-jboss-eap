# Stage 1: Build the WAR with Maven (public Eclipse Temurin JDK image)
FROM eclipse-temurin:17-jdk AS builder
RUN apt-get update && apt-get install -y maven
WORKDIR /tmp/src
COPY pom.xml .
COPY src ./src
RUN mvn clean package

# Stage 2: Run on WildFly (public image, no credentials needed)
FROM quay.io/wildfly/wildfly:36.0.1.Final-jdk17

# Copy the generated WAR file into WildFly deployments
COPY --from=builder /tmp/src/target/session-demo.war /opt/jboss/wildfly/standalone/deployments/
