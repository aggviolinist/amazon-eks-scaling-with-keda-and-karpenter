#!/usr/bin/env bash
set -euo pipefail
#******************
# Clean Deployment
#******************
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR/deployment/environmentVariables.sh"
echo "${RED}******************************************************"
echo "${RED}**************CLEANUP START***************************"
echo "${RED}******************************************************"
echo "${CYAN}Load variables"

echo "${RED}Find all CFN stack names which has cluster name"
STACKS=$(aws cloudformation describe-stacks --region "${AWS_REGION}" --output text --query 'Stacks[?StackName!=`null`]|[?contains(StackName, `'${CLUSTER_NAME}'`) == `true`].StackName')
for stack in $STACKS; do
  if [ -z "${stack:-}" ]; then
    continue
  fi

  echo "${RED}Deleting stacks : ${stack}"
  if [[ "$stack" == *nodegroup* ]]; then
    echo "Node group"
  else
    echo "other stack"
  fi

  TERM_PROTECT=$(aws cloudformation describe-stacks --stack-name "$stack" --region "${AWS_REGION}" --output text --query 'Stacks[0].EnableTerminationProtection') || true
  if [ "$TERM_PROTECT" = "True" ]; then
    echo "${YELLOW}Disabling termination protection for stack: ${stack}"
    aws cloudformation update-termination-protection --stack-name "$stack" --region "${AWS_REGION}" --no-enable-termination-protection
  fi
   STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$stack" --region "${AWS_REGION}" --output text --query 'Stacks[0].StackStatus') || true
   
  if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
    aws cloudformation delete-stack --stack-name "$stack" --region "${AWS_REGION}" --deletion-mode FORCE_DELETE_STACK
  else
    aws cloudformation delete-stack --stack-name "$stack" --region "${AWS_REGION}"
  fi
  aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "$stack"
  #aws cloudformation delete-stack --stack-name "$stack" --region "${AWS_REGION}" --deletion-mode FORCE_DELETE_STACK
  #aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "$stack"
done
# ── START KARPENTER ROLE CLEANUP ───────────────────────────────────

# Clean up orphaned Karpenter IAM Role (may survive CFN stack deletion)
echo "${RED}Deleting orphaned Karpenter IAM roles if they exist"

KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

if aws iam get-role --role-name "$KARPENTER_NODE_ROLE" &>/dev/null; then
  echo "${YELLOW}Found ${KARPENTER_NODE_ROLE}, cleaning up..."

  # Remove from instance profiles
  # for profile in $(aws iam list-instance-profiles-for-role \
  #   --role-name "$KARPENTER_NODE_ROLE" \
  #   --query 'InstanceProfiles[].InstanceProfileName' \
  #   --output text); do

  INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role \
  --role-name "$KARPENTER_NODE_ROLE" \
  --query 'InstanceProfiles[].InstanceProfileName' \
  --output text)

  for profile in $INSTANCE_PROFILES; do
    [ -z "$profile" ] && continue
    echo "${YELLOW}Removing role from instance profile: ${profile}"
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$profile" \
      --role-name "$KARPENTER_NODE_ROLE" || true
    aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
  done

  # Detach managed policies
  for policy_arn in $(aws iam list-attached-role-policies \
    --role-name "$KARPENTER_NODE_ROLE" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text); do
    [ -z "$policy_arn" ] && continue
    echo "${YELLOW}Detaching policy: ${policy_arn}"
    aws iam detach-role-policy \
      --role-name "$KARPENTER_NODE_ROLE" \
      --policy-arn "$policy_arn"
  done

  # Delete inline policies
  for inline_policy in $(aws iam list-role-policies \
    --role-name "$KARPENTER_NODE_ROLE" \
    --query 'PolicyNames[]' \
    --output text); do
    [ -z "$inline_policy" ] && continue
    echo "${YELLOW}Deleting inline policy: ${inline_policy}"
    aws iam delete-role-policy \
      --role-name "$KARPENTER_NODE_ROLE" \
      --policy-name "$inline_policy"
  done

  aws iam delete-role --role-name "$KARPENTER_NODE_ROLE"
  echo "${GREEN}Deleted ${KARPENTER_NODE_ROLE}"
else
  echo "${GREEN}${KARPENTER_NODE_ROLE} does not exist, skipping"
fi
# ── END KARPENTER ROLE CLEANUP ───────────────────────────────────

# Delete IAM Roles
echo "${RED}Deleting Role"

for policy in $(aws iam list-attached-role-policies --role-name ${IAM_KEDA_ROLE} --output text --query 'AttachedPolicies[*].PolicyName')
do
echo "${RED}Detach policy :${policy} from role :${IAM_KEDA_ROLE}"
aws iam detach-role-policy --role-name ${IAM_KEDA_ROLE} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${policy}

echo "${RED}Deleting policy :${policy}"
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${policy}
done

echo "${RED}Deleting role : ${IAM_KEDA_ROLE}"
aws iam delete-role --role-name ${IAM_KEDA_ROLE}

echo "${RED}Delete IAM policies, if missed earlier"
# Delete IAM policies
#Deleting the policies if missed during role deletion process

isSQSPolicyExist=$(aws iam list-policies --output text --query 'Policies[?PolicyName==`'${IAM_KEDA_SQS_POLICY}'`].PolicyName')
echo $isSQSPolicyExist
if [ ! -z $isSQSPolicyExist ];then
echo "${RED}Deleting policy :"$IAM_KEDA_SQS_POLICY
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_KEDA_SQS_POLICY}
else
echo "policy ${IAM_KEDA_SQS_POLICY} already deleted"
fi

isDynamoPolicyExist=$(aws iam list-policies --output text --query 'Policies[?PolicyName==`'${IAM_KEDA_DYNAMO_POLICY}'`].PolicyName')
echo $isDynamoPolicyExist
if [ ! -z $isDynamoPolicyExist ];then
echo "${RED}Deleting policy :"$IAM_KEDA_DYNAMO_POLICY
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_KEDA_DYNAMO_POLICY}
else
echo "policy ${IAM_KEDA_DYNAMO_POLICY} already deleted"
fi


SQS_URL=$(aws sqs get-queue-url --queue-name ${SQS_QUEUE_NAME} --output text)
if [ ! -z $SQS_URL ];then
echo "${RED}Deleting SQS :"$SQS_URL
aws sqs delete-queue --queue-url $SQS_URL --region ${AWS_REGION}

fi

DYNAMO_TABLE=$(aws dynamodb describe-table  --table-name ${DYNAMODB_TABLE} --region ${AWS_REGION} --query 'Table.TableName' --output text)
if [ ! -z $DYNAMO_TABLE ];then
echo "${RED}Deleting DynamoTable :"$DYNAMO_TABLE
RESPONSE=$(aws dynamodb delete-table --table-name $DYNAMO_TABLE --region ${AWS_REGION} --output text)
echo $RESPONSE
fi
#******************
# Clean Completed
#******************
echo "${GREEN}******************************************************"
echo "${GREEN}**************CLEANUP COMPLETE************************"
echo "${GREEN}******************************************************"
