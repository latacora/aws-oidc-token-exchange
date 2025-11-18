# Developer and Maintenance Guide

This document is for developers and maintainers of the AWS OIDC Token Exchange project.

## Project Overview

AWS OIDC Token Exchange is a Terraform-deployed infrastructure project that enables AWS workloads to obtain OIDC tokens for authentication with external services. It consists of:

- **Terraform Infrastructure** (`*.tf` files) - AWS resource definitions
- **Lambda Functions** (JavaScript in `oidc_conf_/index.js`) - Token generation and JWKS endpoints
- **Documentation** - User and security documentation

## Project Structure

```
aws-oidc-token-exchange/
├── main.tf              # Main Terraform configuration
├── variables.tf         # Terraform input variables
├── oidc_conf_/          # Lambda function code
│   └── index.js         # Token exchange, JWKS, discovery endpoints
├── docs/                # Documentation
│   └── images/          # Screenshots and diagrams
├── README.md            # User documentation
├── SECURITY.md          # Security documentation
├── CLAUDE.md            # This file (developer guide)
└── package.json         # Node.js dependencies (if any)
```

## Technology Stack

- **Infrastructure**: Terraform (AWS provider)
- **Runtime**: AWS Lambda (Node.js)
- **Authentication**: AWS IAM, AWS SigV4
- **Cryptography**: AWS KMS (RSA-2048 signing)
- **HTTP**: AWS API Gateway (REST API)
- **Storage**: CloudWatch Logs

## Development Setup

### Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- Node.js 18+ (for local testing)
- An AWS account with permissions to create:
  - KMS keys
  - Lambda functions
  - API Gateway APIs
  - IAM roles and policies
  - Route53 records (if using custom domain)

### Local Development

```bash
# Clone repository
git clone https://github.com/latacora/aws-oidc-token-exchange.git
cd aws-oidc-token-exchange

# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# Plan deployment
terraform plan \
  -var="name=test-oidc" \
  -var="domain=oidc.example.com" \
  -var="hosted_zone_id=Z1234567890ABC" \
  -var="principal_org_id=o-1234567890"

# Deploy to test environment
terraform apply -var-file=test.tfvars
```

## Architecture Deep Dive

### Token Exchange Flow

1. **Request Reception**
   - API Gateway receives GET request with AWS SigV4 signature
   - IAM Authorizer validates credentials
   - Identity information extracted from IAM context

2. **Lambda Invocation**
   - API Gateway invokes Lambda with identity context
   - Lambda receives event with `requestContext.identity` populated by API Gateway

3. **JWT Generation**
   - Header constructed with algorithm (RS256), type (JWT), and key ID
   - Payload constructed with OIDC standard claims and AWS-specific claims
   - Header and payload base64url encoded

4. **Signing**
   - Signing input: `base64url(header).base64url(payload)`
   - KMS `Sign` API called with RSA-SHA256 algorithm
   - Signature base64url encoded

5. **Response**
   - JWT returned: `header.payload.signature`
   - Response includes token type and expiration time

### JWKS Endpoint

1. **Public Key Retrieval**
   - KMS `GetPublicKey` API called
   - Returns DER-encoded RSA public key

2. **JWK Conversion**
   - DER format converted to JWK format
   - Includes key type, use, algorithm, key ID, modulus, exponent

3. **Response**
   - JWKS JSON returned with public cache headers
   - Allows OIDC consumers to cache the key

### Discovery Endpoint

1. **Metadata Generation**
   - Returns OIDC Discovery document
   - Includes issuer, JWKS URI, supported algorithms, claims

2. **Response**
   - JSON document at `/.well-known/openid-configuration`
   - Allows Relying Parties to auto-configure

## Infrastructure Components

### KMS Key

- **Type**: Asymmetric signing key
- **Algorithm**: RSA_2048
- **Usage**: SIGN_VERIFY
- **Key Policy**: Allows Lambda to sign, anyone to get public key
- **Rotation**: Manual (not supported for asymmetric keys)

### API Gateway

- **Type**: REST API
- **Authorization**: AWS_IAM for `/token`, NONE for public endpoints
- **Endpoints**:
  - `GET /token` - Token exchange (authenticated)
  - `GET /.well-known/openid-configuration` - Discovery (public)
  - `GET /.well-known/jwks.json` - JWKS (public)

### Lambda Function

- **Runtime**: Node.js 18.x
- **Handler**: Unified handler for all three endpoints
- **Memory**: Configurable (default recommended: 256 MB)
- **Timeout**: Configurable (default recommended: 30 seconds)
- **Environment Variables**:
  - `KMS_KEY_ID` - KMS key ARN
  - `ISSUER` - OIDC issuer URL
  - Other configuration as needed

### IAM Roles

**Lambda Execution Role:**
- CloudWatch Logs write permissions
- KMS Sign permission
- KMS GetPublicKey permission

**Workload Roles:**
- `execute-api:Invoke` permission for API Gateway
- Restricted by AWS Organization ID (optional)

## Terraform Configuration

### Required Variables

```terraform
variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "domain" {
  description = "Domain name for the OIDC issuer"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
}

variable "principal_org_id" {
  description = "AWS Organization ID for access control"
  type        = string
}
```

### Optional Variables

```terraform
variable "default_audience" {
  description = "Default audience claim if not specified"
  type        = string
  default     = ""
}
```

### Outputs

- `api_gateway_url` - Base URL of API Gateway
- `token_endpoint` - Full token exchange endpoint URL
- `jwks_endpoint` - Full JWKS endpoint URL
- `discovery_endpoint` - Full discovery endpoint URL
- `kms_key_id` - KMS key ID

## Development Workflow

### Making Changes

1. **Create Feature Branch**
   ```bash
   git checkout -b feature/my-feature
   ```

2. **Edit Terraform Configuration**
   - Modify `*.tf` files as needed
   - Update variables if adding configuration options
   - Add outputs for new resources

3. **Edit Lambda Code**
   - Modify `oidc_conf_/index.js`
   - Test locally if possible
   - Ensure error handling is comprehensive

4. **Validate Changes**
   ```bash
   terraform fmt      # Format code
   terraform validate # Validate syntax
   terraform plan     # Preview changes
   ```

5. **Test Deployment**
   ```bash
   # Deploy to test environment
   terraform apply -var-file=test.tfvars

   # Test token exchange
   curl -sS "https://test.example.com/token?audience=test" \
     --aws-sigv4 "aws:amz:us-east-2:execute-api" \
     --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
     --header "x-amz-security-token: ${AWS_SESSION_TOKEN}"

   # Test JWKS
   curl -sS "https://test.example.com/.well-known/jwks.json" | jq

   # Test discovery
   curl -sS "https://test.example.com/.well-known/openid-configuration" | jq
   ```

6. **Update Documentation**
   - Update README.md if user-facing changes
   - Update SECURITY.md if security implications
   - Update this file if internal changes

7. **Create Pull Request**
   - Push branch to GitHub
   - Create PR with clear description
   - Request review

### Code Conventions

#### Terraform

- Use consistent formatting: `terraform fmt`
- Use descriptive resource names
- Add comments for complex logic
- Use variables for all configurable values
- Use outputs for important resource attributes
- Use data sources for existing resources

#### JavaScript/Lambda

- Use modern JavaScript (ES6+)
- Use async/await for asynchronous operations
- Prefer const over let, never use var
- Add JSDoc comments for functions
- Use descriptive variable names
- Keep functions small and focused
- Always handle errors

#### Error Handling

**Terraform:**
- Use validation blocks for input variables
- Add precondition/postcondition checks where appropriate

**Lambda:**
- Always catch and log errors
- Return appropriate HTTP status codes
- Don't leak sensitive information in error messages
- Log sufficient context for debugging

#### Security

- Never log credentials or tokens
- Validate all inputs
- Use IAM policies with least privilege
- Follow AWS Well-Architected Framework
- Review [SECURITY.md](./SECURITY.md) before making changes

## Deployment

### Prerequisites

1. **AWS Account Setup**
   - AWS account with admin access (for initial setup)
   - AWS Organization configured (if using org-based access control)
   - Route53 hosted zone for domain

2. **Terraform State**
   - Configure remote state (S3 + DynamoDB recommended)
   - Enable state locking
   - Use workspaces for multiple environments

### Deployment Steps

1. **Configure Variables**
   ```bash
   # Create tfvars file
   cat > prod.tfvars <<EOF
   name             = "prod-oidc-token-exchange"
   domain           = "oidc.example.com"
   hosted_zone_id   = "Z1234567890ABC"
   principal_org_id = "o-1234567890"
   default_audience = "tailscale"
   EOF
   ```

2. **Initialize Terraform**
   ```bash
   terraform init -backend-config=prod-backend.tfvars
   ```

3. **Plan Deployment**
   ```bash
   terraform plan -var-file=prod.tfvars -out=tfplan
   ```

4. **Review Plan**
   - Verify resources to be created
   - Check IAM policies
   - Verify KMS key configuration
   - Check API Gateway settings

5. **Apply Deployment**
   ```bash
   terraform apply tfplan
   ```

6. **Verify Deployment**
   ```bash
   # Get outputs
   terraform output -json

   # Test endpoints
   curl -sS "$(terraform output -raw discovery_endpoint)" | jq
   curl -sS "$(terraform output -raw jwks_endpoint)" | jq
   ```

7. **Configure Monitoring**
   - Set up CloudWatch alarms (see SECURITY.md)
   - Configure CloudWatch Insights queries
   - Set up AWS Config rules
   - Enable GuardDuty if not already enabled

### Post-Deployment

1. **Document Configuration**
   - Save terraform outputs
   - Document issuer URL
   - Document access control policies
   - Share with team

2. **Test Integration**
   - Test token exchange from workload
   - Configure OIDC consumer (e.g., Tailscale)
   - Verify token verification works
   - Test complete authentication flow

3. **Enable Monitoring**
   - Verify CloudWatch Logs are working
   - Test CloudWatch alarms
   - Set up log retention policies

## Maintenance

### Regular Tasks

#### Weekly
- Review CloudWatch Logs for errors
- Check CloudWatch metrics for anomalies
- Monitor costs in AWS Cost Explorer

#### Monthly
- Review security audit logs
- Check for AWS service updates
- Review and update documentation

#### Quarterly
- Review and update IAM policies
- Test incident response procedures
- Review KMS key policies
- Update dependencies (if any)
- Conduct security review

#### Annually
- Rotate KMS keys (see below)
- Review and update disaster recovery procedures
- Conduct comprehensive security audit

### KMS Key Rotation

KMS doesn't support automatic rotation for asymmetric keys. Manual rotation process:

1. **Create New Key**
   ```bash
   # Update Terraform to create new key
   # Keep old key for transition period
   terraform apply
   ```

2. **Update Lambda**
   ```bash
   # Lambda automatically uses new key via Terraform
   # Old tokens still valid with old key
   ```

3. **Wait for Old Tokens to Expire**
   - Default token lifetime: varies by deployment
   - Wait at least 2x token lifetime for safety

4. **Verify New JWKS**
   ```bash
   # Check JWKS includes new key
   curl -sS "$(terraform output -raw jwks_endpoint)" | jq '.keys[].kid'
   ```

5. **Remove Old Key**
   ```bash
   # Remove old key from Terraform
   # Schedule deletion (7-30 day waiting period)
   terraform apply
   ```

### Updating Lambda Code

1. **Edit Code**
   ```bash
   # Edit oidc_conf_/index.js
   vim oidc_conf_/index.js
   ```

2. **Test Locally** (if possible)
   ```javascript
   // Create test event
   const event = {
     httpMethod: 'GET',
     path: '/token',
     queryStringParameters: { audience: 'test' },
     requestContext: {
       identity: {
         userArn: 'arn:aws:iam::123456789012:role/TestRole',
         accountId: '123456789012'
       }
     }
   };

   // Test handler
   const result = await handler(event);
   console.log(result);
   ```

3. **Deploy Update**
   ```bash
   # Terraform will detect code change
   terraform plan -var-file=prod.tfvars
   terraform apply -var-file=prod.tfvars
   ```

4. **Verify Update**
   ```bash
   # Test token exchange
   curl -sS "$(terraform output -raw token_endpoint)?audience=test" \
     --aws-sigv4 "aws:amz:us-east-2:execute-api" \
     --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
     --header "x-amz-security-token: ${AWS_SESSION_TOKEN}" | jq
   ```

### Troubleshooting

#### Token Exchange Fails

**Symptom**: 403 error from API Gateway

**Solutions**:
- Verify AWS credentials: `aws sts get-caller-identity`
- Check IAM policy allows `execute-api:Invoke`
- Verify AWS Organization ID matches configuration
- Check CloudWatch Logs for Lambda errors

**Symptom**: 500 error from Lambda

**Solutions**:
- Check CloudWatch Logs for Lambda function
- Verify KMS key policy allows Lambda to sign
- Check Lambda has correct environment variables
- Verify Lambda execution role has necessary permissions

#### JWKS Verification Fails

**Symptom**: Relying Party can't verify tokens

**Solutions**:
- Verify JWKS endpoint is accessible
- Check KMS key is active
- Verify `kid` in token matches JWKS
- Check token hasn't expired
- Verify signature algorithm matches (RS256)

#### High Costs

**Symptom**: Unexpected AWS bills

**Solutions**:
- Check KMS Sign API call volume
- Review API Gateway request volume
- Check Lambda invocation count
- Consider caching at client side
- Review CloudWatch Logs data ingestion

## Monitoring

### CloudWatch Metrics

**API Gateway:**
- `Count` - Total requests
- `4XXError` - Client errors
- `5XXError` - Server errors
- `Latency` - Response time

**Lambda:**
- `Invocations` - Total invocations
- `Errors` - Error count
- `Duration` - Execution time
- `Throttles` - Throttled invocations

**KMS:**
- `NumberOfOperations` - Total KMS operations
- `Duration` - KMS operation time

### CloudWatch Alarms

Create alarms for:

```bash
# High error rate
aws cloudwatch put-metric-alarm \
  --alarm-name oidc-high-errors \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --metric-name 4XXError \
  --namespace AWS/ApiGateway \
  --period 300 \
  --statistic Sum \
  --threshold 50 \
  --dimensions Name=ApiName,Value=your-api-name

# High latency
aws cloudwatch put-metric-alarm \
  --alarm-name oidc-high-latency \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --metric-name Latency \
  --namespace AWS/ApiGateway \
  --period 300 \
  --statistic Average \
  --threshold 1000
```

### CloudWatch Insights Queries

```cloudwatch
# Token generation by identity
fields @timestamp, @message
| filter @message like /Token generated/
| parse @message /identity: (?<identity>[^\s,]+)/
| stats count() by identity

# Error analysis
fields @timestamp, @message
| filter @type = "ERROR"
| stats count() by @message

# Performance metrics
fields @timestamp, @duration
| stats avg(@duration), max(@duration), pct(@duration, 99) by bin(5m)
```

## Testing

### Unit Tests

Currently, this project doesn't have unit tests. Recommendations for adding tests:

1. **Lambda Handler Tests**
   - Mock KMS client
   - Test JWT generation
   - Test error handling
   - Test claim extraction

2. **Terraform Tests**
   - Use `terraform plan` for syntax validation
   - Use Terratest for integration tests
   - Test with different variable combinations

### Integration Tests

Test complete flow:

```bash
#!/bin/bash
# test-integration.sh

set -e

# Deploy test stack
terraform apply -var-file=test.tfvars -auto-approve

# Get outputs
TOKEN_ENDPOINT=$(terraform output -raw token_endpoint)
JWKS_ENDPOINT=$(terraform output -raw jwks_endpoint)
DISCOVERY_ENDPOINT=$(terraform output -raw discovery_endpoint)

# Test discovery endpoint
echo "Testing discovery endpoint..."
curl -sS "$DISCOVERY_ENDPOINT" | jq -e '.issuer'

# Test JWKS endpoint
echo "Testing JWKS endpoint..."
curl -sS "$JWKS_ENDPOINT" | jq -e '.keys[0].kty == "RSA"'

# Test token exchange
echo "Testing token exchange..."
TOKEN=$(curl -sS "$TOKEN_ENDPOINT?audience=test" \
  --aws-sigv4 "aws:amz:us-east-2:execute-api" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  --header "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  --header "Accept: application/json")

# Verify token structure
echo "$TOKEN" | jq -e '.access_token'

# Decode token
echo "Token claims:"
echo "$TOKEN" | jq -r '.access_token' | cut -d'.' -f2 | base64 -d | jq

echo "All tests passed!"

# Cleanup
terraform destroy -var-file=test.tfvars -auto-approve
```

## Cost Optimization

### Current Costs

Typical monthly costs (for moderate usage):

- **KMS**: $1/month per key + $0.03 per 10,000 Sign operations
- **API Gateway**: $3.50 per million requests
- **Lambda**: $0.20 per million requests + compute time
- **CloudWatch Logs**: $0.50 per GB ingested
- **Route53**: $0.50 per hosted zone per month

**Estimated total**: $5-20/month for typical workload

### Optimization Strategies

1. **Reduce Token Requests**
   - Cache tokens on client side
   - Refresh proactively before expiration
   - Use longer token lifetime (balance with security)

2. **Optimize Lambda**
   - Right-size memory allocation
   - Minimize cold starts (use provisioned concurrency if needed)
   - Optimize code for performance

3. **Reduce Logging**
   - Lower log retention period
   - Filter logs to reduce volume
   - Use log sampling for high-volume paths

## Contributing

### Pull Request Process

1. Fork the repository
2. Create feature branch: `git checkout -b feature/my-feature`
3. Make changes
4. Update tests (when available)
5. Update documentation
6. Run `terraform fmt` and `terraform validate`
7. Commit with descriptive message
8. Push to fork: `git push origin feature/my-feature`
9. Create Pull Request

### Code Review Checklist

- [ ] Terraform code formatted (`terraform fmt`)
- [ ] Terraform validated (`terraform validate`)
- [ ] Documentation updated
- [ ] Security implications considered and documented
- [ ] Error handling appropriate
- [ ] Logging adequate for debugging
- [ ] No sensitive data in logs
- [ ] Cost impact considered
- [ ] Backwards compatibility maintained

## Support

For issues and questions:

1. Check [README.md](./README.md) for usage information
2. Review [SECURITY.md](./SECURITY.md) for security concerns
3. Search existing GitHub issues
4. Create new issue with:
   - Clear description
   - Steps to reproduce
   - Expected vs actual behavior
   - Terraform version
   - AWS region
   - Relevant logs (sanitized)

## License

See LICENSE file for details.
