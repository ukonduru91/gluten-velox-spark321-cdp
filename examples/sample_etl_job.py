"""A small, typical ETL job to try Gluten with: read Parquet -> filter -> join -> aggregate -> write.

Usage (same arguments for both runs, only the submit script changes):

  ./submit-vanilla.sh sample_etl_job.py <input_dir> <output_dir>
  ./submit-gluten.sh  sample_etl_job.py <input_dir> <output_dir>

<input_dir> needs Parquet data. If you don't have any, create test data first:

  ./submit-vanilla.sh sample_etl_job.py --generate <input_dir> 50000000
"""
import sys
import time

from pyspark.sql import SparkSession, functions as F


def generate(spark, path, rows):
    """Write a synthetic 'sales' fact table and a 'stores' dimension table as Parquet."""
    stores = spark.range(1000).select(
        F.col("id").alias("store_id"),
        F.concat(F.lit("region_"), (F.col("id") % 20).cast("string")).alias("region"))
    sales = spark.range(rows).select(
        F.col("id").alias("sale_id"),
        (F.col("id") % 1000).alias("store_id"),
        (F.rand(1) * 500).cast("decimal(12,2)").alias("amount"),
        (F.rand(2) * 10 + 1).cast("int").alias("qty"),
        F.expr("date_add(date'2023-01-01', cast(rand(3) * 730 as int))").alias("sale_date"))
    sales.write.mode("overwrite").parquet(f"{path}/sales")
    stores.write.mode("overwrite").parquet(f"{path}/stores")


def run(spark, src, dst):
    sales = spark.read.parquet(f"{src}/sales")
    stores = spark.read.parquet(f"{src}/stores")

    t0 = time.time()
    report = (sales
              .filter(F.col("sale_date") >= "2024-01-01")
              .join(stores, "store_id")
              .groupBy("region", F.date_trunc("month", "sale_date").alias("month"))
              .agg(F.sum(F.col("amount") * F.col("qty")).alias("revenue"),
                   F.countDistinct("store_id").alias("stores"),
                   F.count("*").alias("orders"))
              .orderBy("region", "month"))
    report.write.mode("overwrite").parquet(dst)
    print(f"JOB_TIME_SECONDS={time.time() - t0:.1f}", flush=True)

    # "Transformer" operators = running natively in Velox. 0 means Gluten is not active.
    # Read the final plan of the write from the SQL status store (with AQE on, the DataFrame's own
    # executedPlan only shows the plan from before execution, before Gluten's rules apply).
    execs = spark._jsparkSession.sharedState().statusStore().executionsList()
    plan = execs.apply(execs.size() - 1).physicalPlanDescription()
    print(f"GLUTEN_NATIVE_OPERATORS={plan.count('Transformer')}", flush=True)


if __name__ == "__main__":
    spark = SparkSession.builder.getOrCreate()
    if sys.argv[1] == "--generate":
        generate(spark, sys.argv[2], int(sys.argv[3]))
    else:
        run(spark, sys.argv[1], sys.argv[2])
    spark.stop()
