#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Setup
# This script creates and uploads the master key for Sealed Secrets to AWS Secrets Manager
# Only authorized team leads should run this script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_SECRET_NAME="scholar-spark/sealed-secrets/master-key"
BACKUP_DIR="./key-backup"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.yaml"
BACKUP_FILE_JSON="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.json"

# Check for required tools
echo -e "${BLUE}Checking prerequisites...${NC}"
for cmd in aws openssl jq; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd is required but not installed.${NC}"
    exit 1
  fi
done

# Check for AWS credentials
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo -e "${RED}Error: AWS credentials not found in environment.${NC}"
  echo -e "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
  exit 1
fi

# Verify AWS permissions
echo -e "${BLUE}Verifying AWS permissions...${NC}"
if ! aws secretsmanager get-random-password --password-length 32 &> /dev/null; then
  echo -e "${RED}Error: Insufficient AWS permissions. Please ensure you have the correct IAM permissions.${NC}"
  exit 1
fi

# Confirm with user
echo -e "${YELLOW}WARNING: This will create a new Sealed Secrets master key and upload it to AWS Secrets Manager.${NC}"
echo -e "${YELLOW}This is a sensitive operation that should only be performed by authorized team leads.${NC}"
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Operation cancelled.${NC}"
  exit 0
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if a key already exists in AWS Secrets Manager
echo -e "${BLUE}Checking if a master key already exists in AWS Secrets Manager...${NC}"
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${YELLOW}A master key already exists in AWS Secrets Manager.${NC}"
  read -p "Do you want to back it up before proceeding? (Y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo -e "${BLUE}Backing up existing key from AWS...${NC}"
    aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text > "$BACKUP_FILE_JSON"
    echo -e "${GREEN}Existing key backed up to $BACKUP_FILE_JSON${NC}"
  fi
  
  read -p "Do you want to overwrite the existing key? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Operation cancelled.${NC}"
    exit 0
  fi
fi

# Generate a new key pair
echo -e "${BLUE}Generating new key pair...${NC}"
TMPDIR=$(mktemp -d)
openssl req -x509 -days 3650 -nodes -newkey rsa:4096 \
  -keyout "${TMPDIR}/tls.key" -out "${TMPDIR}/tls.crt" \
  -subj "/CN=sealed-secrets/O=scholar-spark"

# Create the secret structure
echo -e "${BLUE}Creating secret structure...${NC}"
SECRET_NAME="sealed-secrets-key"

# Create a JSON structure similar to what would be in a Kubernetes secret
cat > "${TMPDIR}/secret.json" <<EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "${SECRET_NAME}",
    "creationTimestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  },
  "data": {
    "tls.crt": "$(base64 -w 0 < ${TMPDIR}/tls.crt)",
    "tls.key": "$(base64 -w 0 < ${TMPDIR}/tls.key)"
  },
  "type": "kubernetes.io/tls"
}
EOF

# Backup the new key
echo -e "${BLUE}Backing up new key...${NC}"
cp "${TMPDIR}/secret.json" "$BACKUP_FILE_JSON"
echo -e "${GREEN}New key backed up to $BACKUP_FILE_JSON${NC}"

# Create a YAML version for Kubernetes application
echo -e "${BLUE}Creating YAML version of the key...${NC}"
cat > "$BACKUP_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: kube-system
data:
  tls.crt: $(base64 -w 0 < ${TMPDIR}/tls.crt)
  tls.key: $(base64 -w 0 < ${TMPDIR}/tls.key)
type: kubernetes.io/tls
EOF
echo -e "${GREEN}YAML version created at $BACKUP_FILE${NC}"

# Upload to AWS Secrets Manager
echo -e "${BLUE}Uploading key to AWS Secrets Manager...${NC}"
SECRET_CONTENT=$(cat "${TMPDIR}/secret.json")

# Check if the secret already exists in AWS
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${YELLOW}Secret already exists in AWS Secrets Manager. Updating...${NC}"
  aws secretsmanager update-secret \
    --secret-id "$AWS_SECRET_NAME" \
    --secret-string "$SECRET_CONTENT"
else
  echo -e "${BLUE}Creating new secret in AWS Secrets Manager...${NC}"
  aws secretsmanager create-secret \
    --name "$AWS_SECRET_NAME" \
    --description "Sealed Secrets master key for Scholar Spark" \
    --secret-string "$SECRET_CONTENT" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
fi

# Clean up temporary files
rm -rf "$TMPDIR"

echo -e "${GREEN}Master key setup complete!${NC}"
echo -e "${YELLOW}Important: Make sure to securely store the backup files:${NC}"
echo -e "${YELLOW}- JSON format: $BACKUP_FILE_JSON${NC}"
echo -e "${YELLOW}- YAML format: $BACKUP_FILE${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run ./backup-master-key.sh to create additional backups"
echo -e "2. Store backups in secure locations according to security policy"
echo -e "3. Provide the YAML format to developers who need to set up sealed-secrets-controller"

echo -e "${GREEN}Setup complete!${NC}"
