#!/bin/bash
set -euo pipefail

# Scholar Spark Admin Tools - Sealed Secrets Emergency Recovery
# This script restores a backed-up Sealed Secrets master key to AWS Secrets Manager
# Only authorized team leads should run this script in emergency situations

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
RECOVERY_LOG="${BACKUP_DIR}/recovery-log.txt"
BACKUP_TAG="Recovery-${TIMESTAMP}"

# Default values
KEY_FILE=""
FROM_S3=false
FROM_AWS_BACKUP=false
AWS_VERSION_ID=""
AWS_BACKUP_BUCKET="scholar-spark-key-backups"
AWS_BACKUP_PREFIX="sealed-secrets-keys"
S3_KEY=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    --from-s3)
      FROM_S3=true
      shift
      ;;
    --s3-key)
      S3_KEY="$2"
      shift 2
      ;;
    --from-aws-backup)
      FROM_AWS_BACKUP=true
      shift
      ;;
    --aws-version-id)
      AWS_VERSION_ID="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  --key-file FILE       Path to the backup key file (JSON format)"
      echo "  --from-s3             Recover key from AWS S3"
      echo "  --s3-key KEY          S3 key for the backup file (required with --from-s3)"
      echo "  --from-aws-backup     Recover key from AWS Secrets Manager backup"
      echo "  --aws-version-id ID   Version ID or stage name for AWS backup (required with --from-aws-backup)"
      echo "  --help                Show this help message"
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
echo -e "${RED}!!! EMERGENCY RECOVERY PROCEDURE !!!${NC}"
echo -e "${YELLOW}WARNING: This will replace the current Sealed Secrets master key in AWS Secrets Manager.${NC}"
echo -e "${YELLOW}This is a sensitive operation that should only be performed:${NC}"
echo -e "${YELLOW}  - By authorized team leads${NC}"
echo -e "${YELLOW}  - In emergency situations when the current key is compromised or lost${NC}"
echo -e "${YELLOW}  - After notifying all team members${NC}"
echo
echo -e "${YELLOW}The recovery process:${NC}"
echo -e "${YELLOW}  1. Backs up the current key from AWS (if it exists)${NC}"
echo -e "${YELLOW}  2. Restores the backup key to AWS Secrets Manager${NC}"
echo -e "${YELLOW}  3. Creates a YAML version of the key for Kubernetes applications${NC}"
echo

read -p "Have you notified the team about this emergency recovery? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Please notify the team before proceeding with emergency recovery.${NC}"
  exit 1
fi

read -p "Are you sure you want to proceed with emergency recovery? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Operation cancelled.${NC}"
  exit 0
fi

# Determine the source of the backup key
if [[ "$FROM_AWS_BACKUP" == true ]]; then
  if [[ -z "$AWS_VERSION_ID" ]]; then
    echo -e "${RED}Error: --aws-version-id is required with --from-aws-backup.${NC}"
    exit 1
  fi
  
  echo -e "${BLUE}Retrieving key from AWS Secrets Manager backup...${NC}"
  if ! aws secretsmanager describe-secret --secret-id "$AWS_BACKUP_SECRET_NAME" &> /dev/null; then
    echo -e "${RED}Error: Backup secret not found in AWS Secrets Manager.${NC}"
    exit 1
  fi
  
  # List available versions to help the user
  echo -e "${BLUE}Available backup versions:${NC}"
  aws secretsmanager list-secret-version-ids --secret-id "$AWS_BACKUP_SECRET_NAME" --query "Versions[*].[VersionId,VersionStages]" --output table
  
  # Get the secret value for the specified version
  TMPDIR=$(mktemp -d)
  KEY_FILE="${TMPDIR}/aws-backup-key.json"
  
  if [[ "$AWS_VERSION_ID" == *"-"* ]]; then
    # Assume it's a version stage name
    aws secretsmanager get-secret-value --secret-id "$AWS_BACKUP_SECRET_NAME" --version-stage "$AWS_VERSION_ID" --query SecretString --output text > "$KEY_FILE"
  else
    # Assume it's a version ID
    aws secretsmanager get-secret-value --secret-id "$AWS_BACKUP_SECRET_NAME" --version-id "$AWS_VERSION_ID" --query SecretString --output text > "$KEY_FILE"
  fi
  
  if [[ ! -s "$KEY_FILE" ]]; then
    echo -e "${RED}Error: Failed to retrieve key from AWS Secrets Manager backup.${NC}"
    rm -rf "$TMPDIR"
    exit 1
  fi
  
  echo -e "${GREEN}Key retrieved from AWS Secrets Manager backup.${NC}"
elif [[ "$FROM_S3" == true ]]; then
  if [[ -z "$S3_KEY" ]]; then
    echo -e "${RED}Error: --s3-key is required with --from-s3.${NC}"
    exit 1
  fi
  
  echo -e "${BLUE}Retrieving key from AWS S3...${NC}"
  TMPDIR=$(mktemp -d)
  KEY_FILE="${TMPDIR}/s3-key.json"
  
  if ! aws s3 cp "s3://${AWS_BACKUP_BUCKET}/${S3_KEY}" "$KEY_FILE"; then
    echo -e "${RED}Error: Failed to retrieve key from S3.${NC}"
    rm -rf "$TMPDIR"
    exit 1
  fi
  
  echo -e "${GREEN}Key retrieved from AWS S3.${NC}"
elif [[ -z "$KEY_FILE" ]]; then
  echo -e "${RED}Error: No key source specified.${NC}"
  echo -e "Please specify one of: --key-file, --from-aws-backup, or --from-s3."
  exit 1
elif [[ ! -f "$KEY_FILE" ]]; then
  echo -e "${RED}Error: Key file not found: $KEY_FILE${NC}"
  exit 1
fi

# Check if the key file is in JSON format
if ! jq . "$KEY_FILE" > /dev/null 2>&1; then
  echo -e "${RED}Error: Key file is not in valid JSON format.${NC}"
  echo -e "Please provide a JSON formatted key file."
  exit 1
fi

# Check if the current key exists in AWS and back it up
CURRENT_BACKUP="${BACKUP_DIR}/sealed-secrets-key-before-recovery-${TIMESTAMP}.json"
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  echo -e "${BLUE}Backing up current master key from AWS...${NC}"
  CURRENT_KEY=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)
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
fi

# Restore the backup key to AWS Secrets Manager
echo -e "${BLUE}Restoring backup key to AWS Secrets Manager...${NC}"
SECRET_CONTENT=$(cat "$KEY_FILE")

# Update or create the secret in AWS Secrets Manager
if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" &> /dev/null; then
  aws secretsmanager update-secret \
    --secret-id "$AWS_SECRET_NAME" \
    --secret-string "$SECRET_CONTENT"
else
  echo -e "${YELLOW}Secret not found in AWS Secrets Manager. Creating...${NC}"
  aws secretsmanager create-secret \
    --name "$AWS_SECRET_NAME" \
    --description "Sealed Secrets master key for Scholar Spark (Emergency Recovery)" \
    --secret-string "$SECRET_CONTENT" \
    --tags Key=Environment,Value=Production Key=Application,Value=ScholarSpark
fi

# Create a YAML version for Kubernetes application
echo -e "${BLUE}Creating YAML version of the key for Kubernetes...${NC}"
YAML_FILE="${BACKUP_DIR}/sealed-secrets-key-recovered-${TIMESTAMP}.yaml"

# Extract the base64 encoded values from the JSON
TLS_CRT=$(jq -r '.data."tls.crt"' "$KEY_FILE")
TLS_KEY=$(jq -r '.data."tls.key"' "$KEY_FILE")
SECRET_NAME=$(jq -r '.metadata.name' "$KEY_FILE")

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
echo -e "${GREEN}YAML version created at $YAML_FILE${NC}"

# Clean up temporary files
if [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]]; then
  rm -rf "$TMPDIR"
fi

# Log the recovery
mkdir -p "$(dirname "$RECOVERY_LOG")"
echo "Emergency recovery performed on $(date)" >> "$RECOVERY_LOG"
echo "Restored from: $KEY_FILE" >> "$RECOVERY_LOG"
if [[ -n "${CURRENT_BACKUP:-}" && -f "${CURRENT_BACKUP:-}" ]]; then
  echo "Previous key backed up to: $CURRENT_BACKUP" >> "$RECOVERY_LOG"
  echo "Previous key backed up to AWS Secrets Manager with version tag: $BACKUP_TAG" >> "$RECOVERY_LOG"
fi
echo "YAML version created at: $YAML_FILE" >> "$RECOVERY_LOG"

echo -e "${GREEN}Emergency recovery complete!${NC}"
echo -e "${GREEN}Key restored to AWS Secrets Manager: $AWS_SECRET_NAME${NC}"
if [[ -n "${CURRENT_BACKUP:-}" && -f "${CURRENT_BACKUP:-}" ]]; then
  echo -e "${GREEN}Previous key backed up in AWS Secrets Manager: $AWS_BACKUP_SECRET_NAME (version: $BACKUP_TAG)${NC}"
fi
echo -e "${GREEN}YAML version created at: $YAML_FILE${NC}"
echo -e "${YELLOW}Important: Distribute the YAML key file to all developers who need to update their sealed-secrets-controller.${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run ./backup-master-key.sh to create additional backups of the restored key"
echo -e "2. Store backups in secure locations according to security policy"
echo -e "3. Distribute the YAML key file to developers to update their sealed-secrets-controller"
echo -e "4. Document this incident according to your incident response policy"

# Offer to run backup script
read -p "Do you want to run the backup script now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo -e "${BLUE}Running backup script...${NC}"
  ./backup-master-key.sh
fi
