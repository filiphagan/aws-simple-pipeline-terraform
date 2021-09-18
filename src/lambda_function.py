__author__ = "Filip Hagan"

import os
import json
import re
import boto3


def get_parse_s3_file(bucket: str, key: str) -> dict:
    """Returns dictionary with parsed JSON given S3 bucket name and file name (key)"""
    s3 = boto3.client('s3')

    try:
        payload = s3.get_object(Bucket=bucket, Key=key)['Body'].read().decode('utf-8')
    except Exception as e:
        print(f"Loading object failed. Object:{key} Bucket: s3://{bucket}")
        raise e

    try:
        parsed_json = json.loads(payload)
    except (json.decoder.JSONDecodeError, TypeError) as e:
        print(f"Unable to parse file contents to JSON. Verify formatting.")
        raise e

    if isinstance(parsed_json, dict):
        return parsed_json
    else:
        raise TypeError(f"Invalid type. Expecting dict, getting {type(parsed_json)}")


def verify_json(data: dict) -> dict:
    """Verifies the integrity of given JSON and provides additional preprocessing.
    Returns preprocessed message if successfully verified."""

    if len(data.keys()) == 0:
        raise Exception("File empty.")

    # Strip whitespace and lowercase all keys & values
    data = dict((k.lower().strip(), v.lower().strip()) for k, v in data.items())

    if 'email' not in data:
        raise Exception("Email not found.")

    # Raise exception if data contains keys other than 'email', 'first_name', 'last_name'
    forbidden_keys = set(data.keys()).difference({'email', 'first_name', 'last_name'})
    if len(forbidden_keys) > 0:
        raise Exception(f"Input data contains forbidden keys: {forbidden_keys}")

    # RFC 5322 compliant email address matching regex. Credit: https://regex101.com/library/6EL6YF
    pattern = (
        r"(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|\"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x2"
        r"1\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*\")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z"
        r"0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|"
        r"[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b"
        r"\x0c\x0e -\x7f])+)\])"
    )
    not_valid = True
    match = re.findall(pattern, data['email'])
    if match:  # is not empty
        match = match[0]
        if data['email'] == match:
            not_valid = False
            print("Email format is valid.")
    if not_valid:
        raise Exception("Provided email is not valid.")

    # TODO: All edge cases for first and last names
    return data


def ingest(data: dict, table_name: str) -> dict:
    """Processes the input data and saves records into DynamoDB table.
    Returns response with preprocessed data if stored successfully."""

    data = verify_json(data)
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table(table_name)

    # Creates a new item, or replaces an old item with a new item
    db_response = table.put_item(Item=data)
    if db_response['ResponseMetadata']['HTTPStatusCode'] == 200:
        print("Input data was successfully stored in the DB.")
        return data
    else:
        raise Exception(f"Bad status code from DynamoDB: {db_response['ResponseMetadata']['HTTPStatusCode']}")


def lambda_handler(event: dict, context: dict) -> None:
    """Main wrapper. This lambda is triggered by the S3 bucket (PUT).

    Expecting JSON files with certain keys:
        'email' - mandatory
        'first_name' - optional
        'last_name' - optional

    Other keys are not allowed. The data is validated and stored in DynamoDB.
    """

    output_table = os.environ['DB_NAME']
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']

    try:
        # Input JSON parsed into dictionary
        input_data = get_parse_s3_file(bucket, key)
    except Exception as e:
        print(e)
        print(f"Exception during S3 object parsing. Request not processed for the file: {key}")
        return

    try:
        # Integration and ingestion to DynamoDB table
        data_sent_to_db = ingest(input_data, output_table)
    except Exception as e:
        print(e)
        print(f"Exception during data ingestion. Request not processed for the file: {key}")
        return
    else:
        print(f"Request processed successfully for the file: {key} DynamoDB key: {data_sent_to_db['email']}")
        return
