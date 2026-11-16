#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-adi-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
export AWS_PAGER=""
STACK="${1:-sis3-dev}"
echo "Deleting application stack: $STACK (including ALB, Fargate, SNS, SQS, DynamoDB data, IAM roles and logs)."
read -r -p 'Type DELETE to confirm: ' answer
[[ "$answer" == DELETE ]] || exit 1
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"
echo "Application stack $STACK deleted. Shared network and ECR are kept for second-copy testing."
echo 'To delete shared resources after removing ALL app stacks, use: bash cleanup-shared.sh'
