"""POC benchmark: run the same queries on vanilla Spark and on Gluten+Velox.

  spark-submit bench.py gen  <data_dir> <rows>   # generate Parquet + ORC data once
  spark-submit bench.py run  <data_dir> <label>  # run queries, print timings + offload check
"""
import hashlib
import json
import sys
import time

from pyspark.sql import SparkSession, functions as F

QUERIES = {
    # scan + filter + aggregate
    "q1_agg": """
        SELECT l_returnflag, l_linestatus, sum(l_quantity) sum_qty,
               sum(l_extendedprice * (1 - l_discount)) revenue,
               avg(l_discount) avg_disc, count(*) cnt
        FROM lineitem WHERE l_shipdate <= date'1998-09-01'
        GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus""",
    # join + aggregate
    "q3_join": """
        SELECT o.o_orderpriority, count(*) cnt, sum(l.l_extendedprice) price
        FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey
        WHERE o.o_orderdate >= date'1995-01-01' AND l.l_discount > 0.02
        GROUP BY o.o_orderpriority ORDER BY o.o_orderpriority""",
    # high-cardinality group by + top-N
    "q18_topn": """
        SELECT l_orderkey, sum(l_quantity) q FROM lineitem
        GROUP BY l_orderkey ORDER BY q DESC, l_orderkey LIMIT 100""",
    # window function
    "q_window": """
        SELECT o_custkey, max(rn) FROM (
          SELECT o_custkey, row_number() OVER (PARTITION BY o_custkey ORDER BY o_totalprice DESC) rn
          FROM orders) t GROUP BY o_custkey ORDER BY o_custkey LIMIT 50""",
    # string functions + ORC scan
    "q_orc_str": """
        SELECT substr(o_comment, 1, 3) p, upper(o_orderpriority) pr, count(*) c
        FROM orders_orc WHERE o_comment LIKE '%a%' GROUP BY 1, 2 ORDER BY 1, 2 LIMIT 50""",
}


def gen(spark, path, rows):
    orders_n = rows // 4
    orders = (spark.range(orders_n).withColumnRenamed("id", "o_orderkey")
              .withColumn("o_custkey", (F.col("o_orderkey") * 7919) % (orders_n // 10 + 1))
              .withColumn("o_totalprice", F.round(F.rand(1) * 100000, 2).cast("decimal(12,2)"))
              .withColumn("o_orderdate", F.expr("date_add(date'1992-01-01', cast(rand(2) * 2500 as int))"))
              .withColumn("o_orderpriority", F.element_at(F.array(*[F.lit(p) for p in
                          ["1-URGENT", "2-HIGH", "3-MEDIUM", "4-NOT SPECIFIED", "5-LOW"]]),
                          (F.col("o_orderkey") % 5 + 1).cast("int")))
              .withColumn("o_comment", F.expr("md5(cast(o_orderkey as string))")))
    lineitem = (spark.range(rows).withColumnRenamed("id", "l_id")
                .withColumn("l_orderkey", (F.col("l_id") * 2654435761) % orders_n)
                .withColumn("l_quantity", (F.rand(3) * 50 + 1).cast("decimal(12,2)"))
                .withColumn("l_extendedprice", F.round(F.rand(4) * 100000, 2).cast("decimal(12,2)"))
                .withColumn("l_discount", F.round(F.rand(5) * 0.1, 2).cast("decimal(12,2)"))
                .withColumn("l_returnflag", F.element_at(F.array(F.lit("A"), F.lit("N"), F.lit("R")),
                                                         (F.col("l_id") % 3 + 1).cast("int")))
                .withColumn("l_linestatus", F.when(F.col("l_id") % 2 == 0, "O").otherwise("F"))
                .withColumn("l_shipdate", F.expr("date_add(date'1992-01-01', cast(rand(6) * 2500 as int))")))
    lineitem.write.mode("overwrite").parquet(f"{path}/lineitem")
    orders.write.mode("overwrite").parquet(f"{path}/orders")
    orders.write.mode("overwrite").orc(f"{path}/orders_orc")


def checksum(rows):
    # Order-sensitive (all queries have ORDER BY); floats rounded so tiny FP differences don't count.
    norm = [tuple(round(v, 4) if isinstance(v, float) else str(v) for v in r) for r in rows]
    return hashlib.md5(repr(norm).encode()).hexdigest()[:12]


def run(spark, path, label):
    for t in ["lineitem", "orders"]:
        spark.read.parquet(f"{path}/{t}").createOrReplaceTempView(t)
    spark.read.orc(f"{path}/orders_orc").createOrReplaceTempView("orders_orc")

    results = {}
    for name, sql in QUERIES.items():
        df = spark.sql(sql)
        t0 = time.time()
        rows = df.collect()
        secs = round(time.time() - t0, 2)
        plan = df._jdf.queryExecution().executedPlan().toString()
        # Gluten operators end in "Transformer"/"ExecTransformer"; vanilla ones don't.
        native_ops = plan.count("Transformer")
        results[name] = {"secs": secs, "rows": len(rows), "native_ops": native_ops,
                         "checksum": checksum(rows)}
        print(f"[{label}] {name}: {secs}s rows={len(rows)} native_ops={native_ops}", flush=True)
    print("RESULT " + json.dumps({"label": label, "results": results}), flush=True)


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    spark = SparkSession.builder.appName(f"poc-{sys.argv[3]}" if mode == "run" else "poc-gen").getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    if mode == "gen":
        gen(spark, path, int(sys.argv[3]))
    else:
        run(spark, path, sys.argv[3])
    spark.stop()
