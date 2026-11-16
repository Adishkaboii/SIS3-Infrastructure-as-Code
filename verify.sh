#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PROFILE="${AWS_PROFILE:-adi-2}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
export AWS_PAGER=""
APP_STACK="${1:-sis3-dev}"
getout() { aws cloudformation describe-stacks --stack-name "$APP_STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text; }
URL=$(getout ServiceUrl)
TG=$(getout TargetGroupArn)
CLUSTER=$(getout ClusterName)
SERVICE=$(getout ServiceName)
TOPIC=$(getout OrdersTopicArn)
TABLE=$(getout OrdersTableName)
DLQ=$(getout DLQUrl)
echo '=== Stack ==='
aws cloudformation describe-stacks --stack-name "$APP_STACK" --query 'Stacks[0].[StackName,StackStatus]' --output table
echo '=== Fargate service ==='
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table
echo '=== ALB target health ==='
aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].{Port:Target.Port,State:TargetHealth.State,Target:Target.Id}' --output table
echo '=== HTTP health ==='
curl --noproxy '*' --fail-with-body --max-time 20 -i "$URL/health"
echo
echo '=== POST OrderPlaced twice: expect consumer to process once ==='
ORDER="SIS3-$(date +%s)"
for i in 1 2; do curl --noproxy '*' --fail-with-body --max-time 20 -sS -i -H 'Content-Type: application/json' -d "{\"orderId\":\"$ORDER\"}" "$URL/orders"; echo; done
printf 'Published orderId=%s. Check Lambda logs for PROCESSED and DUPLICATE_SKIPPED.\n' "$ORDER"
echo '=== Source SQS and DLQ details ==='
aws sqs get-queue-attributes --queue-url "$(getout QueueUrl)" --attribute-names VisibilityTimeout MessageRetentionPeriod RedrivePolicy --output json
aws sqs get-queue-attributes --queue-url "$DLQ" --attribute-names MessageRetentionPeriod ApproximateNumberOfMessages --output json
printf 'After messages are processed, verify the row with:\naws dynamodb get-item --table-name "%s" --key '\''{"orderId":{"S":"%s"}}'\''\n' "$TABLE" "$ORDER"
printf 'For DLQ demonstration: aws sns publish --topic-arn "%s" --message '\''{"eventType":"OrderPlaced","orderId":"SIS3-FAIL","forceFail":true}'\''\n' "$TOPIC"
echo 'Failure message may need several minutes for 5 receives before entering DLQ.'
