#!/usr/bin/env bash
# Interactive shells with Gluten (spark3-sql / pyspark3 / spark3-shell).
#
#   ./interactive-shells.sh sql       # spark3-sql
#   ./interactive-shells.sh pyspark   # pyspark3
#   ./interactive-shells.sh scala     # spark3-shell
#
# Shells run the driver on the edge node (client mode), so the driver classpath must be the
# FULL local path of the jar, not just its file name.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The jar next to this folder (install layout), else /opt/gluten. Can be an hdfs:// path too.
GLUTEN_JAR=${GLUTEN_JAR:-$(ls "$ROOT"/gluten-velox-bundle-spark3.2.1_*.jar 2>/dev/null | head -1)}
GLUTEN_JAR=${GLUTEN_JAR:-/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar}
CDH_LIB=${CDH_LIB:-/opt/cloudera/parcels/CDH/lib64}

ARGS=(--master yarn
  --num-executors 4 --executor-cores 4
  --driver-memory 2g --conf spark.driver.memoryOverhead=1g
  --executor-memory 4g --conf spark.executor.memoryOverhead=2g
  --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=12g
  --jars "$GLUTEN_JAR"
  --conf spark.driver.extraClassPath="$GLUTEN_JAR"
  --conf spark.executor.extraClassPath="$(basename "$GLUTEN_JAR")"
  --conf spark.plugins=org.apache.gluten.GlutenPlugin
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
  --conf spark.gluten.sql.columnar.forceShuffledHashJoin=true
  --conf spark.executorEnv.LD_LIBRARY_PATH="$CDH_LIB:/opt/cloudera/parcels/CDH/lib/hadoop/lib/native"
  --conf spark.executorEnv.ARROW_LIBHDFS_DIR="$CDH_LIB")

case "${1:-sql}" in
  sql)     exec spark3-sql   "${ARGS[@]}" ;;
  pyspark) exec pyspark3     "${ARGS[@]}" ;;
  scala)   exec spark3-shell "${ARGS[@]}" ;;
  *) echo "usage: $0 [sql|pyspark|scala]"; exit 1 ;;
esac

# Inside the shell, check Gluten is active - the plan should contain "...Transformer" operators:
#   spark-sql> EXPLAIN SELECT region, count(*) FROM my_db.my_parquet_table GROUP BY region;
#   >>> spark.sql("SELECT ...").explain()
