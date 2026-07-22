import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src" / "ingest"))
SQL_DIR = PROJECT_ROOT / "sql" / "silver"
SQL_FILES = [
    "silver_university.sql",
    "silver_billing.sql",
    "silver_crm.sql",
]

from db import get_engine

def run_sql_file(cursor, sql_file: Path) -> None:
    print("=" * 70)
    print(f"Ejecutando: {sql_file.name}")
    cursor.execute(sql_file.read_text())

def table_counts(cursor, schema: str) -> dict:
    cursor.execute(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = %s
        ORDER BY table_name;
        """,
        (schema,),
    )
    tables = [row[0] for row in cursor.fetchall()]
    counts = {}
    for table in tables:
        cursor.execute(f"SELECT COUNT(*) FROM {schema}.{table};")
        counts[table] = cursor.fetchone()[0]
    return counts

def build_silver() -> None:
    print("\n")
    print("=" * 70)
    print("SILVER BUILD")
    print("=" * 70)

    engine = get_engine()
    raw = engine.raw_connection()
    try:
        cursor = raw.cursor()

        for filename in SQL_FILES:
            run_sql_file(cursor, SQL_DIR / filename)

        raw.commit()

        print("\n")
        print("=" * 70)
        print("Conteo de filas por tabla silver:")
        print("=" * 70)
        for table, count in table_counts(cursor, "silver").items():
            print(f"  silver.{table:<30} {count:>8,}")
    except Exception:
        raw.rollback()
        raise
    finally:
        raw.close()

    print("\n")
    print("=" * 70)
    print("Construcción Silver finalizada correctamente.")
    print("=" * 70)


if __name__ == "__main__":
    build_silver()
