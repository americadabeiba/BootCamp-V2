from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator

with DAG(
    dag_id="medallion_pipeline",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    max_active_runs=1,
    default_args={"retries": 1},
) as dag:

    ingest_bronze = BashOperator(
        task_id="ingest_bronze",
        bash_command="python3 /opt/airflow/src/ingest/load_raw_bronze.py",
    )

    build_silver = BashOperator(
        task_id="build_silver",
        bash_command="python3 /opt/airflow/src/transform/build_silver.py",
    )

    build_gold = BashOperator(
        task_id="build_gold",
        bash_command="python3 /opt/airflow/src/transform/build_gold.py",
    )

    export_parquet = BashOperator(
        task_id="export_parquet",
        bash_command="python3 /opt/airflow/src/transform/export_parquet.py",
    )

    validate_pipeline = BashOperator(
        task_id="validate_pipeline",
        bash_command="python3 /opt/airflow/src/validate/validate_pipeline.py",
    )

    ingest_bronze >> build_silver >> build_gold >> export_parquet >> validate_pipeline
