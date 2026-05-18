#!/usr/bin/env bash
set -euo pipefail
#*************************
# Deploy Karpenter
#*************************
## SWITCH CLUSTER CONTEXT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR/../environmentVariables.sh"
GREEN="${GREEN:-}"
RED="${RED:-}"
YELLOW="${YELLOW:-}"
CYAN="${CYAN:-}"
BLUE="${BLUE:-}"
NC="${NC:-}"
echo "${GREEN}=========================="
echo "${GREEN}Installing karpenter"
echo "${GREEN}=========================="

echo "${RED}Casesenstive ${BLUE} Press Y = Proceed \n or \n N = Cancel (change context 'kubectl config use-context {context name you can check using kubectl config view}' and run script)"
read user_input
#kubectl config use-context akaasif-Isengard@${CLUSTER_NAME}.${AWS_REGION}.eksctl.io
#kubectl config current-context
#kubectl config use-context akaasif-Isengard@eks-karpenter-scale.us-west-1.eksctl.io

Entry='Y'
if [[ "$user_input" == *"$Entry"* ]]; then

if [ -z $CLUSTER_NAME ] || [ -z $KARPENTER_VERSION ] || [ -z $AWS_REGION ] || [ -z $ACCOUNT_ID ] || [ -z $TEMPOUT ];then
echo "${RED}Update values & Run environmentVariables.sh file"
exit 1;
else 
echo "${GREEN}**Installing karpenter**"
# If you have login with docker in shell  execute below first
docker logout public.ecr.aws

#Create the KarpenterNode IAM Role
echo "${GREEN}Create the KarpenterNode IAM Role"

curl -fsSL https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml  > $TEMPOUT \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region ${AWS_REGION}


#grant access to instances using the profile to connect to the cluster. This command adds the Karpenter node role to your aws-auth configmap, 
#allowing nodes with this role to connect to the cluster.

eksctl create iamidentitymapping \
  --username system:node:{{EC2PrivateDNSName}} \
  --cluster  ${CLUSTER_NAME} \
  --arn "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --group system:bootstrappers \
  --group system:nodes 

echo "Verify auth Map"
kubectl describe configmap -n kube-system aws-auth

# Create KarpenterController IAM Role
echo "Create KarpenterController IAM Role"

eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --approve

#Karpenter requires permissions like launching instances. This will create an AWS IAM Role, Kubernetes service account, 
#and associate them using IAM Roles for Service Accounts (IRSA)
echo "Map AWS IAM Role  Kubernetes service account"

eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
  --role-name "Karpenter-${CLUSTER_NAME}" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --role-only \
  --approve

export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/Karpenter-${CLUSTER_NAME}"

#Create the EC2 Spot Linked Role
echo "Create the EC2 Spot Linked Role"
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com 2> /dev/null || echo 'Already exist'

#Helm Install Karpenter
echo "Helm Install Karpenter"
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.endpoint" --output text)"

helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --namespace karpenter --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set settings.aws.clusterName=${CLUSTER_NAME} \
  --set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --set settings.aws.interruptionQueueName=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

#deploy Provisioner & AWSNodeTemplate 
echo "Providers & AWSNodeTemplate "
cat <<EOF | envsubst | kubectl apply -f -
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: NotIn
          values: ["spot"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m5.xlarge", "m5.2xlarge"]
      nodeClassRef:
        name: default
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h # 30 * 24h = 720h
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2 # Amazon Linux 2
  role: "KarpenterNodeRole-${CLUSTER_NAME}" # replace with your cluster name
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}" # replace with your cluster name
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}" # replace with your cluster name
EOF




echo "${GREEN}=========================="
echo "${GREEN}Karpenter Completed"
echo "${GREEN}=========================="
fi

fi

# #!/bin/bash
# #*************************
# # Deploy KEDA
# #*************************
# echo "${GREEN}=========================="
# echo "${GREEN}Deploy KEDA"
# echo "${GREEN}=========================="
# source ./deployment/environmentVariables.sh

# echo "${RED} Keda will be deployed on cluster $(kubectl config current-context) \n ${RED}Casesenstive ${BLUE}Press Y = Proceed or N = Cancel (change context and run script)"
# read user_input

# Entry='Y'
# if [[ "$user_input" == *"$Entry"* ]]; then
# OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

# echo "${CYAN}This deployment will target AWS SQS trigger for keda"

# if [ -z $CLUSTER_NAME ] ||  [ -z $AWS_REGION ] || [ -z $IAM_KEDA_SQS_POLICY ] || [ -z $IAM_KEDA_DYNAMO_POLICY ] || [ -z $ACCOUNT_ID ] || [ -z $TEMPOUT ] || [ -z $OIDC_PROVIDER ] || [ -z $IAM_KEDA_ROLE ] || [ -z $SERVICE_ACCOUNT ] || [ -z $NAMESPACE ] || [ -z $SQS_TARGET_NAMESPACE ] || [ -z $SQS_TARGET_DEPLOYMENT ] || [ -z $SQS_QUEUE_URL ];then
# echo "${RED}Update values & Run environmentVariables.sh file"
# exit 1;
# else

# echo "====Installing keda====="
# #Deploy SQS access policy
# echo "${CYAN}Deploy SQS access policy"
# SQS_POLICY=$(aws iam create-policy --policy-name ${IAM_KEDA_SQS_POLICY} --policy-document file://deployment/keda/sqsPolicy.json --output text --query Policy.Arn)
# echo "${GREEN}ARN : ${SQS_POLICY}"
# #Deploy Dynamo access policy
# # This is needed in context to our sample application, its not a KEDA requirement 
# echo "${CYAN}Deploy Dynamo access policy. !!This is needed in context to our sample application, its not a KEDA requirement!!"
# DYNAMO_POLICY=$(aws iam create-policy --policy-name ${IAM_KEDA_DYNAMO_POLICY} --policy-document file://deployment/keda/dynamoPolicy.json  --output text --query Policy.Arn)
# echo "${GREEN}ARN : ${DYNAMO_POLICY}"


# OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
# echo "${CYAN}Create a trusted relation in role for STS"
# #Create Role Trusted Relation 
# cat >./deployment/keda/trust-relationship.json <<EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Principal": {
#         "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
#       },
#       "Action": "sts:AssumeRoleWithWebIdentity",
#       "Condition": {
#         "StringEquals": {
#           "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
#           "${OIDC_PROVIDER}:sub": [
#             "system:serviceaccount:keda:keda-operator",
#             "system:serviceaccount:${SQS_TARGET_NAMESPACE}:${SERVICE_ACCOUNT}"
#           ]
#         }
#       }
#     }
#   ]
# }
# EOF

# # Create role for KedaOperator to access SQS for poling and generate STS for operator to connect with AWS resources
# echo "${GREEN}Create role for KedaOperator to access SQS for poling and generate STS for operator to connect with AWS resources"

# KEDA_ROLE=$(aws iam create-role --role-name ${IAM_KEDA_ROLE}  --assume-role-policy-document file://deployment/keda/trust-relationship.json --description "keda role-description" --output text)
# echo "KEDA ROLE : ${KEDA_ROLE}"
# echo "Attach SQS polciy to Keda role"
# aws iam attach-role-policy --role-name ${IAM_KEDA_ROLE} --policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_KEDA_SQS_POLICY}
# echo "Attach dynamo polciy to Keda role"
# aws iam attach-role-policy --role-name ${IAM_KEDA_ROLE} --policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_KEDA_DYNAMO_POLICY}

# ATTACH_POLICY_LIST=$(aws iam list-attached-role-policies --role-name ${IAM_KEDA_ROLE} --output text)
# echo "${GREEN}ATTACH_POLICY_LIST : ${ATTACH_POLICY_LIST}"
# # Add a new  Kubernetes service account and attach keda-role
# echo "Create a K8s service account and attach role"
# kubectl create namespace keda-test
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: ${SERVICE_ACCOUNT}
#   namespace: keda-test
# EOF
# echo "${CYAN}Map k8s service account to IAM role"
# kubectl annotate serviceaccount -n keda-test keda-service-account eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/${IAM_KEDA_ROLE}



# #Deploy KEDA value
# echo "=== Deploy KEDA VALUES ==="
# ./deployment/keda/values.sh
# #Install KEDA with helm 
# echo "${CYAN}Install Keda using helm" 
# helm repo add kedacore https://kedacore.github.io/charts
# helm repo update
# kubectl create namespace keda
# helm install keda kedacore/keda --values ./deployment/keda/value.yaml --namespace keda

# echo "${CYAN}=== Deploy KEDA Scaleobject ==="
# ./deployment/keda/keda-scaleobject.sh
# kubectl apply -f ./deployment/keda/kedaScaleObject.yaml

# # deploy the application to read queue
# echo "${CYAN}Deploy application to read SQS"
# #kubectl apply -f ./deployment/app/keda-python-app.yaml

# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: sqs-app
#   namespace: keda-test
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: sqs-reader
#   template:
#     metadata:
#       labels:
#         app: sqs-reader
#     spec:
#       serviceAccountName: keda-service-account
#       containers:
#       - name: sqs-pull-app
#         image: khanasif1/sqs-reader:v0.12
#         imagePullPolicy: Always
#         env:
#         - name: SQS_QUEUE_URL
#           value: ${SQS_QUEUE_URL}
#         - name: DYNAMODB_TABLE
#           value: ${DYNAMODB_TABLE}
#         - name: AWS_REGION
#           value: ${AWS_REGION}
#         resources:
#           requests:
#             memory: "32Mi"
#             cpu: "125m"
#           limits:
#             memory: "128Mi"
#             cpu: "500m"
# EOF


# # Clean temporary config file created by script, to save from future conflicts
# echo "${RED}Deleting files value.yaml, kedaScaleObject.yaml, trust-relationship.json"
# rm -f ./deployment/keda/value.yaml
# rm -f ./deployment/keda/kedaScaleObject.yaml
# rm -f ./deployment/keda/trust-relationship.json

# echo "${GREEN}=========================="
# echo "${GREEN}KEDA Completed"
# echo "${GREEN}=========================="
# fi
# fi