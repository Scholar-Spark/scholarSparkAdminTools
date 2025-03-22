# Master Key Management

## Initial Setup (Team Lead Only)

1. Clone the admin repository:
   ```bash
   git clone git@github.com:scholar-spark/scholar-spark-admin.git
   cd scholar-spark-admin/sealed-secrets
   ```

2. Ensure you have AWS credentials with appropriate permissions:
   ```bash
   # The scripts will automatically use your AWS CLI configuration if available
   # To verify your current AWS credentials:
   aws configure get aws_access_key_id
   aws configure get aws_secret_access_key
   aws configure get region
   
   # If you need to use different credentials for this operation:
   export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
   export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
   ```

3. Run the setup script:
   ```bash
   ./setup-master-key.sh
   ```

4. Securely store the backup key:
   ```bash
   ./backup-master-key.sh
   ```
   
   The backup key should be stored in a secure location such as:
   - Company password manager (restricted access)
   - Hardware security module
   - Secure offline storage

## Key Rotation (Every 90 Days)

1. Schedule key rotation during maintenance window
2. Notify team of upcoming rotation
3. Run rotation script:
   ```bash
   ./rotate-master-key.sh
   ```
4. Verify all sealed secrets still work after rotation

## Emergency Recovery

If the Sealed Secrets controller loses access to the master key:

1. Retrieve backup key from secure storage
2. Run emergency recovery script:
   ```bash
   ./emergency-recovery.sh --key-file /path/to/backup/key
   ```
3. Verify controller functionality after recovery
