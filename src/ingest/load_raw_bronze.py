from pathlib import Path
import pandas as pd
from db import get_engine
from postgres import (
    copy_dataframe,
    count_rows,
    create_schema,
    create_table,
    drop_table,
)


SCHEMA = "bronze"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw"


def discover_csv_files():
    return sorted(RAW_DATA_DIR.glob("*/*.csv"))

def table_name(csv_file: Path) -> str:
    domain = csv_file.parent.name
    table = csv_file.stem
    return f"{domain}_{table}"

def load_dataframe(csv_file: Path) -> pd.DataFrame:
    return pd.read_csv(
        csv_file,
        low_memory=False,
    )

def add_ingestion_metadata(df: pd.DataFrame, csv_file: Path, ingested_at: pd.Timestamp) -> pd.DataFrame:
    df["_source_domain"] = csv_file.parent.name
    df["_source_file"] = csv_file.name
    df["_ingested_at"] = ingested_at
    return df

def load_table(engine, csv_file: Path, ingested_at: pd.Timestamp):
    table = table_name(csv_file)
    print("=" * 70)
    print(f"Cargando: {csv_file.name}")
    print(f"Destino : {SCHEMA}.{table}")

    df = load_dataframe(csv_file)
    df = add_ingestion_metadata(df, csv_file, ingested_at)
    print(f"Filas    : {len(df):,}")
    print(f"Columnas : {len(df.columns)}")

    drop_table(
        engine,
        SCHEMA,
        table,
    )

    create_table(
        engine,
        df,
        SCHEMA,
        table,
    )

    copy_dataframe(
        engine,
        df,
        SCHEMA,
        table,
    )

    rows = count_rows(
        engine,
        SCHEMA,
        table,
    )

    print(f"Insertadas: {rows:,}")

def load_raw_bronze():
    print("\n")
    print("=" * 70)
    print("BRONZE INGESTION")
    print("=" * 70)

    if not RAW_DATA_DIR.exists():
        raise FileNotFoundError(
            f"No existe el directorio:\n{RAW_DATA_DIR}"
        )
    engine = get_engine()
    create_schema(
        engine,
        SCHEMA,
    )

    csv_files = discover_csv_files()

    if not csv_files:
        raise RuntimeError(
            f"No se encontraron CSV en:\n{RAW_DATA_DIR}"
        )
    print(f"\nCSV encontrados: {len(csv_files)}\n")

    ingested_at = pd.Timestamp.now(tz="UTC").tz_localize(None)
    print(f"Fecha de ingesta: {ingested_at.isoformat()}\n")

    for csv_file in csv_files:
        load_table(
            engine,
            csv_file,
            ingested_at,
        )
    print("\n")
    print("=" * 70)
    print("Carga Bronze finalizada correctamente.")
    print("=" * 70)

if __name__ == "__main__":
    load_raw_bronze()