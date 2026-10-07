# Troubleshooting

## The job runs but isn't faster / Gluten does nothing

Check the plan first (see [Is Gluten actually working?](../README.md#is-gluten-actually-working)). If there are no `...Transformer` operators:

| Cause | Fix |
|---|---|
| `spark.plugins` not set or misspelled | `--conf spark.plugins=org.apache.gluten.GlutenPlugin` |
| Jar not on the classpath | Driver log should show `GlutenDriverPlugin: Gluten components: ... Velox`. If not, check `--jars` and both `extraClassPath` settings |
| Table is CSV / text / JSON / Hive SerDe | Only Parquet and ORC scans are native. Convert hot tables to Parquet/ORC |
| A function or operator Velox doesn't support | Gluten falls back for that part of the plan. The **Gluten** tab in the Spark UI lists the reason per query |
| RDD API / Python UDFs | Only Spark SQL / DataFrame operators are accelerated. RDD code and Python UDFs stay in the JVM |

Gluten can be **slower** when a plan keeps switching between native and vanilla operators. Each switch converts columnar data to rows and back (`VeloxColumnarToRow` / `RowToVeloxColumnar` in the plan). Fix the fallback that causes it, or turn Gluten off for that job.

## `java.lang.NoSuchMethodError` / `NoSuchFieldError` / `ClassNotFoundException` mentioning `org.apache.spark...`

The Spark version doesn't match the jar.

- `transformWithSubqueries` → you're using the **official** Gluten jar on Spark 3.2.1. Use the jar from this repo's Releases.
- Anything else on Spark **3.2.2+** → use the official Gluten jar instead.
- On **CDP**, Cloudera's patched Spark may differ from Apache Spark 3.2.1 in some internal APIs. Send the full stack trace, and the jar can be rebuilt against Cloudera's Spark jars (see [BUILD.md](BUILD.md), with `-Dspark.version` pointing at Cloudera's artifacts).

## `UnsatisfiedLinkError` / `cannot open shared object file` / native library fails to load

| Message mentions | Fix |
|---|---|
| `GLIBC_2.xx not found` | The OS is too old. The jar needs glibc ≥ 2.17 (RHEL/CentOS 7+) |
| `libhdfs.so` | Velox can't find Hadoop's libhdfs. Check `ls /opt/cloudera/parcels/CDH/lib64/libhdfs.so` **on worker nodes**, and set `spark.executorEnv.LD_LIBRARY_PATH` / `ARROW_LIBHDFS_DIR` to that folder |
| `libjvm.so` | `JAVA_HOME` isn't set for executors. Add `--conf spark.executorEnv.JAVA_HOME=/usr/java/default` (your JDK path) |
| `Illegal instruction` (executor crashes, `SIGILL`) | The worker CPU has no AVX2. Run `grep -c avx2 /proc/cpuinfo` on each worker |

## Out of memory

| Message | Fix |
|---|---|
| `VeloxRuntimeError ... Exceeded memory pool cap` / `Velox memory pool ... OOM` / `SparkOutOfMemoryError` mentioning off-heap | Raise `spark.memory.offHeap.size` |
| `java.lang.OutOfMemoryError: Java heap space` | Raise `spark.executor.memory` (Gluten still needs some heap) |
| YARN kills the container (`Container killed ... running beyond physical memory limits`) | Raise `spark.executor.memoryOverhead` |
| YARN won't start the container (`Required executor memory ... is above the max threshold`) | heap + overhead + off-heap is bigger than `yarn.scheduler.maximum-allocation-mb`. Lower the three settings |

## Kerberos / HDFS access denied in Gluten runs only

Velox reads HDFS through `libhdfs.so`, which uses the executor's Hadoop configuration and Kerberos credentials. If vanilla works but Gluten gets `AccessControlException` or auth errors, make sure the executors have `HADOOP_CONF_DIR` set (CDP normally does this) and send the full executor log.

## `--properties-file` broke other settings

`--properties-file` **replaces** CDP's `spark-defaults.conf`, so you lose the event log dir, YARN settings and so on. Use `--conf` flags instead. `run-poc.sh` turns `gluten-velox.conf` into `--conf` flags for exactly this reason.

## Turning Gluten off quickly

Leave out `spark.plugins` and the `ColumnarShuffleManager` line, or add `--conf spark.gluten.enabled=false`.
