#!/usr/bin/env bash
# Same job with Gluten + Velox.
#
#   ./submit-gluten.sh sample_etl_job.py hdfs:///data/lineitem hdfs:///tmp/poc_out_gluten
#
# Memory: 4g heap + 2g overhead + 12g off-heap (used by Velox) = 18g per executor,
# the same YARN container size as submit-vanilla.sh.
set -euo pipefail

# Local path on the edge node, or an hdfs:// path (upload once, saves 129 MB per submit)
GLUTEN_JAR=${GLUTEN_JAR:-/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar}
# Where the CDH parcel keeps libhdfs.so (Velox uses it to read HDFS)
CDH_LIB=${CDH_LIB:-/opt/cloudera/parcels/CDH/lib64}

spark3-submit \
  --master yarn --deploy-mode cluster \
  --name poc-gluten \
  --num-executors 10 --executor-cores 4 \
  --executor-memory 4g \
  --conf spark.executor.memoryOverhead=2g \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=12g \
  --jars "$GLUTEN_JAR" \
  --conf spark.driver.extraClassPath="$(basename "$GLUTEN_JAR")" \
  --conf spark.executor.extraClassPath="$(basename "$GLUTEN_JAR")" \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.gluten.sql.columnar.forceShuffledHashJoin=true \
  --conf spark.gluten.ui.enabled=true \
  --conf spark.sql.adaptive.enabled=true \
  --conf spark.executorEnv.LD_LIBRARY_PATH="$CDH_LIB:/opt/cloudera/parcels/CDH/lib/hadoop/lib/native" \
  --conf spark.yarn.appMasterEnv.LD_LIBRARY_PATH="$CDH_LIB:/opt/cloudera/parcels/CDH/lib/hadoop/lib/native" \
  --conf spark.executorEnv.ARROW_LIBHDFS_DIR="$CDH_LIB" \
  --conf spark.eventLog.enabled=true \
  "$@"
