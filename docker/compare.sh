#!/usr/bin/env bash
# Runs inside the container: generate data once, then run bench.py on vanilla Spark and on Gluten.
# Env: ROWS (lineitem rows, default 20M), CORES (default 4), GLUTEN_JAR
set -euo pipefail

ROWS=${ROWS:-20000000}
CORES=${CORES:-4}
DATA=/data/tpch_like_${ROWS}
GLUTEN_JAR=${GLUTEN_JAR:-/jars/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar}
OUT=/work/out
mkdir -p "$OUT"

COMMON=(--master "local[$CORES]" --conf spark.sql.shuffle.partitions=$((CORES * 2))
        --conf spark.sql.adaptive.enabled=true
        --conf spark.eventLog.enabled=true --conf spark.eventLog.dir=file://$OUT/events)
mkdir -p "$OUT/events"

if [ ! -d "$DATA/lineitem" ]; then
  echo ">>> generating $ROWS rows into $DATA"
  spark-submit "${COMMON[@]}" --driver-memory 4g /work/bench.py gen "$DATA" "$ROWS"
fi

# Same total memory both ways: vanilla 4g heap; Gluten 1g heap + 3g off-heap for Velox
echo ">>> vanilla"
spark-submit "${COMMON[@]}" --driver-memory 4g /work/bench.py run "$DATA" vanilla \
  2>"$OUT/vanilla.log" | tee "$OUT/vanilla.out"

echo ">>> gluten ($GLUTEN_JAR)"
spark-submit "${COMMON[@]}" --driver-memory 1g \
  --jars "$GLUTEN_JAR" \
  --conf spark.driver.extraClassPath="$GLUTEN_JAR" \
  --conf spark.executor.extraClassPath="$GLUTEN_JAR" \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=3g \
  --conf spark.gluten.sql.columnar.forceShuffledHashJoin=true \
  /work/bench.py run "$DATA" gluten \
  2>"$OUT/gluten.log" | tee "$OUT/gluten.out"

python3.9 - "$OUT/vanilla.out" "$OUT/gluten.out" <<'EOF'
import json, sys
def load(p):
    return next(json.loads(l[7:]) for l in open(p) if l.startswith("RESULT "))["results"]
v, g = load(sys.argv[1]), load(sys.argv[2])
print(f"\n{'query':<12}{'vanilla s':>11}{'gluten s':>10}{'speedup':>9}{'native ops':>12}  result match")
for q in v:
    a, b = v[q], g[q]
    print(f"{q:<12}{a['secs']:>11}{b['secs']:>10}{a['secs']/max(b['secs'],0.01):>8.2f}x"
          f"{b['native_ops']:>12}  {'OK' if a['checksum']==b['checksum'] else 'MISMATCH'}")
tv, tg = sum(x['secs'] for x in v.values()), sum(x['secs'] for x in g.values())
print(f"{'TOTAL':<12}{tv:>11.2f}{tg:>10.2f}{tv/tg:>8.2f}x")
EOF
