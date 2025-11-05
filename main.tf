terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "this" {

}

data "aws_iam_policy_document" "resource_policy" {
  statement {
    sid       = "AllowBreakglassAdminAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.this.account_id}:root"]
    }
  }
  dynamic "statement" {
    for_each = toset(var.key_administrator_patterns)
    content {
      sid       = "AllowAdministration_${md5(statement.value)}"
      effect    = "Allow"
      actions   = ["kms:*"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = ["*"]
      }
      condition {
        test     = "ArnLike"
        values   = [statement.value]
        variable = "aws:PrincipalArn"
      }
    }
  }
  statement {
    sid       = "AllowOIDCServerLambdaToGetPublicKey"
    effect    = "Allow"
    actions   = ["kms:GetPublicKey", "kms:Sign"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.oidc_server.arn]
    }
  }
}


data "aws_iam_policy_document" "oidc_server_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["kms:GetPublicKey"]
    resources = [aws_kms_key.this.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_kms_key" "this" {
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "RSA_2048"
  tags                     = var.tags
}

resource "aws_kms_key_policy" "this" {
  key_id = aws_kms_key.this.key_id
  policy = data.aws_iam_policy_document.resource_policy.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_iam_role" "oidc_server" {
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "oidc_server" {
  policy = data.aws_iam_policy_document.oidc_server_permissions.json
  role   = aws_iam_role.oidc_server.id
}

data "archive_file" "oidc_server" {
  type        = "zip"
  output_path = "/tmp/terraform-lambda-${var.name}-oidc_server.zip"
  dynamic "source" {
    for_each = toset(fileset("${path.module}/oidc_server", "**"))
    content {
      content  = file("${path.module}/oidc_server/${source.value}")
      filename = source.value
    }
  }
}

resource "aws_lambda_function" "oidc_server" {
  function_name    = "${var.name}_oidc_server"
  role             = aws_iam_role.oidc_server.arn
  tags             = var.tags
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.oidc_server.output_path
  source_code_hash = data.archive_file.oidc_server.output_base64sha256
  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
    log_group             = aws_cloudwatch_log_group.oidc_server.name
  }
  environment {
    variables = {
      "KMS_KEY_ID"       = aws_kms_key.this.id
      "ISSUER_DOMAIN"    = var.domain
      "DEFAULT_AUDIENCE" = var.default_audience
    }
  }
}

# API Gateway REST API (v1)
resource "aws_api_gateway_rest_api" "this" {
  name = var.name
  tags = var.tags

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /token resource (IAM auth)
resource "aws_api_gateway_resource" "token" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "token"
}

resource "aws_api_gateway_method" "token" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.token.id
  http_method   = "GET"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "token" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.token.id
  http_method             = aws_api_gateway_method.token.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.oidc_server.invoke_arn
}

# /.well-known resource (public)
resource "aws_api_gateway_resource" "well_known" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = ".well-known"
}

resource "aws_api_gateway_resource" "openid_configuration" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.well_known.id
  path_part   = "openid-configuration"
}

resource "aws_api_gateway_method" "openid_configuration" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.openid_configuration.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "openid_configuration" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.openid_configuration.id
  http_method             = aws_api_gateway_method.openid_configuration.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.oidc_server.invoke_arn
}

resource "aws_api_gateway_resource" "keys" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.well_known.id
  path_part   = "jwks.json"
}

resource "aws_api_gateway_method" "keys" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.keys.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "keys" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.keys.id
  http_method             = aws_api_gateway_method.keys.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.oidc_server.invoke_arn
}

# Deployment
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.token.id,
      aws_api_gateway_method.token.id,
      aws_api_gateway_integration.token.id,
      aws_api_gateway_resource.well_known.id,
      aws_api_gateway_resource.openid_configuration.id,
      aws_api_gateway_method.openid_configuration.id,
      aws_api_gateway_integration.openid_configuration.id,
      aws_api_gateway_resource.keys.id,
      aws_api_gateway_method.keys.id,
      aws_api_gateway_integration.keys.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = "prod"
  tags          = var.tags

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

# API Gateway Resource Policy for cross-account access
data "aws_iam_policy_document" "api_gateway_resource_policy" {
  # Allow cross-account IAM access for specified accounts
  statement {
    sid    = "AllowCrossAccountIAMAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.this.execution_arn}/*/GET/token"]
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgId"
      values   = [var.principal_org_id]
    }
  }

  # Allow public access to OIDC discovery endpoints
  statement {
    sid    = "AllowPublicOIDCDiscovery"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = ["execute-api:Invoke"]
    resources = [
      "${aws_api_gateway_rest_api.this.execution_arn}/*/GET/.well-known/openid-configuration",
      "${aws_api_gateway_rest_api.this.execution_arn}/*/GET/.well-known/jwks.json"
    ]
  }
}

resource "aws_api_gateway_rest_api_policy" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  policy      = data.aws_iam_policy_document.api_gateway_resource_policy.json
}

# ACM Certificate for custom domain
resource "aws_acm_certificate" "this" {
  domain_name       = var.domain
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.hosted_zone_id
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_api_gateway_domain_name" "this" {
  domain_name              = var.domain
  regional_certificate_arn = aws_acm_certificate_validation.this.certificate_arn
  tags                     = var.tags

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

# Route53 record for custom domain
resource "aws_route53_record" "api_gateway" {
  zone_id = var.hosted_zone_id
  name    = aws_api_gateway_domain_name.this.domain_name
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.this.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this.regional_zone_id
    evaluate_target_health = false
  }
}

resource "aws_lambda_permission" "oidc_server_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.oidc_server.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_cloudwatch_log_group" "oidc_server" {
  name              = "/aws/lambda/${var.name}_oidc_server"
  retention_in_days = var.log_retention
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.log_retention
  tags              = var.tags
}




output "endpoints" {
  value = {
    issuer_url   = "https://${aws_api_gateway_domain_name.this.domain_name}"
    token_url    = "https://${aws_api_gateway_domain_name.this.domain_name}/token"
    jwks_url     = "https://${aws_api_gateway_domain_name.this.domain_name}/.well-known/jwks.json"
    metadata_url = "https://${aws_api_gateway_domain_name.this.domain_name}/.well-known/openid-configuration"
  }
}
