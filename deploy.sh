#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE="${AWS_PROFILE:-adi-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
export AWS_PAGER=""
APP_STACK="${1:-sis3-dev}"
ENV_NAME="${2:-dev}"
NETWORK_STACK="${NETWORK_STACK:-sis3-shared-network}"
REGISTRY_STACK="${REGISTRY_STACK:-sis3-shared-registry}"
if [[ ! "$APP_STACK" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,90}$ ]]; then echo 'Invalid stack name'; exit 1; fi
case "$ENV_NAME" in dev|staging|prod) ;; *) echo 'Environment must be dev, staging, prod'; exit 1;; esac
for cmd in aws docker shasum python3; do command -v "$cmd" >/dev/null || { echo "Missing tool: $cmd"; exit 1; }; done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT  Region: $AWS_DEFAULT_REGION  App stack: $APP_STACK  Env: $ENV_NAME"
echo "IMPORTANT: Running Fargate, ALB and public IPv4 resources incur AWS charges."

exists() {
  local err
  if err=$(aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    if [[ "$err" == *'ROLLBACK_COMPLETE'* || "$err" == *'DELETE_FAILED'* ]]; then echo "Stack $1 is in $err; inspect events before continuing" >&2; exit 1; fi
    return 0
  fi
  if [[ "$err" == *ValidationError* && "$err" == *'does not exist'* ]]; then return 1; fi
  echo "Failed reading stack $1: $err" >&2
  exit 1
}
output() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text; }

apply_template() {
  local name="$1" file="$2"; shift 2
  local mode='CREATE'
  if exists "$name"; then mode='UPDATE'; fi
  local change="sis3-$(date +%s)-$RANDOM" detail
  echo "=== Preview $mode: $name ==="
  aws cloudformation create-change-set --stack-name "$name" --change-set-name "$change" \
    --change-set-type "$mode" --template-body "file://$file" --capabilities CAPABILITY_IAM --role-arn "arn:aws:iam::656559337311:role/SIS3-CloudFormation-ServiceRole" \
    "$@" --query Id --output text >/dev/null
  if ! aws cloudformation wait change-set-create-complete --stack-name "$name" --change-set-name "$change"; then
    detail=$(aws cloudformation describe-change-set --stack-name "$name" --change-set-name "$change" --query StatusReason --output text)
    if [[ "$detail" == *"didn't contain changes"* || "$detail" == *'No updates are to be performed'* ]]; then
      echo "No changes in $name"
      aws cloudformation delete-change-set --stack-name "$name" --change-set-name "$change"
      return 0
    fi
    echo "Change set failed: $detail" >&2; exit 1
  fi
  aws cloudformation describe-change-set --stack-name "$name" --change-set-name "$change" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,Replacement]' --output table
  if [[ "${AUTO_APPROVE:-0}" != 1 ]]; then
    read -r -p "Execute this change set for $name? Type YES: " answer
    if [[ "$answer" != YES ]]; then echo "Not executed. Review or delete change set $change"; exit 1; fi
  fi
  aws cloudformation execute-change-set --stack-name "$name" --change-set-name "$change"
  if [[ "$mode" == CREATE ]]; then
    aws cloudformation wait stack-create-complete --stack-name "$name"
  else
    aws cloudformation wait stack-update-complete --stack-name "$name"
  fi
  echo "=== $name: completed ==="
}

if ! exists "$NETWORK_STACK"; then
  apply_template "$NETWORK_STACK" templates/network.yaml
else echo "Reusing shared network stack: $NETWORK_STACK"; fi
if ! exists "$REGISTRY_STACK"; then
  apply_template "$REGISTRY_STACK" templates/registry.yaml
else echo "Reusing shared ECR registry stack: $REGISTRY_STACK"; fi

VPC_ID=$(output "$NETWORK_STACK" VpcId)
SUBNET_A=$(output "$NETWORK_STACK" SubnetA)
SUBNET_B=$(output "$NETWORK_STACK" SubnetB)
REPOSITORY_URI=$(output "$REGISTRY_STACK" RepositoryUri)
REPOSITORY_NAME=$(output "$REGISTRY_STACK" RepositoryName)
TAG="code-$(cat api/Dockerfile api/requirements.txt api/app.py | shasum -a 256 | cut -c1-12)"
IMAGE_URI="$REPOSITORY_URI:$TAG"
if aws ecr describe-images --repository-name "$REPOSITORY_NAME" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  echo "Reusing immutable ECR image: $IMAGE_URI"
else
  echo "=== Building and pushing image $TAG ==="
  REGISTRY="${REPOSITORY_URI%%/*}"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
  docker buildx build --platform linux/amd64 --load -t "$IMAGE_URI" ./api
  docker push "$IMAGE_URI"
fi

apply_template "$APP_STACK" templates/application.yaml --parameters \
  "ParameterKey=Env,ParameterValue=$ENV_NAME" \
  "ParameterKey=VpcId,ParameterValue=$VPC_ID" \
  "ParameterKey=PublicSubnetA,ParameterValue=$SUBNET_A" \
  "ParameterKey=PublicSubnetB,ParameterValue=$SUBNET_B" \
  "ParameterKey=ImageUri,ParameterValue=$IMAGE_URI"

mkdir -p evidence
aws cloudformation describe-stacks --stack-name "$APP_STACK" --query 'Stacks[0].Outputs' > "evidence/${APP_STACK}-outputs.json"
aws ecs describe-task-definition --task-definition "$(output "$APP_STACK" TaskDefinitionArn)" \
  --query taskDefinition > "evidence/${APP_STACK}-task-definition.json"
echo "=== READY ==="
echo "Service URL: $(output "$APP_STACK" ServiceUrl)"
echo "Health URL:  $(output "$APP_STACK" HealthUrl)"
echo "Image URI:   $IMAGE_URI"
echo "Evidence:    evidence/${APP_STACK}-outputs.json and task-definition.json"
echo "Next: bash verify.sh $APP_STACK"
