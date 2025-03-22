#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Setup
# This script generates a new Sealed Secrets master key and stores it in AWS Secrets Manager
# Only authorized team leads should run this script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_SECRET_NAME="scholar-spark/sealed-secrets/master-key"
AWS_BACKUP_SECRET_NAME="scholar-spark/sealed-secrets/master-key-backups"
BACKUP_DIR="./key-backup"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
YAML_FILE="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.yaml"

# Check for required tools
echo -e "${BLUE}Checking prerequisites...${NC}"
for cmd in openssl aws jq; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd is required but not installed.${NC}"
    exit 1
  fi
done

# Check for AWS credentials - use AWS CLI config if available
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
  if [[ -n "$AWS_ACCESS_KEY_ID" ]]; then
    echo -e "${BLUE}Using AWS access key from AWS CLI configuration.${NC}"
    export AWS_ACCESS_KEY_ID
  fi
fi

if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
  if [[ -n "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo -e "${BLUE}Using AWS secret key from AWS CLI configuration.${NC}"
    export AWS_SECRET_ACCESS_KEY
  fi
fi

if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
  AWS_REGION=$(aws configure get region 2>/dev/null || echo "")
  if [[ -n "$AWS_REGION" ]]; then
    echo -e "${BLUE}Using AWS region from AWS CLI configuration: $AWS_REGION${NC}"
    export AWS_REGION
  fi
fi

# Final check for AWS credentials
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo -e "${RED}Error: AWS credentials not found in environment or AWS CLI configuration.${NC}"
  echo -e "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables or configure AWS CLI."
  exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Display warning and confirmation
echo -e "${RED}!!! WARNING !!!${NC}"
echo -e "${YELLOW}This script will generate a new Sealed Secrets master key and store it in AWS Secrets Manager.${NC}"
echo -e "${YELLOW}This is a sensitive operation that should only be performed:${NC}"
echo -e "${YELLOW}  - By authorized team leads${NC}"
echo -e "${YELLOW}  - During initial setup${NC}"
echo -e "${YELLOW}  - After a planned key rotation${NC}"
echo
echo -e "${YELLOW}If you need to rotate an existing key, use rotate-master-key.sh instead.${NC}"
echo

read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Operation cancelled.${NC}"
  exit 0
fi

# Check if a key already exists in AWS Secrets Manager
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${YELLOW}A master key already exists in AWS Secrets Manager.${NC}"
  
  read -p "Do you want to back up the existing key before proceeding? (Y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo -e "${BLUE}Backing up existing key...${NC}"
    
    # Get the existing key from AWS Secrets Manager
    EXISTING_KEY=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)
    
    # Store the backup in AWS Secrets Manager with timestamp
    if aws secretsmanager describe-secret --secret-id "$AWS_BACKUP_SECRET_NAME" &> /dev/null; then
      # Update existing backup secret with a new version
      aws secretsmanager put-secret-value \
        --secret-id "$AWS_BACKUP_SECRET_NAME" \
        --secret-string "$EXISTING_KEY" \
        --version-stages "AWSCURRENT" "Backup-${TIMESTAMP}"
    else
      # Create a new backup secret
      aws secretsmanager create-secret \
        --name "$AWS_BACKUP_SECRET_NAME" \
        --description "Backups of Sealed Secrets master keys for Scholar Spark" \
        --secret-string "$EXISTING_KEY" \
        --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
    fi
    
    # Also save a local YAML copy for Kubernetes applications
    echo "$EXISTING_KEY" | jq -r '.' > "${BACKUP_DIR}/sealed-secrets-key-backup-${TIMESTAMP}.json"
    
    # Extract the base64 encoded values from the JSON
    TLS_CRT=$(echo "$EXISTING_KEY" | jq -r '.data."tls.crt"')
    TLS_KEY=$(echo "$EXISTING_KEY" | jq -r '.data."tls.key"')
    SECRET_NAME=$(echo "$EXISTING_KEY" | jq -r '.metadata.name')
    
    # Create the YAML file
    cat > "${BACKUP_DIR}/sealed-secrets-key-backup-${TIMESTAMP}.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: kube-system
data:
  tls.crt: ${TLS_CRT}
  tls.key: ${TLS_KEY}
type: kubernetes.io/tls
EOF
    
    echo -e "${GREEN}Existing key backed up in AWS Secrets Manager with version tag: Backup-${TIMESTAMP}${NC}"
    echo -e "${GREEN}Local YAML backup created at: ${BACKUP_DIR}/sealed-secrets-key-backup-${TIMESTAMP}.yaml${NC}"
  fi
  
  read -p "Do you want to continue and overwrite the existing key? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Operation cancelled.${NC}"
    exit 0
  fi
fi

# Generate a new key pair
echo -e "${BLUE}Generating new master key...${NC}"
TMPDIR=$(mktemp -d)
CERT_FILE="${TMPDIR}/tls.crt"
KEY_FILE="${TMPDIR}/tls.key"

# Generate private key
openssl genrsa -out "$KEY_FILE" 4096

# Generate certificate
openssl req -x509 -new -nodes -key "$KEY_FILE" -sha256 -days 3650 \
  -out "$CERT_FILE" \
  -subj "/CN=sealed-secrets/O=Scholar-Spark"

# Create the secret in JSON format
SECRET_NAME="sealed-secrets-key"
SECRET_JSON=$(cat <<EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "${SECRET_NAME}",
    "namespace": "kube-system",
    "creationTimestamp": null
  },
  "data": {
    "tls.crt": "$(base64 -w0 < "$CERT_FILE")",
    "tls.key": "$(base64 -w0 < "$KEY_FILE")"
  },
  "type": "kubernetes.io/tls"
}
EOF
)

# Store the key in AWS Secrets Manager
echo -e "${BLUE}Storing master key in AWS Secrets Manager...${NC}"
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  aws secretsmanager update-secret \
    --secret-id "$AWS_SECRET_NAME" \
    --secret-string "$SECRET_JSON"
else
  aws secretsmanager create-secret \
    --name "$AWS_SECRET_NAME" \
    --description "Sealed Secrets master key for Scholar Spark" \
    --secret-string "$SECRET_JSON" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
fi

# Also store as a backup version in the backup secret
if aws secretsmanager describe-secret --secret-id "$AWS_BACKUP_SECRET_NAME" &> /dev/null; then
  # Update existing backup secret with a new version
  aws secretsmanager put-secret-value \
    --secret-id "$AWS_BACKUP_SECRET_NAME" \
    --secret-string "$SECRET_JSON" \
    --version-stages "AWSCURRENT" "Initial-${TIMESTAMP}"
else
  # Create a new backup secret
  aws secretsmanager create-secret \
    --name "$AWS_BACKUP_SECRET_NAME" \
    --description "Backups of Sealed Secrets master keys for Scholar Spark" \
    --secret-string "$SECRET_JSON" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
fi

# Create a YAML version for Kubernetes applications
echo -e "${BLUE}Creating YAML version of the key for Kubernetes...${NC}"
mkdir -p "$(dirname "$YAML_FILE")"

# Create the YAML file
cat > "$YAML_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: kube-system
data:
  tls.crt: $(base64 -w0 < "$CERT_FILE")
  tls.key: $(base64 -w0 < "$KEY_FILE")
type: kubernetes.io/tls
EOF

# Clean up temporary files
rm -rf "$TMPDIR"

echo -e "${GREEN}Master key setup complete!${NC}"
echo -e "${GREEN}Key stored in AWS Secrets Manager: $AWS_SECRET_NAME${NC}"
echo -e "${GREEN}Backup stored in AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME (version: Initial-${TIMESTAMP})${NC}"
echo -e "${GREEN}YAML version created at: $YAML_FILE${NC}"
echo -e "${YELLOW}Important: Distribute the YAML key file to developers who need to update their sealed-secrets-controller.${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run ./backup-master-key.sh to create additional backups"
echo -e "2. Store backups in secure locations according to security policy"
echo -e "3. Distribute the YAML key file to developers"
