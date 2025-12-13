# Define log file path with timestamp and start logging
$LogFile = Join-Path $PSScriptRoot ("logs\Teardown-DevOps-Exercise_" + (Get-Date -Format 'dd-MM-yyyy_HH-mm-ss') + ".log")
Start-Transcript -Path $LogFile -Append


function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Alias("ForegroundColor")]
        [string]$Color = "White"
    )

    $timestamp = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
    Write-Host "$timestamp $Message" -ForegroundColor $Color
}


$awsAuthFile = Join-Path $PSScriptRoot "k8s\aws-auth.yaml"
$TrustPolicyFile = Join-Path $PSScriptRoot "iam/github-oidc-trust-policy.json"
$DeployPolicyFile = Join-Path $PSScriptRoot "iam/github-oidc-deploy-policy.json"
$Region = "il-central-1"
$roleName = "GitHubOIDCDeployRole"


function Ensure-Tool {
    param(
        [string]$ToolName,
        [scriptblock]$InstallAction
    )

    if (-not (Get-Command $ToolName -ErrorAction SilentlyContinue)) {
        Write-Log "$ToolName not found. Installing..." -ForegroundColor Green
        & $InstallAction
    } else {
        Write-Log "$ToolName already installed." -ForegroundColor Yellow
    }
}

function Install-AwsCli {
    Write-Log "Installing AWS CLI v2..." -ForegroundColor Green
    $installer = "$env:TEMP\AWSCLIV2.msi"
    Invoke-WebRequest "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $installer
    Start-Process msiexec.exe -Wait -ArgumentList "/i $installer /qn"
}

function Install-Eksctl {
    Write-Log "Installing eksctl..." -ForegroundColor Green
    $zipPath = "$env:TEMP\eksctl.zip"
    Invoke-WebRequest "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip" -OutFile $zipPath
    Expand-Archive $zipPath -DestinationPath "$env:TEMP\eksctl" -Force
    Move-Item "$env:TEMP\eksctl\eksctl.exe" "C:\Program Files\eksctl\eksctl.exe" -Force
    $env:Path += ";C:\Program Files\eksctl"
}

function Install-Kubectl {
    Write-Log "Installing kubectl..." -ForegroundColor Green
    $kubectlPath = "C:\Program Files\kubectl"
    New-Item -ItemType Directory -Force -Path $kubectlPath | Out-Null
    Invoke-WebRequest "https://dl.k8s.io/release/v1.30.0/bin/windows/amd64/kubectl.exe" -OutFile "$kubectlPath\kubectl.exe"
    $env:Path += ";$kubectlPath"
}

function Install-Helm {
    Write-Log "Installing Helm..." -ForegroundColor Green
    $zipPath = "$env:TEMP\helm.zip"
    $extractPath = "$env:TEMP\helm"
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest "https://get.helm.sh/helm-v3.15.2-windows-amd64.zip" -OutFile $zipPath
    Expand-Archive $zipPath -DestinationPath $extractPath -Force

    $helmExe = Join-Path $extractPath "windows-amd64\helm.exe"
    if (Test-Path $helmExe) {
        $targetPath = "C:\Program Files\helm"
        New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
        Move-Item $helmExe "$targetPath\helm.exe" -Force
        $env:Path += ";$targetPath"
        Write-Log "Helm installed successfully." -ForegroundColor Green
    } else {
        Write-Log "helm.exe not found after extraction. Check archive contents." -ForegroundColor Red
    }
}


# --- Step 1: Ensure required tools --- #
Ensure-Tool "aws" { Install-AwsCli }
Ensure-Tool "eksctl" { Install-Eksctl }
Ensure-Tool "kubectl" { Install-Kubectl }
Ensure-Tool "helm" { Install-Helm }


# --- Step 2: Remove Helm releases --- #
if (helm status fluent-bit -n kube-system 2>$null) {
    Write-Log "Uninstalling fluent-bit..." -ForegroundColor Green
    helm uninstall fluent-bit -n kube-system
} else {
    Write-Log "fluent-bit not found, skipping." -ForegroundColor Yellow
}

if (helm status kube-prom -n monitoring 2>$null) {
    Write-Log "Uninstalling kube-prom..." -ForegroundColor Green
    helm uninstall kube-prom -n monitoring
} else {
    Write-Log "kube-prom not found, skipping." -ForegroundColor Yellow
}


# --- Step 3: Restore IAM JSON files from backup --- #
Write-Log "Restoring IAM JSON files from backup..." -ForegroundColor Green
Copy-Item "iam\policy-json-backup\github-oidc-trust-policy.json" $TrustPolicyFile -Force
Copy-Item "iam\policy-json-backup\github-oidc-deploy-policy.json" $DeployPolicyFile -Force
Write-Log "IAM JSON files restored from backup." -ForegroundColor Cyan


# --- Step 4: Remove Kubernetes manifests --- #
Write-Log "Deleting Kubernetes manifests..." -ForegroundColor Green
kubectl delete -f k8s 2>$null


# --- Step 5: Remove EKS cluster --- #
$clusterExists = aws eks describe-cluster --name devops-exercise --region il-central-1 2>$null
if ($clusterExists) {
    Write-Log "Deleting EKS cluster devops-exercise..." -ForegroundColor Green
    eksctl delete cluster --name devops-exercise --region il-central-1
} else {
    Write-Log "EKS cluster devops-exercise not found, skipping." -ForegroundColor Yellow
}


# --- Step 6: Remove ECR repository --- #
$repoExists = aws ecr describe-repositories --repository-names devops-exercise --region il-central-1 2>$null
if ($repoExists) {
    Write-Log "Deleting ECR repository devops-exercise..." -ForegroundColor Green
    aws ecr delete-repository --repository-name devops-exercise --region il-central-1 --force
} else {
    Write-Log "ECR repository devops-exercise not found, skipping." -ForegroundColor Yellow
}


# --- Step 7: Remove IAM role --- #
$roleExists = aws iam get-role --role-name $roleName --region $Region 2>$null

if ($roleExists) {
    Write-Log "Cleaning up IAM role $roleName..." -ForegroundColor Green

    # Delete inline policies
    $inlinePolicies = aws iam list-role-policies --role-name $roleName --output json | ConvertFrom-Json
    foreach ($policyName in $inlinePolicies.PolicyNames) {
        Write-Log "Deleting inline policy $policyName from role $roleName..." -ForegroundColor Green
        aws iam delete-role-policy --role-name $roleName --policy-name $policyName
    }

    # Detach managed policies
    $attachedPolicies = aws iam list-attached-role-policies --role-name $roleName --output json | ConvertFrom-Json
    foreach ($policy in $attachedPolicies.AttachedPolicies) {
        Write-Log "Detaching managed policy $($policy.PolicyName) from role $roleName..." -ForegroundColor Green
        aws iam detach-role-policy --role-name $roleName --policy-arn $policy.PolicyArn
    }

    # Delete the role
    Write-Log "Deleting IAM role $roleName..." -ForegroundColor Green
    aws iam delete-role --role-name $roleName
} else {
    Write-Log "IAM role $roleName not found, skipping." -ForegroundColor Yellow
}


# --- Step 8: Remove Security Group --- #
$VpcName = "DevopsExerciseVpc"
$sgName = "$VpcName-WebSG"
$sgId = (aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$sgName" `
    --query "SecurityGroups[0].GroupId" `
    --output text 2>$null)

if ($sgId -and $sgId -ne "None") {
    Write-Log "Deleting Security Group $sgName..." -ForegroundColor Green
    aws ec2 delete-security-group --group-id $sgId
} else {
    Write-Log "Security Group $sgName not found, skipping." -ForegroundColor Yellow
}


# --- Step 9: Remove Subnets --- #
$PublicSubnetName = "$VpcName-Public"
$PrivateSubnetName = "$VpcName-Private"

$publicSubnetId = (aws ec2 describe-subnets `
    --filters "Name=tag:Name,Values=$PublicSubnetName" `
    --query "Subnets[0].SubnetId" `
    --output text 2>$null)

$privateSubnetId = (aws ec2 describe-subnets `
    --filters "Name=tag:Name,Values=$PrivateSubnetName" `
    --query "Subnets[0].SubnetId" `
    --output text 2>$null)

if ($publicSubnetId -and $publicSubnetId -ne "None") {
    Write-Log "Deleting Public Subnet..." -ForegroundColor Green
    aws ec2 delete-subnet --subnet-id $publicSubnetId
} else {
    Write-Log "Public Subnet not found, skipping." -ForegroundColor Yellow
}

if ($privateSubnetId -and $privateSubnetId -ne "None") {
    Write-Log "Deleting Private Subnet..." -ForegroundColor Green
    aws ec2 delete-subnet --subnet-id $privateSubnetId
} else {
    Write-Log "Private Subnet not found, skipping." -ForegroundColor Yellow
}

# --- Step 10: Remove Internet Gateway(s) --- #
$VpcId = (aws ec2 describe-vpcs `
    --filters "Name=tag:Name,Values=$VpcName" `
    --query "Vpcs[0].VpcId" `
    --output text --region $Region 2>$null)

if (-not $VpcId -or $VpcId -eq "None") {
    Write-Log "No VPC with tag $VpcName found. Checking for any cluster VPC..." -ForegroundColor Yellow
    $VpcId = (aws eks describe-cluster --name $ClusterName --region $Region `
        --query "cluster.resourcesVpcConfig.vpcId" --output text 2>$null)
}

if ($VpcId -and $VpcId -ne "None") {
    $igwIds = (aws ec2 describe-internet-gateways `
        --filters "Name=attachment.vpc-id,Values=$VpcId" `
        --query "InternetGateways[].InternetGatewayId" `
        --output text --region $Region 2>$null)

    if ($igwIds -and $igwIds -ne "None") {
        foreach ($igwId in $igwIds -split "`n") {
            Write-Log "Detaching and deleting Internet Gateway $igwId..." -ForegroundColor Green
            aws ec2 detach-internet-gateway --internet-gateway-id $igwId --vpc-id $VpcId
            aws ec2 delete-internet-gateway --internet-gateway-id $igwId
        }
    } else {
        Write-Log "No Internet Gateway attached to VPC $VpcId, skipping." -ForegroundColor Yellow
    }
} else {
    Write-Log "VPC not found, skipping IGW deletion." -ForegroundColor Yellow
}


# --- Step 11: Remove VPC --- #
if ($VpcId -and $VpcId -ne "None") {
    Write-Log "Deleting VPC $VpcName..." -ForegroundColor Green
    aws ec2 delete-vpc --vpc-id $VpcId
} else {
    Write-Log "VPC $VpcName not found, skipping." -ForegroundColor Yellow
}


Write-Log "✅ DevOps Exercise teardown complete. All resources cleaned up." -ForegroundColor Green

Stop-Transcript