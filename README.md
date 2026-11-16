# SIS 3 — Reproducible AWS environment (Weeks 9–11)

Cloud Application Development — **SIS 3 (6 points)**. Three CloudFormation stacks are intentional: one shared **network**, one shared **ECR registry**, and one **application** stack per environment/copy. All AWS resources are declared in the templates. No AWS Console creation steps are required.

## Architecture

`Browser → HTTP ALB:80 → ECS Fargate (Python API:8080) → SNS OrderPlaced → SQS → Lambda consumer → DynamoDB`

Failed events are retried and moved to an SQS **DLQ**. A conditional DynamoDB `PutItem` makes processing **idempotent on `orderId`**. AWS logs are collected in **CloudWatch** with 7-day retention. `POST /orders` publishes the event via an ECS **task role**, not via static AWS credentials. ECS **execution role** is separate and allows ECR pulls/logging.

## Prerequisites

- AWS CLI v2 with an authenticated AWS profile (default `adi-2`, region `eu-central-1`).
- Docker Engine and Docker Buildx running.
- IAM permissions to create/describe/delete VPC, subnets, routes, security groups, ECR, ECS, ELBv2, SNS, SQS, Lambda, DynamoDB, Logs, CloudFormation, IAM roles and policies; permission `iam:PassRole` for roles created by the app stack. `CAPABILITY_IAM` is acknowledged by the script. Account policies/quotas might require instructor or administrator approval.
- At least **two availability zones** in the chosen AWS region.
- No secrets or AWS access keys in templates, Docker image, or this repository. Configure AWS_PROFILE/credential chain locally.

## One-command deployment (from a clean checkout)

```bash
AWS_PROFILE=adi-2 AWS_DEFAULT_REGION=eu-central-1 bash deploy.sh sis3-dev dev
```

The single command previews each CloudFormation **change set** and asks for `YES` before execution. The script:
1. Creates shared network stack (VPC, 2 public subnets, IGW, routes) if absent.
2. Creates shared ECR stack (immutable tags, scan-on-push, lifecycle policy) if absent.
3. Builds the **linux/amd64** image, tags it by source-content hash, pushes if not yet present.
4. Creates application stack, including SNS/SQS/DLQ/Lambda/DynamoDB/ECS/ALB/IAM/logs.
5. Saves CloudFormation outputs and registered task-definition JSON under `evidence/`.

To demonstrate reproducibility **under a second stack name**, without console clicks and while retaining the original deployment:

```bash
AWS_PROFILE=adi-2 AWS_DEFAULT_REGION=eu-central-1 bash deploy.sh sis3-copy dev
```

Shared network and ECR stacks are reused, and the application stack creates a separate topic, queues, table, ECS cluster/service, ALB, roles and CloudWatch groups. The same immutable image is reused. Stacks have generated physical names and are safe to deploy side by side. Deploying a second ALB/service **incurs additional charges**.

To update a stack, edit the template and run the same deploy command; review any `Modify / Replacement: True` or `Remove` in the change set before confirming.

## Validation and test

```bash
python3 -m unittest discover -s tests -v
aws cloudformation validate-template --template-body file://templates/network.yaml
aws cloudformation validate-template --template-body file://templates/registry.yaml
aws cloudformation validate-template --template-body file://templates/application.yaml
```

**Important:** `validate-template` checks basic syntax but not all resource property semantics. Install `cfn-lint` (`python3 -m pip install cfn-lint`, preferably in a virtual environment) and run:

```bash
cfn-lint templates/*.yaml
```

After deployment and service stabilization:

```bash
bash verify.sh sis3-dev
```

Check: CloudFormation `CREATE_COMPLETE`, ECS `Running=Desired`, target group `healthy`, `GET /health → 200`, two `POST /orders` calls with the **same** `orderId` (both accepted but only **one** row written), Lambda logs `PROCESSED` and `DUPLICATE_SKIPPED`.

To test DLQ, publish a forced-error event through SNS using the example printed by `verify.sh`; inspect Lambda retry logs and the DLQ after the 5 receives. **Do not claim this passed until AWS logs and DLQ count confirm it.**

## Key configuration (Week 9 slide 22)

| Setting | Code |
| --- | --- |
| Lambda timeout | 10 s |
| Source SQS visibility | 70 s (≥ 6 × 10) |
| maxReceiveCount | 5 |
| Main queue retention | 4 days |
| DLQ retention | 14 days |
| Event source batch size | 5 |
| ReportBatchItemFailures | Enabled |
| Maximum concurrency | 2 |

## Environments and security

`Env=dev/staging/prod` sets CPU/memory/desired count by CloudFormation `Mappings`; all environments use the **same** template. For dev, task size `256 CPU / 512 MiB`, count 1; staging/prod use `512 / 1024`, count 2.

This **lab-only** design runs Fargate tasks with public IPs in public subnets to avoid NAT Gateway cost. **Ingress 8080 is allowed only from ALB security group**, public ingress to ALB HTTP port 80. Not a production TLS/private-subnet architecture. For production, use private subnets + NAT/endpoints, HTTPS/ACM and tighter access controls. Public IPv4, ALB, and running Fargate tasks are billed; do not leave deployed after your demo.

DynamoDB is intentionally **ephemeral** for this reproducibility exercise. CloudFormation deletion **removes its data**. Real production systems need backups and retain policies. ECR shared-stack deletion is configured to delete its images (`EmptyOnDelete: true`) after all app stacks are deleted.

## Evidence to submit

1. Git repository URL and these templates (`network.yaml`, `registry.yaml`, `application.yaml`), README, deploy script.
2. AWS CloudFormation stack `CREATE_COMPLETE` and second `sis3-copy` stack from clean checkout.
3. Image in ECR with immutable tag + lifecycle policy.
4. ECS service running; ALB target `healthy`; service URL (`/health` returns 200).
5. SNS topic, SQS + DLQ, Lambda + DynamoDB idempotency logs and duplicate-event proof.
6. CloudWatch log groups with retention; two distinct ECS roles in template.
7. Screenshots of **change set review** and cleanup (when completed).

## Cleanup — delete what was created, not old Practice 3–6 resources

```bash
bash cleanup.sh sis3-copy
bash cleanup.sh sis3-dev
bash cleanup-shared.sh
```

Do **not** delete shared stacks while either app copy exists. These scripts never target your previous Practice 6 stack, existing VPC, or unrelated ECR repository. Afterward verify no SIS3 Fargate tasks, ALBs, NAT gateways, log groups, public IPs or retained resources remain.

## Troubleshooting

- `AccessDenied` during stack creation: identify the **first** failed resource in CloudFormation Events. Add narrowly scoped IAM permission to the deployment role, then fix **the template**, not the resource in AWS Console.
- `ROLLBACK_COMPLETE`: delete that failed app stack and redeploy.
- `CannotPullContainerError`: check architecture X86_64 and public subnet routes/public IP and execution role permissions.
- ECS tasks running but ALB `unhealthy`: check target type `ip`, port 8080, SG source from ALB, path `/health`.
- If the app stack is already deployed and the code changes, the hash-based image tag changes, which creates a new ECS task definition. Always review its change set.

## Sources

- Instructor: *Week 11 — Infrastructure as Code*, especially slides 9–12, 17, 24, 27–29 and 32–33; Week 9 slide 22; Week 10 on Docker/ECR/ECS.
- Wittig & Wittig, *Amazon Web Services in Action*, 3rd ed., chapter 4 **Programming Your Infrastructure** (assigned reading; not included in this project).
- AWS CloudFormation, ECS, Lambda, ECR official documentation.
