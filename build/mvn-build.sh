#!/usr/bin/env bash
# Build Gluten 1.5.0 Java/Scala against Spark 3.2.1. Native libs are NOT built here: cpp/build/releases
# stays empty and build/assemble_jar.py adds the official release's .so files afterwards. See docs/BUILD.md
set -eo pipefail
cd /src
mvn -B -T 2 package \
  -Pbackends-velox -Pspark-3.2 \
  -Dspark.version=3.2.1 \
  -Darrow-gluten.version=15.0.0 \
  -DskipTests \
  -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dscalastyle.skip=true -Dcheckstyle.skip=true \
  -Daether.connector.http.retryHandler.count=10 -Daether.connector.requestTimeout=300000 \
  "$@"
