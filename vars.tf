# Main variables
variable "region" {
  type = string
}
variable "access_key" {
  type = string
}
variable "secret_key" {
  type = string
}

# S3 parameters
variable "s3_name" {
  type = string
}

# DynamoDB parameters
variable "db_name" {
  type = string
}
variable "db_key" {
  type = string
}

# Lambda parameters
variable "handler_file" {
  description = "File name with lambda code without the file extension"
  default = "lambda_function"
  type = string
}
variable "handler_name" {
  description = "Handler function name"
  default = "lambda_handler"
  type = string
}
variable "lambda_runtime" {
  default = "python3.8"
  type = string
}

# API Gateway parameters
variable "api_name" {
  type = string
}
variable "api_stage" {
  type = string
}

