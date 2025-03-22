#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Rotation
# This script rotates the Sealed Secrets master key in AWS Secrets Manager
# Only authorized team leads should run this script during scheduled maintenance windows

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
BACKUP_FILE_JSON="${BACKUP_DIR}/sealed-secrets-key-before-rotation-${TIMESTAMP}.json"
BACKUP_FILE_YAML="${BACKUP_DIR}/sealed-secrets-key-before-rotation-${TIMESTAMP}.yaml"
NEW_KEY_JSON="${BACKUP_DIR}/sealed-secrets-key-new-${TIMESTAMP}.json"
NEW_KEY_YAML="${BACKUP_DIR}/sealed-secrets-key-new-${TIMESTAMP}.yaml"
ROTATION_LOG="${BACKUP_DIR}/rotation-log.txt"

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

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Display warning and confirmation
echo -e "${YELLOW}WARNING: This will rotate the Sealed Secrets master key.${NC}"
echo -e "${YELLOW}This is a sensitive operation that should only be performed:${NC}"
echo -e "${YELLOW}  - By authorized team leads${NC}"
echo -e "${YELLOW}  - During scheduled maintenance windows${NC}"
echo -e "${YELLOW}  - After notifying all team members${NC}"
echo
echo -e "${YELLOW}The rotation process:${NC}"
echo -e "${YELLOW}  1. Backs up the current key from AWS Secrets Manager${NC}"
echo -e "${YELLOW}  2. Generates a new key${NC}"
echo -e "${YELLOW}  3. Updates the key in AWS Secrets Manager${NC}"
echo -e "${YELLOW}  4. Creates both JSON and YAML versions of the new key${NC}"
echo
echo -e "${YELLOW}After rotation, you should notify all developers to update their sealed-secrets-controller.${NC}"
echo

read -p "Have you notified the team about this rotation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Please notify the team before proceeding with key rotation.${NC}"
  exit 1
fi

read -p "Are you performing this rotation during a scheduled maintenance window? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Please only perform key rotation during scheduled maintenance windows.${NC}"
  exit 1
fi

read -p "Are you sure you want to proceed with key rotation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Operation cancelled.${NC}"
  exit 0
fi

# Check if the key exists in AWS Secrets Manager
echo -e "${BLUE}Checking for master key in AWS Secrets Manager...${NC}"
if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${RED}Error: Master key not found in AWS Secrets Manager.${NC}"
  echo -e "Please run setup-master-key.sh first to create the master key."
  exit 1
fi

# Backup the current key from AWS Secrets Manager
echo -e "${BLUE}Backing up current master key from AWS Secrets Manager...${NC}"
aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text > "$BACKUP_FILE_JSON"
echo -e "${GREEN}Current key backed up to $BACKUP_FILE_JSON${NC}"

# Convert JSON to YAML format for Kubernetes application
echo -e "${BLUE}Creating YAML version of the current key...${NC}"
# Extract the base64 encoded values from the JSON
TLS_CRT=$(jq -r '.data."tls.crt"' "$BACKUP_FILE_JSON")
TLS_KEY=$(jq -r '.data."tls.key"' "$BACKUP_FILE_JSON")
SECRET_NAME=$(jq -r '.metadata.name' "$BACKUP_FILE_JSON")

# Create the YAML file for the current key
cat > "$BACKUP_FILE_YAML" <<EOF
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
echo -e "${GREEN}YAML version of current key created at $BACKUP_FILE_YAML${NC}"

# Log the rotation
mkdir -p "$(dirname "$ROTATION_LOG")"
echo "Key rotation performed on $(date)" >> "$ROTATION_LOG"
echo "Previous key backed up to $BACKUP_FILE_JSON and $BACKUP_FILE_YAML" >> "$ROTATION_LOG"

# Generate a new key pair
echo -e "${BLUE}Generating new key pair...${NC}"
TMPDIR=$(mktemp -d)
openssl req -x509 -days 3650 -nodes -newkey rsa:4096 \
  -keyout "${TMPDIR}/tls.key" -out "${TMPDIR}/tls.crt" \
  -subj "/CN=sealed-secrets/O=scholar-spark"

# Create a JSON structure for the new key
echo -e "${BLUE}Creating JSON structure for the new key...${NC}"
cat > "$NEW_KEY_JSON" <<EOF
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

# Create a YAML version for Kubernetes application
echo -e "${BLUE}Creating YAML version of the new key...${NC}"
cat > "$NEW_KEY_YAML" <<EOF
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

# Update AWS Secrets Manager with the new key
echo -e "${BLUE}Updating key in AWS Secrets Manager...${NC}"
NEW_SECRET_CONTENT=$(cat "$NEW_KEY_JSON")

# Update the key in AWS Secrets Manager
aws secretsmanager update-secret \
  --secret-id "$AWS_SECRET_NAME" \
  --secret-string "$NEW_SECRET_CONTENT"

# Clean up temporary files
rm -rf "$TMPDIR"

# Log completion
echo "New key deployed to AWS Secrets Manager successfully on $(date)" >> "$ROTATION_LOG"
echo "New key backed up to $NEW_KEY_JSON and $NEW_KEY_YAML" >> "$ROTATION_LOG"

echo -e "${GREEN}Master key rotation complete!${NC}"
echo -e "${YELLOW}Important: Distribute the new YAML key file to all developers who need to update their sealed-secrets-controller.${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run ./backup-master-key.sh to create additional backups of the new key"
echo -e "2. Store backups in secure locations according to security policy"
echo -e "3. Notify developers to update their sealed-secrets-controller with the new key"
echo -e "4. Verify functionality of all applications using sealed secrets after developers update"

# Offer to run backup script
read -p "Do you want to run the backup script now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo -e "${BLUE}Running backup script...${NC}"
  ./backup-master-key.sh
fi
