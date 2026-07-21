import pandas as pd
from pandas.api.types import (
    is_bool_dtype,
    is_datetime64_any_dtype,
    is_float_dtype,
    is_integer_dtype,
)


def infer_pg_type(series: pd.Series) -> str:
    if is_integer_dtype(series):
        return "BIGINT"
    if is_float_dtype(series):
        return "DOUBLE PRECISION"
    if is_bool_dtype(series):
        return "BOOLEAN"
    if is_datetime64_any_dtype(series):
        return "TIMESTAMP"
    return "TEXT"