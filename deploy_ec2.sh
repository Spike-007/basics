#!/bin/bash

set -e

# Accept stage as parameter
STAGE=$1
if [[ -z "$STAGE" ]]; then
  echo "Usage: $0 <Stage: Dev|Prod>"
  exit 1
fi

CONFIG_FILE="${STAGE,,}_config"  # lowercase
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file '$CONFIG_FILE' not found!"
  exit 1
fi

source "$CONFIG_FILE"

# Load AWS credentials from environment
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  echo "AWS credentials not set in environment!"
  exit 1
fi

echo "[*] Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP" \
  --region "$REGION" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "[+] Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo "[*] Waiting for instance to be in 'running' state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Get public IP
IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "[+] Public IP: $IP"

echo "[*] Waiting 60 seconds for instance to be SSH-ready..."
sleep 60

# Bootstrap Script
echo "[*] Installing Java 21, Maven and building app on remote instance..."
ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@$IP <<EOF
sudo apt update
sudo apt install -y openjdk-21-jdk maven git
git clone https://github.com/Trainings-TechEazy/test-repo-for-devops.git
cd test-repo-for-devops
mvn clean package
sudo nohup java -jar target/hellomvc-0.0.1-SNAPSHOT.jar --server.port=80 &
EOF

echo "[*] Waiting 20 seconds for app to start..."
sleep 20

# Test app on port 80
echo "[*] Checking if app is reachable at http://$IP ..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://$IP)

if [[ "$STATUS" == "200" ]]; then
  echo "[+] App is reachable!"
else
  echo "[!] App not reachable. HTTP Status: $STATUS"
fi

# Schedule shutdown
echo "[*] Instance will be stopped after $INSTANCE_DURATION seconds..."
sleep "$INSTANCE_DURATION"

aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "[+] Instance $INSTANCE_ID stopped to save cost."
