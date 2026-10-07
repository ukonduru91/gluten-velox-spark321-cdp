#!/usr/bin/env bash
# The same 5-query benchmark as the Docker test, on YARN: generate TPC-H-like data on HDFS once,
# run it on vanilla Spark and on Gluten (same YARN container size), and print a comparison table.
#
#   ./run-benchmark.sh hdfs:///tmp/gluten_bench            # 200M rows (~10 GB Parquet), default
#   ./run-benchmark.sh hdfs:///tmp/gluten_bench 50000000   # smaller
#
# Env overrides: GLUTEN_JAR, NUM_EXECUTORS (10), EXECUTOR_CORES (4), SPARK_SUBMIT (spark3-submit),
#                MASTER (yarn), CDH_LIB (/opt/cloudera/parcels/CDH/lib64)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DATA=${1:?usage: $0 <hdfs_dir> [rows]}
ROWS=${2:-200000000}
DATA_DIR="${DATA%/}/tpch_like_${ROWS}"

GLUTEN_JAR=${GLUTEN_JAR:-$(ls "$ROOT"/gluten-velox-bundle-spark3.2.1_*.jar 2>/dev/null | head -1)}
GLUTEN_JAR=${GLUTEN_JAR:-/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar}
SPARK_SUBMIT=${SPARK_SUBMIT:-spark3-submit}
BENCH=$ROOT/bench/bench.py
OUT=$ROOT/results/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

# Client mode: the driver runs here, so its output (timings) lands in our log files.
COMMON=(--master "${MASTER:-yarn}" --deploy-mode client
        --num-executors "${NUM_EXECUTORS:-10}" --executor-cores "${EXECUTOR_CORES:-4}"
        --driver-memory 4g
        --conf spark.sql.adaptive.enabled=true
        --conf spark.eventLog.enabled=true)

data_exists() {
  if command -v hdfs >/dev/null 2>&1 && [[ "$DATA_DIR" != file:* && "$DATA_DIR" != /* ]]; then
    hdfs dfs -test -d "$DATA_DIR/lineitem"
  else
    [ -d "${DATA_DIR#file://}/lineitem" ]
  fi
}

[ -f "$GLUTEN_JAR" ] || [[ "$GLUTEN_JAR" == hdfs:* ]] || { echo "Gluten jar not found: $GLUTEN_JAR (set GLUTEN_JAR)"; exit 1; }
echo "jar:     $GLUTEN_JAR"
echo "data:    $DATA_DIR ($ROWS lineitem rows)"
echo "results: $OUT"

if ! data_exists; then
  echo ">>> generating data (one time)"
  $SPARK_SUBMIT "${COMMON[@]}" --name poc-gen \
    --executor-memory 16g --conf spark.executor.memoryOverhead=2g \
    "$BENCH" gen "$DATA_DIR" "$ROWS" 2>"$OUT/gen.log"
fi

# Vanilla: 16g heap + 2g overhead = 18g container
echo ">>> vanilla"
$SPARK_SUBMIT "${COMMON[@]}" \
  --executor-memory 16g --conf spark.executor.memoryOverhead=2g \
  "$BENCH" run "$DATA_DIR" vanilla 2>"$OUT/vanilla.log" | tee "$OUT/vanilla.out"

# Gluten: settings from gluten-velox.conf (4g heap + 2g overhead + 12g off-heap = 18g container)
GLUTEN_CONFS=()
while read -r k v; do
  [[ -z "$k" || "$k" == \#* ]] && continue
  GLUTEN_CONFS+=(--conf "$k=$v")
done < "$HERE/gluten-velox.conf"

echo ">>> gluten"
$SPARK_SUBMIT "${COMMON[@]}" "${GLUTEN_CONFS[@]}" \
  --conf spark.executorEnv.LD_LIBRARY_PATH="${CDH_LIB:-/opt/cloudera/parcels/CDH/lib64}:/opt/cloudera/parcels/CDH/lib/hadoop/lib/native" \
  --conf spark.executorEnv.ARROW_LIBHDFS_DIR="${CDH_LIB:-/opt/cloudera/parcels/CDH/lib64}" \
  --jars "$GLUTEN_JAR" \
  --conf spark.driver.extraClassPath="$GLUTEN_JAR" \
  --conf spark.executor.extraClassPath="$(basename "$GLUTEN_JAR")" \
  "$BENCH" run "$DATA_DIR" gluten 2>"$OUT/gluten.log" | tee "$OUT/gluten.out"

# Comparison table from lines like: [gluten] q1_agg: 8.71s rows=6 native_ops=9 checksum=d885b75709fc
awk '
  /^\[(vanilla|gluten)\] / {
    label = substr($1, 2, length($1) - 2); q = $2; sub(/:$/, "", q)
    secs = $3; sub(/s$/, "", secs)
    split($5, n, "="); split($6, c, "=")
    t[label, q] = secs; ops[label, q] = n[2]; sum[label, q] = c[2]
    if (label == "vanilla") order[++cnt] = q
  }
  END {
    printf "\n%-12s%11s%10s%9s%12s  %s\n", "query", "vanilla s", "gluten s", "speedup", "native ops", "result match"
    for (i = 1; i <= cnt; i++) {
      q = order[i]; v = t["vanilla", q]; g = t["gluten", q]
      printf "%-12s%11.2f%10.2f%8.2fx%12d  %s\n", q, v, g, (g > 0 ? v / g : 0), ops["gluten", q],
             (sum["vanilla", q] == sum["gluten", q] ? "OK" : "MISMATCH")
      tv += v; tg += g
    }
    printf "%-12s%11.2f%10.2f%8.2fx\n", "TOTAL", tv, tg, (tg > 0 ? tv / tg : 0)
  }' "$OUT/vanilla.out" "$OUT/gluten.out" | tee "$OUT/summary.txt"

echo
echo "Logs and summary: $OUT"
echo "Per-stage details: Spark 3 History Server, apps poc-vanilla and poc-gluten"
