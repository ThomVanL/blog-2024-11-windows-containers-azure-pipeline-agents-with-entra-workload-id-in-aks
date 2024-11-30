# Log in to Azure
az login

# Alternatively uncomment line below to log in to a specific Azure DevOps organization 
# az devops login --organization

# Define Variables and Create a Resource Group
export SUBSCRIPTION="$(az account show --query id --output tsv)"
export RESOURCE_GROUP="myResourceGroup"
export LOCATION="eastus"
export AKS_CLUSTER_NAME="myAKSCluster"

az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

# Fetch the Latest Kubernetes Version
export AKS_VERSION="$(az aks get-versions --location $LOCATION -o tsv --query "values[0].version")"
az aks get-versions --location $LOCATION -o table

# Create the AKS Cluster
export AKS_CLUSTER_NAME="myAKSCluster"

az aks create --resource-group "${RESOURCE_GROUP}" \
              --name "${AKS_CLUSTER_NAME}" \
              --kubernetes-version "${AKS_VERSION}" \
               --os-sku Ubuntu \
               --node-vm-size Standard_D4_v5 \
               --node-count 1 \
               --enable-oidc-issuer \
               --enable-workload-identity \
               --generate-ssh-keys \
               --windows-admin-username "azure" \
               --windows-admin-password "replacePassword1234#"

# Add a Windows Node Pool
az aks nodepool add --resource-group "${RESOURCE_GROUP}" \
                    --cluster-name "${AKS_CLUSTER_NAME}" \
                    --name "win22" \
                    --os-sku "Windows2022" \
                    --mode "User"


# Configure Entra Workload Identity
export USER_ASSIGNED_IDENTITY_NAME="myIdentity"

az identity create --resource-group "${RESOURCE_GROUP}" \
  --name "${USER_ASSIGNED_IDENTITY_NAME}" \
  --location "${LOCATION}" \
  --subscription "${SUBSCRIPTION}"

export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group "${RESOURCE_GROUP}" --name "${USER_ASSIGNED_IDENTITY_NAME}" --query 'clientId' -o tsv)"

# Create a Kubernetes service account
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"

az aks get-credentials --name "${AKS_CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${USER_ASSIGNED_CLIENT_ID}"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${SERVICE_ACCOUNT_NAMESPACE}"
EOF

# Link Kubernetes service account to federated identity credential.
export FEDERATED_IDENTITY_CREDENTIAL_NAME="myFedIdentity"
export AKS_OIDC_ISSUER="$(az aks show --name "${AKS_CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "oidcIssuerProfile.issuerUrl" -o tsv)"

az identity federated-credential create --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} \
  --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${AKS_OIDC_ISSUER}" \
  --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" \
  --audience "api://AzureADTokenExchange"

# Link your Azure Pipeline agents to the correct pool
export AZP_ORGANIZATION="DevOpsOrg"
export AZP_URL="https://dev.azure.com/${AZP_ORGANIZATION}"
export AZP_POOL="aks-windows-pool"

kubectl create configmap azdevops \
  --from-literal=AZP_URL="${AZP_URL}" \
  --from-literal=AZP_POOL="${AZP_POOL}"

# Set up Container Registry and access
export AKS_KUBELETIDENTITY_OBJECT_ID="$(az aks show --name "${AKS_CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "identityProfile.kubeletidentity.objectId" -o tsv)"
export ACR_NAME="mysweetregistry"

az acr create --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --sku "Standard"
export ACR_RESOURCE_ID="$(az acr show --name "${ACR_NAME}" --query "id" -o tsv)"

az role assignment create --role "Acrpull" \
--assignee-principal-type "ServicePrincipal" \
--assignee-object-id "${AKS_KUBELETIDENTITY_OBJECT_ID}" \
--scope "${ACR_RESOURCE_ID}"

# Build and push container image
docker build --tag "${ACR_NAME}.azurecr.io/azp-agent:windows" --file "./azp-agent-windows.dockerfile" .
az acr login --name "${ACR_NAME}"
docker push "${ACR_NAME}.azurecr.io/azp-agent:windows"

# Creating an ADO agent pool
az extension add --name azure-devops
az extension show --name azure-devops

# Create user entitlement give user-assigned managed identity a 'basic' Azure DevOps license
export USER_ASSIGNED_OBJECT_ID="$(az identity show --resource-group "${RESOURCE_GROUP}" --name "${USER_ASSIGNED_IDENTITY_NAME}" --query 'principalId' -o tsv)"

cat << EOF > serviceprincipalentitlements.json
{
    "accessLevel": {
        "accountLicenseType": "express"
    },
    "projectEntitlements": [],
    "servicePrincipal": {
        "displayName": "${USER_ASSIGNED_IDENTITY_NAME}",
        "originId": "${USER_ASSIGNED_OBJECT_ID}",
        "origin": "aad",
        "subjectKind": "servicePrincipal"
    }
}
EOF

export ADO_USER_ID="$(az devops invoke \
     --http-method POST \
     --organization "${AZP_URL}" \
     --area MemberEntitlementManagement \
     --resource ServicePrincipalEntitlements\
     --api-version 7.2-preview \
     --in-file serviceprincipalentitlements.json \
     --query "operationResult.result.id" \
     --output tsv)"

# Create the ADO agent pool
cat << EOF > pool.json
{
    "name": "${AZP_POOL}",
    "autoProvision": true
}
EOF

export AZP_AGENT_POOL_ID="$(az devops invoke \
     --http-method POST \
     --organization "${AZP_URL}" \
     --area distributedtask \
     --resource pools \
     --api-version 7.1 \
     --in-file pool.json \
     --query "id" \
     --output tsv)"

# Create ADO role assignment
# ⚠️ At time of writing there was a bug with this command, check blog post for workaround. 
cat << EOF > roleassignments.json
[
    {
        "userId": "${ADO_USER_ID}",
        "roleName": "Administrator"
    }
]
EOF

az devops invoke \
     --http-method PUT \
     --organization "${AZP_URL}" \
     --area securityroles \
     --resource roleassignments \
     --route-parameters scopeId="distributedtask.agentpoolrole" resourceId="${AZP_AGENT_POOL_ID}" \
     --api-version 7.2-preview \
     --in-file roleassignments.json

# Deploy Agent to K8s with deployment object 
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azdevops-deployment
  labels:
    app: azdevopsagent-windows
spec:
  replicas: 3
  selector:
    matchLabels:
      app: azdevopsagent-windows
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
        app: azdevopsagent-windows
    spec:
      serviceAccountName: workload-identity-sa
      containers:
        - name: azuredevopsagent
          image: "${ACR_NAME}.azurecr.io/azp-agent:windows"
          imagePullPolicy: Always
          env:
            - name: AZP_URL
              valueFrom:
                configMapKeyRef:
                  name: azdevops
                  key: AZP_URL
            - name: AZP_POOL
              valueFrom:
                configMapKeyRef:
                  name: azdevops
                  key: AZP_POOL
          resources:
            limits:
              memory: 1024Mi
              cpu: 500m
EOF


# Install KEDA using Helm
helm install keda kedacore/keda --namespace keda \
  --create-namespace \
  --set podIdentity.azureWorkload.enabled=true \
  --set podIdentity.azureWorkload.clientId="${USER_ASSIGNED_CLIENT_ID}"

# Add keda-operator K8s service account to the federated credential so it can access ADO 
az identity federated-credential create --name "keda-operator" \
  --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${AKS_OIDC_ISSUER}" \
  --subject "system:serviceaccount:keda:keda-operator" \
  --audience "api://AzureADTokenExchange"

# Create KEDA TriggerAuthentication
cat <<EOF | kubectl apply -f -
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: pipeline-trigger-auth
  namespace: default
spec:
  podIdentity:
    provider: azure-workload
EOF

# Create KEDA scaling rules by creating a ScaledObject 
cat <<EOF | kubectl apply -f -
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: azure-pipelines-scaledobject
  namespace: default
spec:
  scaleTargetRef:
    name: azdevops-deployment
  minReplicaCount: 1
  maxReplicaCount: 5
  triggers:
  - type: azure-pipelines
    metadata:
      poolName: "${AZP_POOL}"
      organizationURLFromEnv: "AZP_URL"
    authenticationRef:
      name: pipeline-trigger-auth
EOF