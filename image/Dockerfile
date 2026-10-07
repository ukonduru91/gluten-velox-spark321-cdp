# Distribution image: the Gluten jar + cluster scripts + benchmark, on UBI 8 minimal.
# It doesn't run Spark. You run it once on the edge node to copy everything out, then use
# spark3-submit on the host (it needs CDP's client configs and Kerberos ticket).
#
# Build (from the repo root, with the jar downloaded next to README.md):
#   docker build -f image/Dockerfile -t upendrak/gluten-velox-spark321-cdp:1.5.0-spark3.2.1 .
FROM redhat/ubi8-minimal:8.10

ARG JAR=gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar

LABEL org.opencontainers.image.title="gluten-velox-spark321-cdp" \
      org.opencontainers.image.description="Apache Gluten 1.5.0 + Velox jar for Spark 3.2.1 (CDP 7.1.7 SP1 / RHEL 8) with vanilla-vs-Gluten benchmark scripts" \
      org.opencontainers.image.source="https://github.com/ukonduru91/gluten-velox-spark321-cdp" \
      org.opencontainers.image.version="1.5.0-spark3.2.1" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /opt/gluten
COPY ${JAR} ${JAR}.sha512 ./
COPY cluster/   cluster/
COPY examples/  examples/
COPY docker/bench.py bench/bench.py
COPY docs/      docs/
COPY README.md LICENSE LICENSE-binary NOTICE NOTICE-binary DISCLAIMER ./
COPY image/entrypoint.sh /usr/local/bin/gluten-dist

RUN chmod 755 /usr/local/bin/gluten-dist cluster/*.sh examples/*.sh \
 && sha512sum -c ${JAR}.sha512

ENTRYPOINT ["/usr/local/bin/gluten-dist"]
CMD ["help"]
