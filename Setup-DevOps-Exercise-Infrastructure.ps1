# Define log file path with timestamp and start logging
$LogFile = Join-Path $PSScriptRoot ("logs\Setup-DevOps-Exercise-Infrastructure_" + (Get-Date -Format 'dd-MM-yyyy_HH-mm-ss') + ".log")
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


# --- Variables --- #
$Region = "il-central-1"
$ClusterName = "devops-exercise"
$RepositoryName = "devops-exercise"
$RoleName = "GitHubOIDCDeployRole"
$VpcName = "DevopsExerciseVpc"
$TrustPolicyFile = Join-Path $PSScriptRoot "iam\github-oidc-trust-policy.json"
$DeployPolicyFile = Join-Path $PSScriptRoot "iam\github-oidc-deploy-policy.json"
$CiWorkflow = Join-Path $PSScriptRoot ".github\workflows\ci.yaml"
$CdWorkflow = Join-Path $PSScriptRoot ".github\workflows\cd.yaml"
$ClusterConfigFile = Join-Path $PSScriptRoot "eks\cluster.yaml"


# --- Ensure dedicated VPC exists --- #
$vpcExists = aws ec2 describe-vpcs `
    --filters "Name=tag:Name,Values=$VpcName" `
    --query "Vpcs[0].VpcId" `
    --output text 2>$null

if (-not $vpcExists -or $vpcExists -eq "None") {
    Write-Log "Creating dedicated VPC $VpcName..." -ForegroundColor Green
    $VpcId = (aws ec2 create-vpc `
        --cidr-block 10.0.0.0/16 `
        --query "Vpc.VpcId" `
        --output text).Trim()

    aws ec2 create-tags --resources $VpcId --tags Key=Name,Value=$VpcName
    aws ec2 modify-vpc-attribute --vpc-id $VpcId --enable-dns-hostnames
} else {
    Write-Log "Dedicated VPC $VpcName already exists." -ForegroundColor Yellow
    $VpcId = $vpcExists.Trim()
}

Write-Log "Using VPC ID: $VpcId" -ForegroundColor Cyan


# --- Create public and private subnets --- #
$PublicSubnetName = "$VpcName-Public"
$PrivateSubnetName = "$VpcName-Private"

# Public subnet
$publicSubnetId = (aws ec2 describe-subnets `
    --filters "Name=tag:Name,Values=$PublicSubnetName" `
    --query "Subnets[0].SubnetId" `
    --output text 2>$null)

if (-not $publicSubnetId -or $publicSubnetId -eq "None") {
    $publicSubnetId = (aws ec2 create-subnet `
        --vpc-id $VpcId `
        --cidr-block 10.0.1.0/24 `
        --availability-zone "${Region}a" `
        --query "Subnet.SubnetId" `
        --output text).Trim()
    aws ec2 create-tags --resources $publicSubnetId --tags Key=Name,Value=$PublicSubnetName
}

# Private subnet
$privateSubnetId = (aws ec2 describe-subnets `
    --filters "Name=tag:Name,Values=$PrivateSubnetName" `
    --query "Subnets[0].SubnetId" `
    --output text 2>$null)

if (-not $privateSubnetId -or $privateSubnetId -eq "None") {
    $privateSubnetId = (aws ec2 create-subnet `
        --vpc-id $VpcId `
        --cidr-block 10.0.2.0/24 `
        --availability-zone "${Region}a" `
        --query "Subnet.SubnetId" `
        --output text).Trim()
    aws ec2 create-tags --resources $privateSubnetId --tags Key=Name,Value=$PrivateSubnetName
}

Write-Log "Public Subnet: $publicSubnetId" -ForegroundColor Cyan
Write-Log "Private Subnet: $privateSubnetId" -ForegroundColor Cyan

# --- Security Group for web app --- #
$sgName = "$VpcName-WebSG"
$sgId = (aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$VpcId" "Name=group-name,Values=$sgName" `
    --query "SecurityGroups[0].GroupId" `
    --output text 2>$null)

if (-not $sgId -or $sgId -eq "None") {
    $sgId = (aws ec2 create-security-group `
        --group-name $sgName `
        --description "Web app SG allowing HTTP/HTTPS" `
        --vpc-id $VpcId `
        --query "GroupId" `
        --output text).Trim()

    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 443 --cidr 0.0.0.0/0
}

Write-Log "Web App Security Group: $sgId" -ForegroundColor Cyan


# --- Dynamic variable replacements --- #

# Get AWS Account ID
$AccountId = (aws sts get-caller-identity --query "Account" --output text)

# Get the remote origin URL
$remoteUrl = git config --get remote.origin.url

# Extract org/user and repo name
if ($remoteUrl -match "github.com[:/](.+?)/(.+?)(\.git)?$") {
    $GitHubOrg = $matches[1]
    $GitHubRepo = $matches[2]
}

# Patch Trust Policy JSON
$trustPolicy = Get-Content $TrustPolicyFile -Raw | ConvertFrom-Json
$trustPolicy.Statement[0].Principal.Federated = "arn:aws:iam::${AccountId}:oidc-provider/token.actions.githubusercontent.com"
$trustPolicy.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
$trustPolicy.Statement[0].Condition.StringLike."token.actions.githubusercontent.com:sub" = @(
    "repo:${GitHubOrg}/${GitHubRepo}:ref:refs/heads/main"
)
$json = $trustPolicy | ConvertTo-Json -Depth 20 -Compress
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TrustPolicyFile, $json, $utf8NoBom)


# Patch Deploy Policy JSON
$deployPolicy = Get-Content $DeployPolicyFile -Raw
$deployPolicy = $deployPolicy `
    -replace "<account-id>", $AccountId `
    -replace "<region>", $Region `
    -replace "<cluster-name>", $ClusterName
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($DeployPolicyFile, $deployPolicy, $utf8NoBom)


# Sanity check output
Write-Log "Patched IAM JSONs for account $AccountId and repo $GitHubOrg/$GitHubRepo" -ForegroundColor Cyan


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


# --- Step 2: Ensure ECR repository exists --- #
$repoExists = aws ecr describe-repositories --repository-names $RepositoryName --region $Region 2>$null
if (-not $repoExists) {
    Write-Log "Creating ECR repository $RepositoryName in $Region..." -ForegroundColor Green
    aws ecr create-repository --repository-name $RepositoryName --region $Region
} else {
    Write-Log "ECR repository $RepositoryName already exists." -ForegroundColor Yellow
}


# --- Step 3: Ensure EKS cluster exists --- #
$clusterExists = aws eks describe-cluster --name $ClusterName --region $Region 2>$null
if (-not $clusterExists) {
    Write-Log "Creating EKS cluster $ClusterName in $Region using eks\cluster.yaml..." -ForegroundColor Green
    eksctl create cluster -f $ClusterConfigFile
} else {
    Write-Log "EKS cluster $ClusterName already exists." -ForegroundColor Yellow
}


# --- Step 4: Validate cluster addons --- #
Write-Log "Validating and ensuring addons for cluster $ClusterName..." -ForegroundColor Green

# Desired addons list
$desiredAddons = @("vpc-cni", "kube-proxy", "coredns", "metrics-server", "aws-ebs-csi-driver")

# Get currently installed addons
$installedAddons = aws eks list-addons --cluster-name $ClusterName --region $Region | ConvertFrom-Json
$installedNames = $installedAddons.addons

foreach ($addon in $desiredAddons) {
    if ($installedNames -contains $addon) {
        $status = (aws eks describe-addon `
            --cluster-name $ClusterName `
            --region $Region `
            --addon-name $addon `
            --query "addon.status" `
            --output text)

        if ($status -ne "ACTIVE") {
            Write-Log "Addon $addon is $status. Attempting repair..." -ForegroundColor Yellow
            try {
                eksctl update addon --name $addon --cluster $ClusterName --region $Region --force
                Write-Log "Addon $addon updated successfully." -ForegroundColor Green
            } catch {
                Write-Log "Update failed for $addon. Recreating..." -ForegroundColor Red
                eksctl delete addon --name $addon --cluster $ClusterName --region $Region --force
                eksctl create addon --name $addon --cluster $ClusterName --region $Region --force
            }
        } else {
            Write-Log "Addon $addon is healthy (ACTIVE)." -ForegroundColor Cyan
        }
    } else {
        Write-Log "Addon $addon not installed. Installing..." -ForegroundColor Yellow
        eksctl create addon --name $addon --cluster $ClusterName --region $Region --force
    }
}

Write-Log "Addon validation complete." -ForegroundColor Green


# --- Step 5: Update kubeconfig --- #
Write-Log "Updating kubeconfig for cluster $ClusterName..." -ForegroundColor Green
aws eks update-kubeconfig --region $Region --name $ClusterName


# --- Step 6: Add required Helm charts and update cache --- #
Write-Log "Adding required Helm charts and updating cache..." -ForegroundColor Green
helm repo add eks https://aws.github.io/eks-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update


# --- Step 7: Install AWS Load Balancer Controller --- #
Write-Log "Installing AWS Load Balancer Controller..." -ForegroundColor Green
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
    -n kube-system `
    --set clusterName=$ClusterName `
    --set region=$Region `
    --set vpcId=$VpcId `
    --wait --timeout 20m --atomic


# --- Step 8: Install Prometheus/Grafana --- #
Write-Log "Installing Prometheus/Grafana (kube-prometheus-stack)..." -ForegroundColor Green
helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack `
    --namespace monitoring --create-namespace `
    --wait --timeout 20m --atomic


# --- Step 9: Install Fluent Bit for CloudWatch Logs --- #
Write-Log "Installing Fluent Bit for CloudWatch Logs..." -ForegroundColor Green
helm upgrade --install fluent-bit fluent/fluent-bit `
    --namespace kube-system `
    --set cloudWatch.logGroupName=/eks/$ClusterName/application `
    --set cloudWatch.region=$Region `
    --wait --timeout 20m --atomic


# --- Step 10: Create IAM OIDC provider and role --- #
$oidcUrl = "https://token.actions.githubusercontent.com"

# Check if OIDC provider already exists
$existingProviders = aws iam list-open-id-connect-providers --output json | ConvertFrom-Json
$providerExists = $existingProviders.OpenIDConnectProviderList | Where-Object { $_.Arn -like "*$AccountId*oidc-provider/token.actions.githubusercontent.com" }

if (-not $providerExists) {
    Write-Log "Creating IAM OIDC provider for Github Actions..." -ForegroundColor Green
    aws iam create-open-id-connect-provider `
        --url $oidcUrl `
        --client-id-list sts.amazonaws.com `
        --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
} else {
    Write-Log "Github Actions OIDC provider already exists." -ForegroundColor Yellow
}

# Check if IAM role exists
aws iam get-role --role-name $RoleName --region $Region --output json > role.json 2>$null
if ($LASTEXITCODE -eq 0) {
    $roleExists = Get-Content role.json | ConvertFrom-Json
} else {
    $roleExists = $null
}

if (-not $roleExists) {
    Write-Log "Creating IAM OIDC role $RoleName..." -ForegroundColor Green
    aws iam create-role `
        --role-name $RoleName `
        --assume-role-policy-document file://$TrustPolicyFile `
        --region $Region
    aws iam put-role-policy `
        --role-name $RoleName `
        --policy-name GitHubOIDCDeployPolicy `
        --policy-document file://$DeployPolicyFile `
        --region $Region
} else {
    Write-Log "IAM role $RoleName already exists." -ForegroundColor Yellow
}

# Clean up temporary file
Remove-Item role.json -Force


# --- Step 11: Get role ARN --- #
$roleArn = (aws iam get-role --role-name $RoleName --query 'Role.Arn' --output text)
Write-Log "Role ARN: $roleArn" -ForegroundColor Cyan


# --- Step 12 Patch aws-auth ConfigMap --- #
$awsAuthFile = Join-Path $PSScriptRoot "k8s\aws-auth.yaml"
$awsAuthContent = Get-Content $awsAuthFile -Raw
$awsAuthPatched = $awsAuthContent -replace "<role-arn>", $roleArn
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($awsAuthFile, $awsAuthPatched, $utf8NoBom)
Write-Log "Patched aws-auth ConfigMap with role $roleArn" -ForegroundColor Cyan


# --- Step 13: Apply aws-auth ConfigMap --- #
Write-Log "Applying aws-auth ConfigMap to cluster $ClusterName..." -ForegroundColor Green
kubectl apply -f $awsAuthFile


# --- Step 14: Ensure EKS Access Entry for GitHub OIDC Role --- #
Write-Log "Ensuring EKS access entry for GitHub OIDC role..." -ForegroundColor Green

# Check if access entry already exists
$existingAccessEntries = aws eks list-access-entries `
    --cluster-name $ClusterName `
    --region $Region | ConvertFrom-Json

if ($existingAccessEntries.accessEntries -contains $roleArn) {
    Write-Log "Access entry already exists for $roleArn." -ForegroundColor Yellow
}


# --- Step 15: Update workflows with role ARN and region --- #
Write-Log "Updating workflows with role ARN and region..." -ForegroundColor Green
(Get-Content $CiWorkflow) -replace "role-to-assume:.*", "role-to-assume: $roleArn" `
                         -replace "aws-region:.*", "aws-region: $Region" | Set-Content $CiWorkflow
(Get-Content $CdWorkflow) -replace "role-to-assume:.*", "role-to-assume: $roleArn" `
                         -replace "aws-region:.*", "aws-region: $Region" | Set-Content $CdWorkflow


Write-Log "✅ Infrastructure and IAM setup complete. Use role $roleArn in GitHub Actions for CI/CD." -ForegroundColor Green

Stop-Transcript