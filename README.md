# Gluten + Velox for Spark 3.2.1 (CDP 7.1.7 SP1 / RHEL 8)

A ready-to-use **[Apache Gluten](https://github.com/apache/incubator-gluten) 1.5.0 + Velox** jar that works on **Apache Spark 3.2.1**, plus scripts to compare your jobs on vanilla Spark against Gluten.

Gluten is a Spark plugin. It hands Spark SQL / DataFrame work to **Velox**, a native C++ engine, so you don't change any job code. You just add a jar and a few `--conf` settings.

> **Why this repo exists:** the official Gluten 1.5.0 jar is compiled against Spark **3.2.2** and fails on 3.2.1 at the first query:
> ```
> java.lang.NoSuchMethodError: org.apache.spark.sql.execution.SparkPlan.transformWithSubqueries(Lscala/PartialFunction;)...
> ```
> The jar here is rebuilt against Spark 3.2.1. See [How the jar was built](docs/BUILD.md).

---

## Contents

- [Download](#download)
- [Compatibility](#compatibility)
- [Quick start on a CDP cluster](#quick-start-on-a-cdp-cluster)
- [Examples](#examples)
- [Is Gluten actually working?](#is-gluten-actually-working)
- [Benchmark results](#benchmark-results)
- [Memory settings](#memory-settings)
- [Try it locally with Docker](#try-it-locally-with-docker)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [How the jar was built](docs/BUILD.md)

---

## Download

The jar is 129 MB, too big for a normal git file, so it's attached to the **[Releases](../../releases)** page.

| File | |
|---|---|
| [`gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar`](../../releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar) | the jar |
| [`...jar.sha512`](../../releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar.sha512) | checksum |

```bash
wget https://github.com/ukonduru91/gluten-velox-spark321-cdp/releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar
wget https://github.com/ukonduru91/gluten-velox-spark321-cdp/releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar.sha512
sha512sum -c gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar.sha512
```

---

## Compatibility

| | Requirement | Status |
|---|---|---|
| Spark | **3.2.1**, Scala 2.12 (3.2.0 has the same APIs and should work, but is untested) | ✅ tested on Apache Spark 3.2.1 |
| Java | JDK 8 (JDK 17 works with the `--add-opens` flags in [`cluster/gluten-velox.conf`](cluster/gluten-velox.conf)) | ✅ tested on OpenJDK 1.8.0 |
| OS | Linux x86_64 with glibc ≥ 2.17: RHEL / CentOS / Rocky 7, 8, 9 | ✅ tested on RHEL 8.10 |
| CPU | x86_64 with **AVX2** (`grep -c avx2 /proc/cpuinfo` > 0) | required |
| File formats | Parquet, ORC (native). CSV/text/Hive SerDe tables fall back to vanilla Spark | ✅ Parquet + ORC tested |
| Cluster | YARN on CDP 7.1.7 SP1 (CDS 3.2) | ⚠️ not yet tested on a real cluster, see notes below |

**Not included:** the Delta Lake, Iceberg, Hudi and Paimon connectors (the official jar has them, this build doesn't). Hive, Parquet and ORC tables are covered.

**Spark 3.2.2 or newer?** Use the [official Gluten jar](https://gluten.apache.org/downloads/) instead. Check with `spark3-submit --version`.

> ⚠️ **On CDP:** Cloudera's Spark is Apache Spark plus Cloudera patches. This jar is tested on Apache Spark 3.2.1, not on Cloudera's build, and HDFS reads through `libhdfs.so` and Kerberos haven't been tested yet. **Run one small job first** (step 3 below).

---

## Quick start on a CDP cluster

You only need the jar on the **edge/gateway node**, the machine you run `spark3-submit` from. `--jars` ships it to the YARN containers. Nothing needs installing on worker nodes.

**1. Copy the files to the edge node**

```bash
sudo mkdir -p /opt/gluten && sudo chown $USER /opt/gluten
cd /opt/gluten
wget https://github.com/ukonduru91/gluten-velox-spark321-cdp/releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar
git clone https://github.com/ukonduru91/gluten-velox-spark321-cdp.git repo
chmod +x repo/cluster/*.sh repo/examples/*.sh
```

**2. Check the environment**

```bash
spark3-submit --version                          # should say 3.2.0 or 3.2.1
ls /opt/cloudera/parcels/CDH/lib64/libhdfs.so    # Velox reads HDFS through this
ssh <any-worker-node> 'grep -c avx2 /proc/cpuinfo'   # must be > 0
```

**3. Smoke test: one small job with Gluten**

```bash
cd /opt/gluten/repo/examples
./submit-vanilla.sh sample_etl_job.py --generate hdfs:///tmp/gluten_poc/sales 10000000   # create test data once
./submit-gluten.sh  sample_etl_job.py hdfs:///tmp/gluten_poc/sales hdfs:///tmp/gluten_poc/out_gluten
```

In the YARN driver log (`yarn logs -applicationId <app id> | grep GLUTEN_`) you should see something like:
```
JOB_TIME_SECONDS=...
GLUTEN_NATIVE_OPERATORS=41      <- more than 0 means Velox did the work
```

**4. Compare your own job**

```bash
cd /opt/gluten/repo/cluster
./run-poc.sh --class com.mycompany.MyJob /path/to/my-job.jar arg1 arg2   # Scala/Java job
./run-poc.sh /path/to/my_job.py arg1 arg2                               # PySpark job
```

`run-poc.sh` runs the job twice, vanilla then Gluten, with the **same YARN container size** each time. It prints both wall-clock times and appends them to `poc-results.txt`. Both runs show up in the Spark 3 History Server as `poc-vanilla` and `poc-gluten`.

---

## Examples

All examples are in [`examples/`](examples/). Each script takes the jar path from `GLUTEN_JAR` (default `/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar`).

### Same job, with and without Gluten

```bash
# vanilla Spark
./examples/submit-vanilla.sh my_job.py <args>

# Gluten + Velox: same job, same arguments
./examples/submit-gluten.sh  my_job.py <args>

# Scala/Java jobs work the same way
./examples/submit-gluten.sh --class com.mycompany.MyJob my-job.jar <args>
```

### The settings that turn Gluten on

These are the lines [`submit-gluten.sh`](examples/submit-gluten.sh) adds to a normal `spark3-submit`:

```bash
GLUTEN_JAR=/opt/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar

spark3-submit --master yarn --deploy-mode cluster \
  --jars $GLUTEN_JAR \
  --conf spark.driver.extraClassPath=$(basename $GLUTEN_JAR) \
  --conf spark.executor.extraClassPath=$(basename $GLUTEN_JAR) \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=12g \
  --executor-memory 4g \
  --conf spark.executorEnv.LD_LIBRARY_PATH=/opt/cloudera/parcels/CDH/lib64:/opt/cloudera/parcels/CDH/lib/hadoop/lib/native \
  --conf spark.executorEnv.ARROW_LIBHDFS_DIR=/opt/cloudera/parcels/CDH/lib64 \
  my_job.py
```

| Setting | Why |
|---|---|
| `--jars` + `extraClassPath` | Ships the jar to YARN and puts it first on the classpath. In cluster mode use only the **file name** for `extraClassPath`; YARN puts shipped jars in each container's working directory |
| `spark.plugins=...GlutenPlugin` | Turns Gluten on |
| `spark.shuffle.manager=...ColumnarShuffleManager` | Shuffle stays in columnar format and doesn't convert back to rows |
| `spark.memory.offHeap.*` | Velox works **off-heap**. Give it most of the memory, see [Memory settings](#memory-settings) |
| `LD_LIBRARY_PATH`, `ARROW_LIBHDFS_DIR` | Lets Velox find `libhdfs.so` from the CDH parcel to read HDFS |

### Interactive shells (`spark3-sql`, `pyspark3`, `spark3-shell`)

```bash
./examples/interactive-shells.sh sql       # spark3-sql with Gluten
./examples/interactive-shells.sh pyspark   # pyspark3 with Gluten
./examples/interactive-shells.sh scala     # spark3-shell with Gluten
```
```sql
spark-sql> EXPLAIN SELECT region, sum(amount) FROM sales_db.sales GROUP BY region;
-- look for ...Transformer operators in the plan
```

Shells run the driver on the edge node (client mode), so `spark.driver.extraClassPath` must be the **full path** to the jar. The script handles that.

### Upload the jar to HDFS once (optional)

That way each `spark3-submit` doesn't upload 129 MB again:
```bash
hdfs dfs -mkdir -p /apps/gluten
hdfs dfs -put gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar /apps/gluten/
export GLUTEN_JAR=hdfs:///apps/gluten/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar
./examples/submit-gluten.sh my_job.py
```

---

## Is Gluten actually working?

Gluten silently falls back to vanilla Spark for anything it can't run natively, so always check:

1. **Spark UI / History Server → SQL tab → the query's plan.** Native operators end in `Transformer`: `ScanTransformer parquet`, `FilterExecTransformer`, `BroadcastHashJoinExecTransformer`, `RegularHashAggregateExecTransformer`, `ColumnarExchange`, `VeloxColumnarToRow`. If you only see `FileScan`, `HashAggregate`, `SortMergeJoin` and so on, Gluten isn't active.
2. **The "Gluten SQL / DataFrame" tab** in the Spark UI (from `spark.gluten.ui.enabled=true`) lists each query's **fallback reasons**.
3. **Driver log:** `grep -i "fallback" driver.log`
4. **In code** (PySpark), after an action:
   ```python
   execs = spark._jsparkSession.sharedState().statusStore().executionsList()
   plan = execs.apply(execs.size() - 1).physicalPlanDescription()
   print("native operators:", plan.count("Transformer"))
   ```
   With AQE on, `df._jdf.queryExecution().executedPlan()` shows the plan from **before** execution, without Gluten's operators. Don't rely on it.

**Normal fallbacks on Spark 3.2:** writing files (`InsertIntoHadoopFsRelationCommand`) runs in vanilla Spark, because native writes need Spark 3.4+. You'll see a `VeloxColumnarToRow` just before the write. Reading and all the processing still run in Velox.

---

## Benchmark results

Measured in the Docker test bed in this repo ([`docker/`](docker/)): RHEL 8.10, OpenJDK 8, Apache Spark 3.2.1, `local[4]`. Both runs had the same 4 GB of memory: vanilla as a 4 GB heap, Gluten as a 1 GB heap plus 3 GB off-heap.

**20 M-row TPC-H-like data** (`lineitem` 20 M rows, `orders` 5 M rows, Parquet + ORC):

| Query | Vanilla | Gluten | Speedup | Same result? |
|---|---:|---:|---:|:---:|
| Scan + filter + aggregate | 14.1 s | 8.7 s | **1.6×** | ✅ |
| Join + aggregate | 16.9 s | 7.0 s | **2.4×** | ✅ |
| Group by 5 M keys + top-100 | 29.4 s | 5.2 s | **5.7×** | ✅ |
| Window function | 5.9 s | 2.5 s | **2.3×** | ✅ |
| ORC scan + string functions | 2.6 s | 1.2 s | **2.1×** | ✅ |
| **Total** | **68.9 s** | **24.7 s** | **2.8×** | |

**Small data hides the gain.** On a 10 M-row ETL job ([`sample_etl_job.py`](examples/sample_etl_job.py)) wall-clock time was about the same (≈ 10–12 s for both), because job startup and scheduling dominate. Executor **CPU time** still dropped from ~27 s to ~12 s, which is **2.3× less CPU**. When you compare:

- use realistic data sizes, at least tens of GB on a cluster
- compare **executor CPU time** and **stage times** in the History Server, not just wall-clock time
- run each job 2–3 times and ignore the first run, which includes JVM and cache warm-up

These are single-machine numbers. Your cluster results will depend on your queries, data and file formats.

---

## Memory settings

Velox allocates its memory **off-heap**, outside the JVM heap. A YARN executor container is:

```
container size = spark.executor.memory + spark.executor.memoryOverhead + spark.memory.offHeap.size
```

| | Vanilla | Gluten |
|---|---|---|
| `spark.executor.memory` (heap) | 16g | **4g** |
| `spark.executor.memoryOverhead` | 2g | 2g |
| `spark.memory.offHeap.size` | — | **12g** |
| **YARN container** | **18g** | **18g** |

- Keep the container size the **same** for both runs so the comparison is fair.
- A good starting split for Gluten is about **75% off-heap / 25% heap**.
- If Gluten tasks fail with `OutOfMemory` / "Velox memory pool" errors, raise `spark.memory.offHeap.size`. If they fail with Java heap errors, raise `spark.executor.memory`.
- If YARN rejects the container, lower all three numbers together for both runs.

All settings are in [`cluster/gluten-velox.conf`](cluster/gluten-velox.conf).

---

## Try it locally with Docker

The [`docker/`](docker/) folder builds a test machine that mirrors a CDP worker: **RHEL 8.10 (UBI 8) + OpenJDK 8 + Apache Spark 3.2.1 + Spark History Server**. It runs the benchmark above.

```bash
cd docker
# 1. Spark 3.2.1 (300 MB) and the Gluten jar
curl -LO https://archive.apache.org/dist/spark/spark-3.2.1/spark-3.2.1-bin-hadoop3.2.tgz
mkdir -p ../jars && curl -L -o ../jars/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar \
  https://github.com/ukonduru91/gluten-velox-spark321-cdp/releases/download/v1.5.0-spark3.2.1/gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar

# 2. Build and start (the History Server comes up on http://localhost:18080)
docker build -t gluten-poc:spark3.2.1-rhel8 .
mkdir -p out/events
docker run -d --name gluten-poc -p 18080:18080 -m 7g --cpus 4 \
  -v "$PWD/../jars:/jars:ro" -v "$PWD:/work" -v gluten-poc-data:/data \
  gluten-poc:spark3.2.1-rhel8

# 3. Run vanilla vs Gluten (ROWS = lineitem rows; data is generated on the first run)
docker exec -e ROWS=20000000 gluten-poc bash /work/compare.sh
```

Output:
```
query         vanilla s  gluten s  speedup  native ops  result match
q1_agg            14.13      8.71    1.62x           9  OK
...
TOTAL             68.88     24.65    2.79x
```

The container needs about 7 GB of RAM. On Docker Desktop, check **Settings → Resources**.

---

## Repository layout

```
cluster/
  run-poc.sh            run a job vanilla vs Gluten on YARN, print both times
  gluten-velox.conf     all Gluten settings (read by run-poc.sh)
examples/
  submit-vanilla.sh     spark3-submit without Gluten
  submit-gluten.sh      spark3-submit with Gluten
  interactive-shells.sh spark3-sql / pyspark3 / spark3-shell with Gluten
  sample_etl_job.py     small ETL job (+ test data generator) to try it with
docker/                 local RHEL 8.10 + Spark 3.2.1 test bed and benchmark
build/                  patches and scripts used to build the jar (see docs/BUILD.md)
docs/
  BUILD.md              how the jar was built and how to rebuild it
  TROUBLESHOOTING.md    common errors and fixes
```

---

## License

Apache Gluten (incubating) and Velox are licensed under the [Apache License 2.0](LICENSE). This repo redistributes a build of Gluten 1.5.0 with small source changes for Spark 3.2.1 compatibility ([`build/spark-3.2.1-compat.patch`](build/spark-3.2.1-compat.patch)). See [`LICENSE-binary`](LICENSE-binary) and [`NOTICE-binary`](NOTICE-binary) for the bundled third-party components, and [`DISCLAIMER`](DISCLAIMER).

This is a community build. It is **not an official Apache Gluten release** and is not affiliated with or endorsed by the Apache Software Foundation or Cloudera.
