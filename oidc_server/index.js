import {createPublicKey} from "crypto";
import {KMSClient, GetPublicKeyCommand, SignCommand} from "@aws-sdk/client-kms";

const region = process.env["AWS_REGION"];
const ISSUER_URL = `https://${process.env["ISSUER_DOMAIN"]}`;
const TOKEN_PATH = "/token";
const JWKS_PATH = "/.well-known/jwks.json";
const METADATA_PATH = "/.well-known/openid-configuration";
const KMS_KEY_ID = process.env["KMS_KEY_ID"];
const DEFAULT_AUDIENCE = process.env["DEFAULT_AUDIENCE"];
const TOKEN_DURATION_SECONDS = parseInt(process.env["TOKEN_DURATION_SECONDS"] || "3600");

const client = new KMSClient({region: region});

const getJwkForKmsKey = async (keyId) => {
    const command = new GetPublicKeyCommand({KeyId: keyId});
    const response = await client.send(command);
    const keyBase64 = Buffer.from(response.PublicKey).toString('base64');
    const pemKey = `-----BEGIN PUBLIC KEY-----\n${keyBase64}\n-----END PUBLIC KEY-----\n`;
    const jwk = createPublicKey(pemKey).export({type: "pkcs1", format: "jwk"});
    jwk.kid = response.KeyId.replace(/.+\//, "");
    jwk.use = "sig"
    jwk.alg = "RS256"
    return jwk;
}

const getMetadata = () => {
    const discoveryDoc = {
        issuer: ISSUER_URL,
        jwks_uri: ISSUER_URL + JWKS_PATH,
        token_endpoint: ISSUER_URL + TOKEN_PATH,
        authorization_endpoint: ISSUER_URL + "/404",
        response_types_supported: ['id_token'],
        subject_types_supported: ['public'],
        id_token_signing_alg_values_supported: ['RS256'],
        claims_supported: [
            'iss',
            'sub',
            'aud',
            'iat',
            'exp',
            'aws:account',
            'aws:arn',
            'aws:arn:partition',
            'aws:arn:service',
            'aws:arn:region',
            'aws:arn:account',
            'aws:arn:resource_type',
            'aws:arn:resource_name',
            'aws:arn:role_name',
            'aws:arn:session_name',
            'aws:user_id',
            'aws:caller_id',
            'aws:access_key',
            'aws:principal_org_id',
            'aws:source_ip',
            'aws:user_agent'
        ],
    }
    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'public, max-age=3600',
            'Access-Control-Allow-Origin': '*'
        },
        body: JSON.stringify(discoveryDoc)
    };
}

const jwks = async () => {
    const keyIds = [KMS_KEY_ID];
    const kmsKeys = await Promise.all(keyIds.map(getJwkForKmsKey))
    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'public, max-age=3600',
            'Access-Control-Allow-Origin': '*'
        },
        body: JSON.stringify({keys: kmsKeys})
    };
}

const base64url = (buffer) => {
    return Buffer.from(buffer).toString('base64url');
}

const signWithKMS = async (data) => {
    const command = new SignCommand({
        KeyId: KMS_KEY_ID,
        Message: data,
        MessageType: 'RAW',
        SigningAlgorithm: 'RSASSA_PKCS1_V1_5_SHA_256'
    });

    const response = await client.send(command);
    return response.Signature;
}

const parseArn = (arn) => {
    if (!arn) return {};

    const arnParts = arn.split(':');
    if (arnParts.length < 6) return {};

    const [, partition, service, region, account, ...resourceParts] = arnParts;
    const resource = resourceParts.join(':');

    // Parse resource into type and name
    // Resource can be in formats like:
    // - "assumed-role/RoleName/SessionName"
    // - "user/UserName"
    // - "role/RoleName"
    let resourceType = '';
    let resourceName = '';
    let roleName;
    let sessionName;

    const resourceMatch = resource.match(/^([^/]+)\/(.+)$/);
    if (resourceMatch) {
        resourceType = resourceMatch[1];
        resourceName = resourceMatch[2];

        // For assumed-role, parse RoleName/SessionName
        if (resourceType === 'assumed-role') {
            const roleSessionMatch = resourceName.match(/^([^/]+)\/(.+)$/);
            if (roleSessionMatch) {
                roleName = roleSessionMatch[1];
                sessionName = roleSessionMatch[2];
            }
        }
    } else {
        resourceType = resource;
    }

    return {
        partition,
        service,
        region: region || undefined,
        account,
        resourceType,
        resourceName: resourceName || undefined,
        roleName,
        sessionName
    };
};

const validateIdentity = (identity) => {
    if (!identity) {
        throw new Error("Missing identity information");
    }

    const requiredFields = ['userArn', 'accountId'];
    const missingFields = requiredFields.filter(field => !identity[field]);

    if (missingFields.length > 0) {
        throw new Error(`Missing required identity fields: ${missingFields.join(', ')}`);
    }
};

const getClaimsFromRequest = (event) => {
    // Validate request structure
    if (!event?.requestContext?.identity) {
        throw new Error("Missing request context or identity");
    }

    const identity = event.requestContext.identity;
    validateIdentity(identity);

    const now = Math.floor(Date.now() / 1000);
    const audience = event.queryStringParameters?.audience || DEFAULT_AUDIENCE;

    // Parse the ARN into its components
    const arnComponents = parseArn(identity.userArn);

    const claims = {
        iss: ISSUER_URL,
        sub: identity.userArn,
        aud: audience,
        iat: now,
        exp: now + TOKEN_DURATION_SECONDS
    };

    if (identity.accountId) claims["aws:account"] = identity.accountId;
    if (identity.userArn) claims["aws:arn"] = identity.userArn;
    if (identity.user) claims["aws:user_id"] = identity.user;
    if (identity.caller) claims["aws:caller_id"] = identity.caller;
    if (identity.accessKey) claims["aws:access_key"] = identity.accessKey;
    if (identity.principalOrgId) claims["aws:principal_org_id"] = identity.principalOrgId;
    if (identity.sourceIp) claims["aws:source_ip"] = identity.sourceIp;
    if (identity.userAgent) claims["aws:user_agent"] = identity.userAgent;
    if (arnComponents.partition) claims["aws:arn:partition"] = arnComponents.partition;
    if (arnComponents.service) claims["aws:arn:service"] = arnComponents.service;
    if (arnComponents.region) claims["aws:arn:region"] = arnComponents.region;
    if (arnComponents.account) claims["aws:arn:account"] = arnComponents.account;
    if (arnComponents.resourceType) claims["aws:arn:resource_type"] = arnComponents.resourceType;
    if (arnComponents.resourceName) claims["aws:arn:resource_name"] = arnComponents.resourceName;
    if (arnComponents.roleName) claims["aws:arn:role_name"] = arnComponents.roleName;
    if (arnComponents.sessionName) claims["aws:arn:session_name"] = arnComponents.sessionName;


    return claims;
}

const createToken = async (event) => {
    const claims = getClaimsFromRequest(event);

    const header = {
        alg: 'RS256',
        typ: 'JWT',
        kid: KMS_KEY_ID
    };

    const encodedHeader = base64url(JSON.stringify(header));
    const encodedPayload = base64url(JSON.stringify(claims));

    // Create signing input
    const signingInput = `${encodedHeader}.${encodedPayload}`;

    // Sign with KMS
    const signature = await signWithKMS(Buffer.from(signingInput, 'utf8'));
    const encodedSignature = base64url(signature);

    // Construct JWT
    const token = `${signingInput}.${encodedSignature}`;

    console.log({message: "Issuing token with claims.", ...claims});

    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
            'Pragma': 'no-cache'
        },
        body: JSON.stringify({
            access_token: token,
            token_type: 'Bearer',
            expires_in: TOKEN_DURATION_SECONDS
        })
    };
}


export const handler = async (event, context) => {
    console.log({message: "Received request", ...event});
    try {
        switch (event?.requestContext?.resourcePath) {
            case METADATA_PATH: {
                return getMetadata();
            }
            case JWKS_PATH: {
                return await jwks();
            }
            case TOKEN_PATH : {
                return await createToken(event);
            }
            default:
                return {
                    statusCode: 404,
                    headers: {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    body: JSON.stringify({message: "Not found."})
                }
        }
    } catch (error) {
        console.error(error, {message: "Error processing request."})
        return {
            statusCode: 500,
            headers: {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            body: JSON.stringify({message: "Internal server error."})
        }
    }
}
