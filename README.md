# DevOps Exercise: Flask on EKS with CI/CD and Monitoring

A complete DevOps project featuring a simple interactive Flask application deployed to AWS EKS (Elastic Kubernetes Service) with full CI/CD automation via GitHub Actions, comprehensive monitoring with Prometheus/Grafana, and centralized logging through CloudWatch via Fluent Bit.

## 🏗️ Architecture Overview

This project demonstrates a production-ready deployment pipeline:

- **Application**: Flask web app with health checks and custom metrics endpoint
- **Container**: Docker image built and stored in AWS ECR
- **Orchestration**: Kubernetes deployment on AWS EKS with 2-4 nodes (t3.small)
- **CI/CD**: GitHub Actions workflows with AWS OIDC authentication
- **Ingress**: AWS Application Load Balancer (ALB) for external access
- **Monitoring**: Prometheus + Grafana for metrics visualization
- **Logging**: Fluent Bit shipping logs to CloudWatch Logs

## 📋 Prerequisites

### Required Tools
All tools are automatically installed by the setup script:
- AWS CLI v2
- eksctl
- kubectl
- Helm

### Required Access
- **AWS Account** with permissions to create:
  - EKS clusters
  - ECR repositories
  - IAM roles and policies
  - VPC and networking resources
  - Application Load Balancers
  - CloudWatch log groups
- **GitHub Repository** with Actions enabled
- **Windows PowerShell** with administrator privileges

## 🚀 Quick Start

### 1. Initial Setup

Run the automated setup script as administrator:

```powershell
# Open PowerShell as Administrator
.\Setup-DevOps-Exercise-Infrastructure.ps1
```

**What the setup script does:**
- ✅ Installs required tools (AWS CLI, eksctl, kubectl, Helm)
- ✅ Gathers AWS account and GitHub repository information
- ✅ Creates dedicated VPC with public/private subnets
- ✅ Sets up security groups for web traffic
- ✅ Creates ECR repository for Docker images
- ✅ Provisions EKS cluster using cluster.yaml configuration
- ✅ Validates and installs EKS add-ons (vpc-cni, kube-proxy, coredns, metrics-server, aws-ebs-csi-driver)
- ✅ Configures kubectl for cluster access
- ✅ Installs AWS Load Balancer Controller via Helm
- ✅ Deploys Prometheus/Grafana monitoring stack
- ✅ Configures Fluent Bit for CloudWatch logging
- ✅ Sets up IAM OIDC provider for GitHub Actions
- ✅ Creates GitHub OIDC deploy role with appropriate permissions
- ✅ Patches aws-auth ConfigMap for role access
- ✅ Updates GitHub Actions workflow files with proper credentials

**Estimated time:** 15-20 minutes

### 2. Deploy the Application

After setup completes, trigger deployment by either:

**Option A: Push to main branch**
```bash
git add .
git commit -m "Deploy application"
git push origin main
```

**Option B: Manual trigger via GitHub Actions**
1. Go to your repository on GitHub
2. Click **Actions** tab
3. Select **CI** workflow
4. Click **Run workflow** → **Run workflow**

### 3. Access Your Application

Once deployment completes:

```powershell
# Get the Application Load Balancer URL
kubectl get ingress -n app

# Example output:
# NAME        CLASS   HOSTS   ADDRESS                                                    PORTS   AGE
# flask-app   alb     *       k8s-app-flaskapp-xxxxxxxxxxxx.il-central-1.elb.amazonaws.com   80      5m
```

Open the ADDRESS URL in your browser to access the Flask application.

## 📊 Monitoring and Observability

### Grafana Dashboard

Access Grafana for metrics visualization:

```powershell
# Port-forward Grafana service
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80

# Open browser to: http://localhost:3000
# Default credentials:
#   Username: admin
#   Password: prom-operator
```

**Available Metrics:**
- Custom application metrics at `/metrics` endpoint
  - `custom_requests_total`: Total number of requests
  - `custom_uptime_seconds`: Application uptime
- Kubernetes cluster metrics (CPU, memory, network)
- Pod and container metrics

### CloudWatch Logs

View application logs in AWS CloudWatch:

```powershell
# View logs via AWS CLI
aws logs tail /eks/devops-exercise/application --follow

# Or access via AWS Console:
# CloudWatch → Logs → Log groups → /eks/devops-exercise/application
```

### Kubernetes Commands

```powershell
# View all pods across namespaces
kubectl get pods -A

# View application pods
kubectl get pods -n app

# View application logs
kubectl logs -n app -l app=flask-app

# View service status
kubectl get svc -A

# View ingress status
kubectl get ingress -n app

# Describe deployment
kubectl describe deployment flask-app -n app

# View cluster nodes
kubectl get nodes
```

## 🔄 CI/CD Pipeline

### CI Workflow (`.github/workflows/ci.yaml`)

Triggers on:
- Push to `main` branch
- Pull requests
- Manual workflow dispatch

**Steps:**
1. Checkout code
2. Set up Python 3.11 environment
3. Install dependencies and run syntax validation
4. Authenticate to AWS via OIDC
5. Login to ECR
6. Build Docker image
7. Tag image with commit SHA
8. Push image to ECR

### CD Workflow (`.github/workflows/cd.yaml`)

Triggers on:
- Push to `main` branch (after CI completes)

**Steps:**
1. Checkout code
2. Authenticate to AWS via OIDC
3. Update kubeconfig for EKS access
4. Verify cluster connectivity
5. Patch deployment manifest with image SHA
6. Apply Kubernetes manifests:
   - Namespace
   - Deployment
   - Service
   - Ingress
   - ServiceMonitor
7. Wait for rollout to complete
8. Debug on failure (show pods, events, logs)

## 📁 Project Structure

```
devops-exercise/
├── app/
│   ├── main.py              # Flask application
│   ├── requirements.txt     # Python dependencies
│   └── templates/
│       └── index.html       # Frontend template
├── k8s/
│   ├── namespace.yaml       # Kubernetes namespace
│   ├── deployment.yaml      # Application deployment
│   ├── service.yaml         # ClusterIP service
│   ├── ingress.yaml         # ALB ingress
│   ├── servicemonitor.yaml  # Prometheus monitoring
│   └── aws-auth.yaml        # EKS authentication ConfigMap
├── eks/
│   └── cluster.yaml         # EKS cluster configuration
├── iam/
│   ├── github-oidc-trust-policy.json    # OIDC trust policy
│   ├── github-oidc-deploy-policy.json   # Deploy permissions
│   └── policy-json-backup/              # Original policy templates
├── .github/
│   └── workflows/
│       ├── ci.yaml          # CI pipeline
│       └── cd.yaml          # CD pipeline
├── logs/                    # Setup/teardown logs (generated)
├── Dockerfile               # Container definition
├── Setup-DevOps-Exercise-Infrastructure.ps1
├── Teardown-DevOps-Exercise-Infrastructure.ps1
└── README.md
```

## 🧪 Testing the Application

### Health Check
```bash
curl http://<ALB-URL>/healthz
# Expected: {"status":"ok"}
```

### Custom Metrics
```bash
curl http://<ALB-URL>/metrics
# Expected:
# custom_requests_total 42
# custom_uptime_seconds 3600
```

### Echo Endpoint
```bash
curl -X POST http://<ALB-URL>/echo -d "message=Hello"
# Expected: You said: Hello
#           Aha! I knew you were going to say that. :)
```

### Interactive Web UI
Open `http://<ALB-URL>` in your browser to access the interactive form where you can type messages and see responses.

## 🛠️ Troubleshooting

### Check Pod Status
```powershell
kubectl get pods -n app
kubectl describe pod <pod-name> -n app
kubectl logs <pod-name> -n app
```

### Check Deployment
```powershell
kubectl get deployment flask-app -n app
kubectl describe deployment flask-app -n app
kubectl rollout status deployment/flask-app -n app
```

### Check Ingress and ALB
```powershell
kubectl get ingress -n app
kubectl describe ingress flask-app -n app

# Check ALB in AWS Console
aws elbv2 describe-load-balancers --region il-central-1
```

### Check EKS Add-ons
```powershell
aws eks list-addons --cluster-name devops-exercise --region il-central-1
aws eks describe-addon --cluster-name devops-exercise --addon-name vpc-cni --region il-central-1
```

### Check Events
```powershell
kubectl get events -n app --sort-by='.lastTimestamp'
kubectl get events -n kube-system --sort-by='.lastTimestamp'
```

### Verify IAM Role and OIDC
```powershell
# Check IAM role
aws iam get-role --role-name GitHubOIDCDeployRole

# Check OIDC provider
aws iam list-open-id-connect-providers

# Verify GitHub Actions can assume role (check workflow logs)
```

### Check Helm Releases
```powershell
helm list -A

# Check specific releases
helm status aws-load-balancer-controller -n kube-system
helm status kube-prom -n monitoring
helm status fluent-bit -n kube-system
```

### Re-apply Manifests Manually
```powershell
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/servicemonitor.yaml
```

### Check VPC and Networking
```powershell
# Get VPC ID
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=DevopsExerciseVpc" --region il-central-1

# Check subnets
aws ec2 describe-subnets --filters "Name=tag:Name,Values=DevopsExerciseVpc-*" --region il-central-1

# Check security groups
aws ec2 describe-security-groups --filters "Name=group-name,Values=DevopsExerciseVpc-WebSG" --region il-central-1
```

## 🧹 Cleanup

To tear down all infrastructure:

```powershell
# Run as Administrator
.\Teardown-DevOps-Exercise-Infrastructure.ps1
```

**What the teardown script does:**
- ✅ Ensures required tools are installed
- ✅ Uninstalls Helm releases (Fluent Bit, Prometheus/Grafana)
- ✅ Restores IAM policy JSON files from backup
- ✅ Deletes Kubernetes manifests
- ✅ Removes EKS cluster and node groups
- ✅ Deletes ECR repository and images
- ✅ Removes IAM role and policies
- ✅ Deletes security groups
- ✅ Removes subnets (public and private)
- ✅ Detaches and deletes Internet Gateways
- ✅ Deletes VPC
- ✅ Cleans up all associated AWS resources

**Estimated time:** 10-15 minutes

### Manual Cleanup (if needed)

If the automated teardown fails, you can manually clean up resources:

```powershell
# Remove Helm releases
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall kube-prom -n monitoring
helm uninstall fluent-bit -n kube-system

# Delete Kubernetes resources
kubectl delete -f k8s/

# Delete EKS cluster
eksctl delete cluster --name devops-exercise --region il-central-1

# Delete ECR repository
aws ecr delete-repository --repository-name devops-exercise --region il-central-1 --force

# Delete IAM role
aws iam delete-role --role-name GitHubOIDCDeployRole

# Delete VPC (find VPC ID first)
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=DevopsExerciseVpc" --region il-central-1
aws ec2 delete-vpc --vpc-id <vpc-id>
```

## 📝 Configuration Details

### Environment Variables
- `PORT`: Application port (default: 8080)
- `PYTHONDONTWRITEBYTECODE`: Prevents .pyc files
- `PYTHONUNBUFFERED`: Forces stdout/stderr to be unbuffered

### EKS Cluster Configuration
Defined in `eks/cluster.yaml`:
- Cluster name: devops-exercise
- Region: il-central-1
- Kubernetes version: 1.30
- Node type: t3.small
- Node count: 2 (min: 2, max: 4)

### Resource Requests/Limits
Defined in `k8s/deployment.yaml`:
- CPU: 100m (request) / 200m (limit)
- Memory: 128Mi (request) / 256Mi (limit)
- Replicas: 2

### VPC Configuration
- CIDR Block: 10.0.0.0/16
- Public Subnet: 10.0.1.0/24 (il-central-1a)
- Private Subnet: 10.0.2.0/24 (il-central-1a)
- Security Group: Allows HTTP (80) and HTTPS (443)

### IAM Policies
- **Trust Policy**: Allows GitHub Actions OIDC provider to assume role
- **Deploy Policy**: Grants permissions for ECR, EKS, and ELB operations

## 🔐 Security Considerations

- **OIDC Authentication**: No long-lived AWS credentials stored in GitHub
- **IAM Least Privilege**: Deploy role has minimal required permissions
- **Private ECR**: Images stored in private repository
- **VPC Isolation**: Resources deployed in dedicated VPC
- **Security Groups**: Restrict inbound traffic to HTTP/HTTPS only
- **AWS Auth ConfigMap**: Controls Kubernetes RBAC for IAM roles
- **Backup Policies**: Original IAM policy templates preserved in backup directory

## 🎯 Project Features

### Automated Infrastructure
- One-command setup and teardown
- Idempotent scripts (safe to re-run)
- Comprehensive logging with timestamps
- Error handling and validation

### Production-Ready Patterns
- Health checks and readiness probes
- Custom metrics for observability
- Structured logging
- Rolling deployments
- Resource limits and requests

### DevOps Best Practices
- Infrastructure as Code (Kubernetes manifests)
- GitOps workflow (Git as source of truth)
- Automated CI/CD pipelines
- Centralized logging
- Comprehensive monitoring

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📚 Additional Resources

- [AWS EKS Documentation](https://docs.aws.amazon.com/eks/)
- [eksctl Documentation](https://eksctl.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Helm Documentation](https://helm.sh/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Flask Documentation](https://flask.palletsprojects.com/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

## 📄 License

This project is provided as-is for educational and demonstration purposes.

---

**Built with ❤️ for DevOps excellence**