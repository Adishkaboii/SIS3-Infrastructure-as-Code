#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-adi-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
export AWS_PAGER=""
NETWORK="${NETWORK_STACK:-sis3-shared-network}"
REGISTRY="${REGISTRY_STACK:-sis3-shared-registry}"
echo "This destroys shared stacks $REGISTRY and $NETWORK. Do this ONLY after ALL SIS3 app stacks are deleted."
read -r -p 'Type DELETE-SHARED to confirm: ' answer
[[ "$answer" == DELETE-SHARED ]] || exit 1
for stack in "$REGISTRY" "$NETWORK"; do
  aws cloudformation delete-stack --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --stack-name "$stack"
  echo "Deleted $stack"
done
