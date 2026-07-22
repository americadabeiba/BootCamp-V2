import sys
from pathlib import Path

import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src" / "ingest"))

from db import get_engine  # noqa: E402

PARQUET_DIR = PROJECT_ROOT / "data" / "parquet"
SCHEMAS = ["bronze", "silver", "gold"]


def list_tables(engine, schema: str) -> list[str]:
    query = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = %(schema)s
        ORDER BY table_name;
    """
    return pd.read_sql(query, engine, params={"schema": schema})["table_name"].tolist()


def export_table(engine, schema: str, table: str) -> int:
    df = pd.read_sql(f"SELECT * FROM {schema}.{table};", engine)
    out_dir = PARQUET_DIR / schema
    out_dir.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out_dir / f"{table}.parquet", engine="pyarrow", index=False)
    return len(df)


def export_parquet() -> None:
    print("\n")
    print("=" * 70)
    print("PARQUET EXPORT")
    print("=" * 70)

    engine = get_engine()

    for schema in SCHEMAS:
        tables = list_tables(engine, schema)
        print(f"\nEsquema {schema}: {len(tables)} tablas")
        for table in tables:
            rows = export_table(engine, schema, table)
            print(f"  {schema}.{table:<35} {rows:>8,} filas")

    print("\n")
    print("=" * 70)
    print("Exportacion a Parquet finalizada correctamente.")
    print("=" * 70)


if __name__ == "__main__":
    export_parquet()
