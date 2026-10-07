# Test bed that mirrors the CDP worker nodes: RHEL 8.10 + JDK 8 + Spark 3.2.1 (Scala 2.12)
FROM redhat/ubi8:8.10

RUN dnf -y install java-1.8.0-openjdk-headless python39 procps-ng hostname which findutils \
 && dnf clean all

ENV JAVA_HOME=/usr/lib/jvm/jre-1.8.0 \
    SPARK_HOME=/opt/spark \
    PYSPARK_PYTHON=python3.9 \
    PATH=/opt/spark/bin:$PATH

COPY spark-3.2.1-bin-hadoop3.2.tgz /tmp/
RUN tar -xzf /tmp/spark-3.2.1-bin-hadoop3.2.tgz -C /opt \
 && mv /opt/spark-3.2.1-bin-hadoop3.2 /opt/spark \
 && rm /tmp/spark-3.2.1-bin-hadoop3.2.tgz

# Spark History Server reads the event logs both runs write to /work/out/events
COPY spark-defaults.conf /opt/spark/conf/spark-defaults.conf
RUN mkdir -p /work/out/events /data /jars

WORKDIR /work
EXPOSE 18080
# History Server runs in the foreground; jobs are launched with `docker exec`
ENV SPARK_NO_DAEMONIZE=true
CMD ["/opt/spark/sbin/start-history-server.sh"]
