# How the jar was built

**Short version:** Gluten's Java/Scala layer was recompiled against Spark 3.2.1 with 4 small source fixes. The native libraries (Velox, `libgluten.so`) and Gluten's patched Arrow are the **unchanged files from the official Apache Gluten 1.5.0 release**, built from the same source commit, so the Java ↔ native (JNI) interface matches exactly.

## Why the official jar fails on Spark 3.2.1

Gluten's `spark-3.2` profile compiles against Spark **3.2.2**. Between 3.2.1 and 3.2.2 Spark changed some internal APIs that Gluten uses:

| Spark API | 3.2.1 | 3.2.2 | Gluten code affected |
|---|---|---|---|
| `QueryPlan.transformWithSubqueries` | doesn't exist (only `transformUpWithSubqueries`) | added | `MiscColumnarRules.RewriteSubqueryBroadcast`, `BloomFilterMightContainJointRewriteRule` |
| `HashAggregateExec` / `ObjectHashAggregateExec` / `SortAggregateExec` | 7 fields | 9 fields (`isStreaming`, `numShufflePartitions` added) | `MergeTwoPhasesHashBaseAggregate` |
| `ProjectionOverSchema.apply` | `(schema)` | `(schema, output)` | `HiveTableScanNestedColumnPruning` |

The first one makes the official jar crash at the first query with `NoSuchMethodError: SparkPlan.transformWithSubqueries`. The others would fail later, as soon as those code paths run.

## The source changes

All in [`build/spark-3.2.1-compat.patch`](../build/spark-3.2.1-compat.patch), applied to the Gluten 1.5.0 source release:

1. **New `SubqueryTransformUtil.transformDownWithSubqueries`**: the same behaviour as Spark 3.2.2's `transformWithSubqueries` (a top-down transform that also descends into subquery plans), built only from APIs that exist in 3.2.1. Both call sites use it.
2. **`MergeTwoPhasesHashBaseAggregate`**: the patterns match the 7-field 3.2.1 aggregate classes. The "don't merge streaming aggregates" check now reads `isStreaming` from the plan's logical link (`agg.logicalLink.exists(_.isStreaming)`) instead of the 3.2.2-only field.
3. **`HiveTableScanNestedColumnPruning`**: uses the one-argument `ProjectionOverSchema(schema)`, the same call Spark 3.2.1 itself makes.

## Arrow

Gluten depends on `arrow-*:15.0.0-gluten`, Apache Arrow 15.0.0 with Gluten's patches. It isn't published to Maven Central. Gluten only patches **`arrow-dataset`** at the Java level (`ep/build-velox/src/modify_arrow_dataset_scan_option.patch`). So:

- for **compiling**, [`build/patch-arrow-dataset.sh`](../build/patch-arrow-dataset.sh) takes the official `arrow-dataset-15.0.0-sources.jar` from Maven Central, applies Gluten's patch, compiles it, and puts it in the build's local Maven repo
- in the **final jar**, the Arrow `c` / `dataset` classes and their JNI `.so` files are the exact files from the official Gluten 1.5.0 jar

## Build steps

Requirements: Docker. The build runs in `maven:3.9-eclipse-temurin-8` (JDK 8, matching the official build's `java_version=1.8`).

```bash
# 1. Official release: source + binary jar (checksums: https://archive.apache.org/dist/incubator/gluten/1.5.0-incubating/)
curl -LO https://archive.apache.org/dist/incubator/gluten/1.5.0-incubating/apache-gluten-1.5.0-incubating-src.tar.gz
curl -LO https://archive.apache.org/dist/incubator/gluten/1.5.0-incubating/apache-gluten-1.5.0-incubating-bin-spark-3.2.tar.gz
tar xzf apache-gluten-1.5.0-incubating-src.tar.gz && mv incubator-gluten-1.5.0 gluten-src
tar xzf apache-gluten-1.5.0-incubating-bin-spark-3.2.tar.gz   # -> gluten-velox-bundle-spark3.2_2.12-linux_amd64-1.5.0.jar

# 2. Apply the Spark 3.2.1 fixes
cd gluten-src && git apply ../build/spark-3.2.1-compat.patch && cd ..

# 3. Put the source in a Docker volume (much faster than a Windows/macOS bind mount)
docker volume create gluten-src-vol
tar -C gluten-src -cf - . | docker run --rm -i -v gluten-src-vol:/src maven:3.9-eclipse-temurin-8 \
  sh -c 'tar -xf - -C /src && mkdir -p /src/cpp/build/releases'

# 4. First Maven pass (compiles the protos the Arrow patch needs; it stops at gluten-arrow, that's expected),
#    then build the patched arrow-dataset, then the full build
RUN="docker run --rm -m 4g -e MAVEN_OPTS=-Xmx2g -v gluten-src-vol:/src -v gluten-m2:/root/.m2 \
     -v $PWD/build:/build:ro maven:3.9-eclipse-temurin-8"
$RUN bash /build/mvn-build.sh || true
$RUN bash /build/patch-arrow-dataset.sh
$RUN bash /build/mvn-build.sh

# 5. Take the bundle out and overlay the official native libs + patched Arrow classes
docker run --rm -v gluten-src-vol:/src -v $PWD:/out maven:3.9-eclipse-temurin-8 \
  cp /src/package/target/gluten-velox-bundle-spark3.2_2.12-linux_amd64-1.5.0.jar /out/rebuilt-bundle.jar
python3 build/assemble_jar.py rebuilt-bundle.jar \
  gluten-velox-bundle-spark3.2_2.12-linux_amd64-1.5.0.jar \
  gluten-velox-bundle-spark3.2.1_2.12-linux_amd64-1.5.0-rhel8.jar
```

[`build/mvn-build.sh`](../build/mvn-build.sh) runs:
```bash
mvn -B -T 2 package -Pbackends-velox -Pspark-3.2 \
  -Dspark.version=3.2.1 -Darrow-gluten.version=15.0.0 -DskipTests ...
```

[`build/assemble_jar.py`](../build/assemble_jar.py) starts from the rebuilt bundle and replaces `org/apache/arrow/**`, `linux/amd64/*.so` and `x86_64/*.so` with the official release's copies. It drops the unpatched `aarch_64` Arrow libraries, since this build is x86_64 only.

## What's in the jar

```
gluten-build-info.properties   spark_version=3.2.1, java_version=1.8, scala_version=2.12.15, backend_type=velox
linux/amd64/libgluten.so       official 1.5.0 (built with GCC 11, needs glibc >= 2.17)
linux/amd64/libvelox.so        official 1.5.0 (Velox 657a00386d35)
x86_64/libarrow_*_jni.so       official 1.5.0
org/apache/gluten/**           rebuilt against Spark 3.2.1
org/apache/arrow/{c,dataset}   official 1.5.0
```

## Adding Delta / Iceberg / Hudi / Paimon

This build leaves out the lakehouse connectors. To include them, add the Maven profiles to `mvn-build.sh`, e.g. `-Pdelta -Piceberg`. Their code may hit more 3.2.1 vs 3.2.2 differences; the compiler will report them.
