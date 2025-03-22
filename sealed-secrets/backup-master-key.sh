#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Master Key Backup
# This script creates secure backups of the Sealed Secrets master key
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
BACKUP_FILE_JSON="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.json"
BACKUP_FILE_YAML="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.yaml"
ENCRYPTED_BACKUP="${BACKUP_DIR}/sealed-secrets-key-${TIMESTAMP}.enc"
AWS_BACKUP_BUCKET="scholar-spark-key-backups"
AWS_BACKUP_PREFIX="sealed-secrets-keys"

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

# Check if the key exists in AWS Secrets Manager
echo -e "${BLUE}Checking for master key in AWS Secrets Manager...${NC}"
if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${RED}Error: Master key not found in AWS Secrets Manager.${NC}"
  echo -e "Please run setup-master-key.sh first to create the master key."
  exit 1
fi

# Backup the key from AWS Secrets Manager
echo -e "${BLUE}Creating backup of master key from AWS Secrets Manager...${NC}"
aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text > "$BACKUP_FILE_JSON"
echo -e "${GREEN}Key backed up to $BACKUP_FILE_JSON${NC}"

# Convert JSON to YAML format for Kubernetes application
echo -e "${BLUE}Creating YAML version of the key for Kubernetes...${NC}"
# Extract the base64 encoded values from the JSON
TLS_CRT=$(jq -r '.data."tls.crt"' "$BACKUP_FILE_JSON")
TLS_KEY=$(jq -r '.data."tls.key"' "$BACKUP_FILE_JSON")
SECRET_NAME=$(jq -r '.metadata.name' "$BACKUP_FILE_JSON")

# Create the YAML file
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
echo -e "${GREEN}YAML version created at $BACKUP_FILE_YAML${NC}"

# Offer encryption option
echo -e "${YELLOW}It is recommended to encrypt the backup files for additional security.${NC}"
read -p "Do you want to encrypt the backup files? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  # Generate a random password for encryption
  PASSWORD=$(openssl rand -base64 32)
  
  # Encrypt the backup files
  echo -e "${BLUE}Encrypting backup files...${NC}"
  ENCRYPTED_JSON="${ENCRYPTED_BACKUP}.json"
  ENCRYPTED_YAML="${ENCRYPTED_BACKUP}.yaml"
  
  openssl enc -aes-256-cbc -salt -in "$BACKUP_FILE_JSON" -out "$ENCRYPTED_JSON" -pass pass:"$PASSWORD"
  openssl enc -aes-256-cbc -salt -in "$BACKUP_FILE_YAML" -out "$ENCRYPTED_YAML" -pass pass:"$PASSWORD"
  
  # Display the password
  echo -e "${GREEN}Backups encrypted to:${NC}"
  echo -e "${GREEN}- JSON format: $ENCRYPTED_JSON${NC}"
  echo -e "${GREEN}- YAML format: $ENCRYPTED_YAML${NC}"
  echo -e "${YELLOW}Encryption password: $PASSWORD${NC}"
  echo -e "${YELLOW}IMPORTANT: Store this password securely in your password manager!${NC}"
  
  # Remove the unencrypted backups
  rm "$BACKUP_FILE_JSON" "$BACKUP_FILE_YAML"
  BACKUP_FILE_JSON="$ENCRYPTED_JSON"
  BACKUP_FILE_YAML="$ENCRYPTED_YAML"
fi

# Offer AWS S3 backup option
echo -e "${YELLOW}It is recommended to store the backup in a secure location such as AWS S3.${NC}"
read -p "Do you want to upload the backup to AWS S3? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  # Check if the bucket exists
  if ! aws s3 ls "s3://${AWS_BACKUP_BUCKET}" &> /dev/null; then
    echo -e "${YELLOW}Bucket $AWS_BACKUP_BUCKET does not exist.${NC}"
    read -p "Do you want to create it? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      echo -e "${BLUE}Creating S3 bucket...${NC}"
      aws s3 mb "s3://${AWS_BACKUP_BUCKET}" --region us-east-1
      
      # Enable versioning on the bucket
      aws s3api put-bucket-versioning \
        --bucket "$AWS_BACKUP_BUCKET" \
        --versioning-configuration Status=Enabled
      
      # Enable server-side encryption
      aws s3api put-bucket-encryption \
        --bucket "$AWS_BACKUP_BUCKET" \
        --server-side-encryption-configuration '{
          "Rules": [
            {
              "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
              }
            }
          ]
        }'
    else
      echo -e "${RED}Cannot upload to S3 without a valid bucket.${NC}"
      echo -e "${YELLOW}Please store the backup file manually in a secure location.${NC}"
      exit 0
    fi
  fi
  
  # Upload to S3
  echo -e "${BLUE}Uploading backups to AWS S3...${NC}"
  S3_KEY_JSON="${AWS_BACKUP_PREFIX}/$(basename "$BACKUP_FILE_JSON")"
  S3_KEY_YAML="${AWS_BACKUP_PREFIX}/$(basename "$BACKUP_FILE_YAML")"
  
  aws s3 cp "$BACKUP_FILE_JSON" "s3://${AWS_BACKUP_BUCKET}/${S3_KEY_JSON}" --sse AES256
  aws s3 cp "$BACKUP_FILE_YAML" "s3://${AWS_BACKUP_BUCKET}/${S3_KEY_YAML}" --sse AES256
  
  echo -e "${GREEN}Backups uploaded to:${NC}"
  echo -e "${GREEN}- JSON format: s3://${AWS_BACKUP_BUCKET}/${S3_KEY_JSON}${NC}"
  echo -e "${GREEN}- YAML format: s3://${AWS_BACKUP_BUCKET}/${S3_KEY_YAML}${NC}"
fi

# Remind about offline storage
echo -e "${YELLOW}Remember to also store a copy of the backup in secure offline storage.${NC}"
echo -e "${YELLOW}Follow your organization's security policy for handling sensitive cryptographic material.${NC}"

echo -e "${GREEN}Backup process complete!${NC}"
