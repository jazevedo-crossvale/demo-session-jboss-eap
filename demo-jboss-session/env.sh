#!/usr/bin/env bash
# Source this file before running any demo scripts:
#   source env.sh

export WILDFLY_HOME=/home/jazevedo/Downloads/wildfly-31.0.1.Final
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-arm64

# Version 2 only: hostname/IP of the Infinispan Server (default: localhost)
# Change this if Infinispan runs in Docker with a custom network hostname.
export ISPN_HOST=localhost

echo "WILDFLY_HOME=$WILDFLY_HOME"
echo "JAVA_HOME=$JAVA_HOME"
echo "ISPN_HOST=$ISPN_HOST"
