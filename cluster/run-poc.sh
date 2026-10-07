#!/usr/bin/env bash
# Run the same job twice: vanilla Spark, then Gluten+Velox. Same resources both times,
# so the comparison is fair. Compare wall time here and per-stage times in the History Server.
#
# Usage: ./run-poc.sh [--class com.x.Main] <your-app.jar|your_job.py> [app args...]
set -euo pipefail

GLUTEN_JAR=${GLUTEN_JAR:-/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar}
HERE=$(cd "$(dirname "$0")" && pwd)

# Same total memory per executor in both runs: vanilla gets it on-heap,
# Gluten gets most of it off-heap (both ask YARN for 18g per executor: vanilla 16g heap + 2g overhead, Gluten 4g heap + 2g overhead + 12g off-heap).
COMMON=(--master yarn --deploy-mode cluster
        --num-executors 10 --executor-cores 4
        --conf spark.sql.adaptive.enabled=true
        --conf spark.eventLog.enabled=true)

run() {
  local name=$1; shift
  local t0=$(date +%s)
  spark3-submit --name "poc-$name" "${COMMON[@]}" "$@"
  echo "$name: $(( $(date +%s) - t0 ))s" | tee -a "$HERE/poc-results.txt"
}

run vanilla --conf spark.executor.memory=16g --conf spark.executor.memoryOverhead=2g "$@"

# Turn gluten-velox.conf into --conf flags (keeps CDP's spark-defaults.conf in effect,
# which --properties-file would replace)
GLUTEN_CONFS=()
while read -r k v; do
  [[ -z "$k" || "$k" == \#* ]] && continue
  GLUTEN_CONFS+=(--conf "$k=$v")
done < "$HERE/gluten-velox.conf"

run gluten  "${GLUTEN_CONFS[@]}" \
            --jars "$GLUTEN_JAR" \
            --conf spark.driver.extraClassPath="$(basename "$GLUTEN_JAR")" \
            --conf spark.executor.extraClassPath="$(basename "$GLUTEN_JAR")" \
            "$@"

cat "$HERE/poc-results.txt"
