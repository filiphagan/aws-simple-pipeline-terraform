// Infrastructure definition
// =========================
// 1) S3 + Lambda + DynamoDB
// -------------------------
// 2) API Gateway + DynamoDB
// =========================

provider "aws" {
  region = var.region
  access_key = var.access_key
  secret_key = var.secret_key
}

// Account ID
data "aws_caller_identity" "current" {}

locals {
    account_id = data.aws_caller_identity.current.account_id
}

output "account_id" {
  value = local.account_id
}

// S3
resource "aws_s3_bucket" "my_bucket" {
  bucket = var.s3_name
  acl = "private"
  force_destroy = true
}

// DynamoDB
resource "aws_dynamodb_table" "my_db" {
  hash_key = var.db_key
  name = var.db_name
  billing_mode = "PAY_PER_REQUEST"
  attribute {
    name = var.db_key
    type = "S"
  }
}

// Lambda
data "archive_file" "lambda_zip" {
  type = "zip"
  source_dir = "src"
  output_path = "lambda_function.zip"
}

data "aws_iam_policy_document" "policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["lambda.amazonaws.com"]
      type        = "Service"
    }
    principals {
      identifiers = ["apigateway.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "iam_role_lambda"
  assume_role_policy = data.aws_iam_policy_document.policy.json
}

// TODO: IAM policy as tf data block https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
resource "aws_iam_policy" "lambda_policy" {
  name   = "iam_policy_lambda"
  policy = file("${path.module}/iam_policy_lambda.json")
}

resource "aws_iam_role_policy_attachment" "lambda_role_policy" {
  policy_arn = aws_iam_policy.lambda_policy.arn
  role = aws_iam_role.lambda_role.name
}

resource "aws_lambda_function" "ingestion_lambda" {
  filename = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name = "ingestion-lambda"
  role = aws_iam_role.lambda_role.arn
  handler = "${var.handler_file}.${var.handler_name}"
  runtime = var.lambda_runtime
  timeout = 900
  environment {
    variables = {
      DB_NAME = aws_dynamodb_table.my_db.name
    }
  }
}

// S3 Lambda trigger
resource "aws_s3_bucket_notification" "bucket_trigger" {
  bucket = aws_s3_bucket.my_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion_lambda.arn
    events = ["s3:ObjectCreated:Put"]
    filter_suffix = ".json"
  }
}

resource "aws_lambda_permission" "lambda_permission" {
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion_lambda.function_name
  principal = "s3.amazonaws.com"
  source_arn = "arn:aws:s3:::${aws_s3_bucket.my_bucket.id}"
}

// API Gateway
resource "aws_iam_role" "api_role" {
  name               = "iam_role_api"
  assume_role_policy = data.aws_iam_policy_document.policy.json
}

// TODO: IAM policy as tf data block
resource "aws_iam_policy" "api_policy" {
  name   = "iam_policy_api"
  policy = file("${path.module}/iam_policy_api.json")
}

resource "aws_iam_role_policy_attachment" "api_role_policy" {
  policy_arn = aws_iam_policy.api_policy.arn
  role = aws_iam_role.api_role.name
}

resource "aws_api_gateway_rest_api" "my_api" {
  name = var.api_name
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "my_api_resource" {
  parent_id   = aws_api_gateway_rest_api.my_api.root_resource_id
  path_part   = "get-data"
  rest_api_id = aws_api_gateway_rest_api.my_api.id
}

resource "aws_api_gateway_method" "my_api_method" {
  authorization = "NONE"
  http_method   = "GET"
  resource_id   = aws_api_gateway_resource.my_api_resource.id
  rest_api_id   = aws_api_gateway_rest_api.my_api.id
}

resource "aws_api_gateway_integration" "my_api_integration" {
  integration_http_method = "POST"
  http_method             = aws_api_gateway_method.my_api_method.http_method
  resource_id             = aws_api_gateway_resource.my_api_resource.id
  rest_api_id             = aws_api_gateway_rest_api.my_api.id
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:eu-central-1:dynamodb:action/Scan"
  credentials             = aws_iam_role.api_role.arn
  request_templates = {
    "application/json" = file("${path.module}/mapping_template.json")
  }
}

resource "aws_api_gateway_method_response" "my_api_method_resp" {
  rest_api_id = aws_api_gateway_rest_api.my_api.id
  resource_id = aws_api_gateway_resource.my_api_resource.id
  http_method = aws_api_gateway_method.my_api_method.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "my_api_integration_resp" {
  rest_api_id = aws_api_gateway_rest_api.my_api.id
  resource_id = aws_api_gateway_resource.my_api_resource.id
  http_method = aws_api_gateway_method.my_api_method.http_method
  status_code = aws_api_gateway_method_response.my_api_method_resp.status_code
  depends_on = [aws_api_gateway_integration.my_api_integration]
}

resource "aws_api_gateway_deployment" "my_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.my_api.id
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.my_api_resource.id,
      aws_api_gateway_method.my_api_method.id,
      aws_api_gateway_integration.my_api_integration.id,
      aws_api_gateway_method_response.my_api_method_resp.id,
      aws_api_gateway_integration_response.my_api_integration_resp.id,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "my_api_stage" {
  deployment_id = aws_api_gateway_deployment.my_api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.my_api.id
  stage_name    = var.api_stage
}

output "api_invoke_url" {
  value = "${aws_api_gateway_deployment.my_api_deployment.invoke_url}${var.api_stage}/${aws_api_gateway_resource.my_api_resource.path_part}"
}
