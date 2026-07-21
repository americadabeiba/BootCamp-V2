from io import StringIO
import pandas as pd
from sqlalchemy import text
from pg_types import infer_pg_type


def create_schema(engine, schema: str = "bronze") -> None:
    with engine.begin() as conn:
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema};"))

def drop_table(engine, schema: str, table: str) -> None:
    with engine.begin() as conn:
        conn.execute(
            text(
                f"""
                DROP TABLE IF EXISTS
                {schema}.{table}
                CASCADE;
                """
            )
        )

def create_table(engine, df: pd.DataFrame, schema: str, table: str) -> None:
    columns = []
    for column in df.columns:
        pg_type = infer_pg_type(df[column])
        columns.append(
            f'"{column}" {pg_type}'
        )
    ddl = f"""
        CREATE TABLE {schema}.{table}
        (
            {", ".join(columns)}
        );
    """
    with engine.begin() as conn:
        conn.execute(text(ddl))

def copy_dataframe(engine, df: pd.DataFrame, schema: str, table: str) -> None:
    csv_buffer = StringIO()
    df.to_csv(
        csv_buffer,
        index=False,
        header=False,
        na_rep="",
    )
    csv_buffer.seek(0)
    raw = engine.raw_connection()
    try:
        cursor = raw.cursor()
        cursor.copy_expert(
            sql=f"""
                COPY {schema}.{table}
                FROM STDIN
                WITH (
                    FORMAT CSV
                )
            """,
            file=csv_buffer,
        )
        raw.commit()
    finally:
        raw.close()

def count_rows(engine, schema: str, table: str) -> int:
    with engine.begin() as conn:
        result = conn.execute(
            text(
                f"""
                SELECT COUNT(*)
                FROM {schema}.{table}
                """
            )
        )
        return result.scalar_one()