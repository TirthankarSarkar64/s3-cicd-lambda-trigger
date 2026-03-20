"""Lambda entry point for S3-triggered CSV ingestion.

This function expects an S3 ObjectCreated event, downloads the uploaded
CSV file, reads it with pandas, and logs a compact summary that is easy
to inspect in CloudWatch Logs.
"""

import io
import json
import logging
import os
from typing import Any
from urllib.parse import unquote_plus

import boto3
import pandas as pd


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

# Reuse the S3 client across invocations to avoid recreating it on every call.
s3_client = boto3.client("s3")
# This controls how many rows from the CSV are included in the log preview.
MAX_PREVIEW_ROWS = int(os.getenv("MAX_PREVIEW_ROWS", "5"))


def _parse_csv_body(body: str) -> dict[str, Any]:
    """Parse raw CSV text and return a small summary for logging."""
    dataframe = pd.read_csv(io.StringIO(body))

    return {
        "column_names": dataframe.columns.tolist(),
        "row_count": int(len(dataframe.index)),
        "preview_rows": dataframe.head(MAX_PREVIEW_ROWS).fillna("").to_dict(orient="records"),
    }


def _process_record(record: dict[str, Any]) -> dict[str, Any]:
    """Handle one S3 event record and extract metadata from the CSV object."""
    bucket_name = record["s3"]["bucket"]["name"]
    object_key = unquote_plus(record["s3"]["object"]["key"])

    LOGGER.info("Reading s3://%s/%s", bucket_name, object_key)

    response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
    body = response["Body"].read().decode("utf-8")
    csv_summary = _parse_csv_body(body)

    result = {
        "bucket": bucket_name,
        "key": object_key,
        "file_size_bytes": record["s3"]["object"].get("size"),
        "column_names": csv_summary["column_names"],
        "row_count": csv_summary["row_count"],
        "preview_rows": csv_summary["preview_rows"],
    }

    LOGGER.info("Processed CSV summary: %s", json.dumps(result))
    return result

def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """AWS Lambda handler invoked by S3 object creation events."""
    LOGGER.info("Received event: %s", json.dumps(event))

    results = [_process_record(record) for record in event.get("Records", [])]

    return {
        "statusCode": 200,
        "processed_files": len(results),
        "results": results,
    }
