#!/usr/bin/env bash
# Baseline: run a job on plain Spark (no Gluten).
#
#   ./submit-vanilla.sh sample_etl_job.py hdfs:///data/lineitem hdfs:///tmp/poc_out_vanilla
#
# Memory: 16g heap + 2g overhead = 18g per executor, the same YARN container size as
# submit-gluten.sh, so the comparison is fair.
set -euo pipefail

spark3-submit \
  --master yarn --deploy-mode cluster \
  --name poc-vanilla \
  --num-executors 10 --executor-cores 4 \
  --executor-memory 16g \
  --conf spark.executor.memoryOverhead=2g \
  --conf spark.sql.adaptive.enabled=true \
  --conf spark.eventLog.enabled=true \
  "$@"
