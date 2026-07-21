import os
from sqlalchemy import create_engine


def get_engine():
    user = os.environ.get("WAREHOUSE_DB_USER", "postgres")
    password = os.environ.get("WAREHOUSE_DB_PASSWORD", "postgres")
    database = os.environ.get("WAREHOUSE_DB_NAME", "warehouse")
    host = os.environ.get("WAREHOUSE_DB_HOST", "warehouse-db")
    port = os.environ.get("WAREHOUSE_DB_PORT", "5432")
    url = (
        f"postgresql+psycopg2://"
        f"{user}:{password}@{host}:{port}/{database}"
    )
    return create_engine(url, future=True)