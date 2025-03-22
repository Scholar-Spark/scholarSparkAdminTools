#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Backup
# This script backs up the Sealed Secrets master key from AWS Secrets Manager
# Backups are stored in AWS Secrets Manager and locally as YAML/JSON files

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
BACKUP_TAG="Backup-${TIMESTAMP}"
YAML_FILE="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.yaml"
JSON_FILE="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.json"

# Default values
ENCRYPT=false
UPLOAD_TO_S3=false
AWS_BACKUP_BUCKET="scholar-spark-key-backups"
AWS_BACKUP_PREFIX="sealed-secrets-keys"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --encrypt)
      ENCRYPT=true
      shift
      ;;
    --upload-to-s3)
      UPLOAD_TO_S3=true
      shift
      ;;
    --bucket)
      AWS_BACKUP_BUCKET="$2"
      shift 2
      ;;
    --prefix)
      AWS_BACKUP_PREFIX="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  --encrypt            Encrypt the backup file with GPG"
      echo "  --upload-to-s3       Upload the backup to S3"
      echo "  --bucket BUCKET      S3 bucket name (default: $AWS_BACKUP_BUCKET)"
      echo "  --prefix PREFIX      S3 key prefix (default: $AWS_BACKUP_PREFIX)"
      echo "  --help               Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Error: Unknown option $1${NC}"
      exit 1
      ;;
  esac
done

# Check for required tools
echo -e "${BLUE}Checking prerequisites...${NC}"
for cmd in aws jq; do
  if ! command -v $cmd &> /dev/null; then
    echo -e "${RED}Error: $cmd is required but not installed.${NC}"
    exit 1
  fi
done

if [[ "$ENCRYPT" == true ]]; then
  if ! command -v gpg &> /dev/null; then
    echo -e "${RED}Error: gpg is required for encryption but not installed.${NC}"
    exit 1
  fi
fi

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

# Check if the master key exists in AWS Secrets Manager
echo -e "${BLUE}Checking if master key exists in AWS Secrets Manager...${NC}"
if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${RED}Error: Master key not found in AWS Secrets Manager.${NC}"
  exit 1
fi

# Retrieve the master key from AWS Secrets Manager
echo -e "${BLUE}Retrieving master key from AWS Secrets Manager...${NC}"
SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)

# Save the JSON backup
echo -e "${BLUE}Creating JSON backup...${NC}"
echo "$SECRET_VALUE" > "$JSON_FILE"
echo -e "${GREEN}JSON backup created at $JSON_FILE${NC}"

# Store the backup in AWS Secrets Manager with timestamp
echo -e "${BLUE}Storing backup in AWS Secrets Manager...${NC}"
if aws secretsmanager describe-secret --secret-id "$AWS_BACKUP_SECRET_NAME" &> /dev/null; then
  # Update existing backup secret with a new version
  aws secretsmanager put-secret-value \
    --secret-id "$AWS_BACKUP_SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --version-stages "AWSCURRENT" "$BACKUP_TAG"
  echo -e "${GREEN}Backup stored in AWS Secrets Manager with version tag: $BACKUP_TAG${NC}"
else
  # Create a new backup secret
  aws secretsmanager create-secret \
    --name "$AWS_BACKUP_SECRET_NAME" \
    --description "Backups of Sealed Secrets master keys for Scholar Spark" \
    --secret-string "$SECRET_VALUE" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
  echo -e "${GREEN}Backup secret created in AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME${NC}"
fi

# Create a YAML version for Kubernetes applications
echo -e "${BLUE}Creating YAML version of the key...${NC}"

# Extract the base64 encoded values from the JSON
TLS_CRT=$(echo "$SECRET_VALUE" | jq -r '.data."tls.crt"')
TLS_KEY=$(echo "$SECRET_VALUE" | jq -r '.data."tls.key"')
SECRET_NAME=$(echo "$SECRET_VALUE" | jq -r '.metadata.name')

# Create the YAML file
cat > "$YAML_FILE" <<EOF
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
echo -e "${GREEN}YAML backup created at $YAML_FILE${NC}"

# Encrypt backups if requested
if [[ "$ENCRYPT" == true ]]; then
  echo -e "${BLUE}Encrypting backup files...${NC}"
  
  # Encrypt JSON backup
  gpg --symmetric --cipher-algo AES256 "$JSON_FILE"
  rm "$JSON_FILE"
  echo -e "${GREEN}Encrypted JSON backup created at ${JSON_FILE}.gpg${NC}"
  
  # Encrypt YAML backup
  gpg --symmetric --cipher-algo AES256 "$YAML_FILE"
  rm "$YAML_FILE"
  echo -e "${GREEN}Encrypted YAML backup created at ${YAML_FILE}.gpg${NC}"
  
  # Update file names for potential S3 upload
  YAML_FILE="${YAML_FILE}.gpg"
  JSON_FILE="${JSON_FILE}.gpg"
fi

# Upload to S3 if requested
if [[ "$UPLOAD_TO_S3" == true ]]; then
  if [[ "$ENCRYPT" != true ]]; then
    echo -e "${YELLOW}Warning: Uploading unencrypted backups to S3 is not recommended.${NC}"
    read -p "Do you want to continue without encryption? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${BLUE}Operation cancelled. Please run again with --encrypt option.${NC}"
      exit 0
    fi
  fi
  
  echo -e "${BLUE}Uploading backups to S3...${NC}"
  
  # Upload JSON backup
  S3_JSON_PATH="s3://${AWS_BACKUP_BUCKET}/${AWS_BACKUP_PREFIX}/json/sealed-secrets-key-${TIMESTAMP}.json"
  if [[ "$ENCRYPT" == true ]]; then
    S3_JSON_PATH="${S3_JSON_PATH}.gpg"
  fi
  aws s3 cp "$JSON_FILE" "$S3_JSON_PATH"
  echo -e "${GREEN}JSON backup uploaded to $S3_JSON_PATH${NC}"
  
  # Upload YAML backup
  S3_YAML_PATH="s3://${AWS_BACKUP_BUCKET}/${AWS_BACKUP_PREFIX}/yaml/sealed-secrets-key-${TIMESTAMP}.yaml"
  if [[ "$ENCRYPT" == true ]]; then
    S3_YAML_PATH="${S3_YAML_PATH}.gpg"
  fi
  aws s3 cp "$YAML_FILE" "$S3_YAML_PATH"
  echo -e "${GREEN}YAML backup uploaded to $S3_YAML_PATH${NC}"
fi

echo -e "${GREEN}Backup complete!${NC}"
echo -e "${BLUE}Backup details:${NC}"
echo -e "- AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME (version: $BACKUP_TAG)"
echo -e "- JSON backup: $JSON_FILE"
echo -e "- YAML backup: $YAML_FILE"
if [[ "$UPLOAD_TO_S3" == true ]]; then
  echo -e "- S3 JSON backup: $S3_JSON_PATH"
  echo -e "- S3 YAML backup: $S3_YAML_PATH"
fi
