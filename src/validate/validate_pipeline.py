import sys
from pathlib import Path

import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src" / "ingest"))

from db import get_engine  # noqa: E402

RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw"
PARQUET_DIR = PROJECT_ROOT / "data" / "parquet"

SILVER_TO_GOLD = {
    "university_semesters": "dim_semestre",
    "university_courses": "dim_curso",
    "university_students": "dim_estudiante",
    "university_enrollments": "fact_inscripciones",
    "university_grades": "fact_notas",
    "billing_customers": "dim_cliente",
    "billing_products": "dim_producto",
    "billing_subscriptions": "fact_suscripciones",
    "billing_invoices": "fact_facturas",
    "billing_payments": "fact_pagos",
    "crm_accounts": "dim_cuenta",
    "crm_contacts": "dim_contacto",
    "crm_opportunities": "fact_oportunidades",
    "crm_activities": "fact_actividades",
    "crm_leads": "mart_leads",
}

SILVER_SIN_EQUIVALENTE_GOLD = {
    "university_professors",
    "billing_invoice_items",
    "crm_opportunity_contacts",
}


def table_count(engine, schema: str, table: str) -> int:
    return int(pd.read_sql(f"SELECT COUNT(*) AS n FROM {schema}.{table};", engine)["n"].iloc[0])


def list_tables(engine, schema: str) -> list[str]:
    query = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = %(schema)s
        ORDER BY table_name;
    """
    return pd.read_sql(query, engine, params={"schema": schema})["table_name"].tolist()


def check(results: list, name: str, passed: bool, detail: str) -> None:
    results.append({"check": name, "passed": passed, "detail": detail})


def validar_csv_vs_bronze(engine, results: list) -> None:
    for csv_file in sorted(RAW_DATA_DIR.glob("*/*.csv")):
        domain = csv_file.parent.name
        table = f"{domain}_{csv_file.stem}"
        csv_rows = len(pd.read_csv(csv_file, low_memory=False))
        bronze_rows = table_count(engine, "bronze", table)
        check(
            results,
            f"csv->bronze {table}",
            csv_rows == bronze_rows,
            f"csv={csv_rows:,} bronze={bronze_rows:,}",
        )


def validar_bronze_vs_silver(engine, results: list) -> None:
    bronze_tables = list_tables(engine, "bronze")
    for table in bronze_tables:
        bronze_rows = table_count(engine, "bronze", table)
        silver_rows = table_count(engine, "silver", table)
        if table == "university_grades":
            expected = int(
                pd.read_sql(
                    "SELECT COUNT(*) AS n FROM (SELECT DISTINCT enrollment_id, assessment FROM bronze.university_grades) t;",
                    engine,
                )["n"].iloc[0]
            )
            check(
                results,
                f"bronze->silver {table} (deduplicado)",
                silver_rows == expected,
                f"bronze={bronze_rows:,} silver={silver_rows:,} esperado={expected:,}",
            )
        else:
            check(
                results,
                f"bronze->silver {table}",
                silver_rows == bronze_rows,
                f"bronze={bronze_rows:,} silver={silver_rows:,}",
            )


def validar_silver_vs_gold(engine, results: list) -> None:
    silver_tables = list_tables(engine, "silver")
    for table in silver_tables:
        if table in SILVER_SIN_EQUIVALENTE_GOLD:
            check(results, f"silver->gold {table}", True, "fuera de alcance por diseno, ver decisiones.md SS5.6")
            continue
        gold_table = SILVER_TO_GOLD[table]
        silver_rows = table_count(engine, "silver", table)
        gold_rows = table_count(engine, "gold", gold_table)
        check(
            results,
            f"silver->gold {table} -> {gold_table}",
            silver_rows == gold_rows,
            f"silver={silver_rows:,} gold={gold_rows:,}",
        )


def validar_postgres_vs_parquet(engine, results: list) -> None:
    for schema in ["bronze", "silver", "gold"]:
        for table in list_tables(engine, schema):
            parquet_file = PARQUET_DIR / schema / f"{table}.parquet"
            if not parquet_file.exists():
                check(results, f"parquet {schema}.{table}", False, "archivo parquet no encontrado")
                continue
            db_rows = table_count(engine, schema, table)
            parquet_rows = len(pd.read_parquet(parquet_file))
            check(
                results,
                f"parquet {schema}.{table}",
                db_rows == parquet_rows,
                f"postgres={db_rows:,} parquet={parquet_rows:,}",
            )


def validate_pipeline() -> None:
    print("\n")
    print("=" * 70)
    print("VALIDACION DEL PIPELINE")
    print("=" * 70)

    engine = get_engine()
    results: list = []

    validar_csv_vs_bronze(engine, results)
    validar_bronze_vs_silver(engine, results)
    validar_silver_vs_gold(engine, results)
    validar_postgres_vs_parquet(engine, results)

    fallidos = [r for r in results if not r["passed"]]

    for r in results:
        estado = "OK" if r["passed"] else "FAIL"
        print(f"  [{estado}] {r['check']:<45} {r['detail']}")

    print("\n")
    print("=" * 70)
    print(f"Total: {len(results)}  OK: {len(results) - len(fallidos)}  FAIL: {len(fallidos)}")
    print("=" * 70)

    if fallidos:
        print("\nValidacion del pipeline FALLIDA.")
        sys.exit(1)

    print("\nValidacion del pipeline exitosa.")


if __name__ == "__main__":
    validate_pipeline()
