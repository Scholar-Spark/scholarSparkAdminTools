#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Rotation
# This script rotates the Sealed Secrets master key in AWS Secrets Manager
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
BACKUP_TAG="Rotation-${TIMESTAMP}"
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
echo -e "${YELLOW}This script will rotate the Sealed Secrets master key in AWS Secrets Manager.${NC}"
echo -e "${YELLOW}This is a sensitive operation that should only be performed:${NC}"
echo -e "${YELLOW}  - By authorized team leads${NC}"
echo -e "${YELLOW}  - During planned key rotation periods${NC}"
echo -e "${YELLOW}  - After notifying all team members${NC}"
echo
echo -e "${YELLOW}After rotation, all existing sealed secrets will still be decryptable,${NC}"
echo -e "${YELLOW}but new secrets will be encrypted with the new key.${NC}"
echo

read -p "Have you notified the team about this key rotation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Please notify the team before proceeding with key rotation.${NC}"
  exit 1
fi

read -p "Are you sure you want to proceed with key rotation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Operation cancelled.${NC}"
  exit 0
fi

# Check if the current key exists in AWS Secrets Manager
if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${RED}Error: Master key not found in AWS Secrets Manager.${NC}"
  echo -e "Please run setup-master-key.sh first to create the master key."
  exit 1
fi

# Backup the current key from AWS Secrets Manager
echo -e "${BLUE}Backing up current master key from AWS Secrets Manager...${NC}"
CURRENT_KEY=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)
CURRENT_BACKUP="${BACKUP_DIR}/sealed-secrets-key-before-rotation-${TIMESTAMP}.json"
echo "$CURRENT_KEY" > "$CURRENT_BACKUP"

# Store the backup in AWS Secrets Manager with timestamp
if aws secretsmanager describe-secret --secret-id "$AWS_BACKUP_SECRET_NAME" &> /dev/null; then
  # Update existing backup secret with a new version
  aws secretsmanager put-secret-value \
    --secret-id "$AWS_BACKUP_SECRET_NAME" \
    --secret-string "$CURRENT_KEY" \
    --version-stages "AWSCURRENT" "$BACKUP_TAG"
  echo -e "${GREEN}Current key backed up in AWS Secrets Manager with version tag: $BACKUP_TAG${NC}"
else
  # Create a new backup secret
  aws secretsmanager create-secret \
    --name "$AWS_BACKUP_SECRET_NAME" \
    --description "Backups of Sealed Secrets master keys for Scholar Spark" \
    --secret-string "$CURRENT_KEY" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
  echo -e "${GREEN}Backup secret created in AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME${NC}"
fi

echo -e "${GREEN}Current key backed up to $CURRENT_BACKUP${NC}"

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

# Extract the secret name from the current key
SECRET_NAME=$(echo "$CURRENT_KEY" | jq -r '.metadata.name')

# Create the secret in JSON format
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

# Update the key in AWS Secrets Manager
echo -e "${BLUE}Updating master key in AWS Secrets Manager...${NC}"
aws secretsmanager update-secret \
  --secret-id "$AWS_SECRET_NAME" \
  --secret-string "$SECRET_JSON"

# Create a YAML version for Kubernetes applications
echo -e "${BLUE}Creating YAML version of the new key for Kubernetes...${NC}"
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

echo -e "${GREEN}Master key rotation complete!${NC}"
echo -e "${GREEN}New key stored in AWS Secrets Manager: $AWS_SECRET_NAME${NC}"
echo -e "${GREEN}Previous key backed up in AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME (version: $BACKUP_TAG)${NC}"
echo -e "${GREEN}Previous key backed up to: $CURRENT_BACKUP${NC}"
echo -e "${GREEN}YAML version of new key created at: $YAML_FILE${NC}"
echo -e "${YELLOW}Important: Distribute the YAML key file to all developers who need to update their sealed-secrets-controller.${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run ./backup-master-key.sh to create additional backups of the new key"
echo -e "2. Store backups in secure locations according to security policy"
echo -e "3. Distribute the YAML key file to developers to update their sealed-secrets-controller"

# Offer to run backup script
read -p "Do you want to run the backup script now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo -e "${BLUE}Running backup script...${NC}"
  ./backup-master-key.sh
fi
