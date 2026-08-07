# Automobile Manufacturing Dashboard — Full Build Guide (From Scratch)

Everything here assumes an **empty AWS account** (nothing exists yet — no
VPC, no EKS, no state backend) and that you're running **PowerShell on
Windows**. No domain name is used anywhere; the app is served over the
ALB's own `*.elb.amazonaws.com` DNS name on plain HTTP.

Node type used throughout: **`c7i-flex.large`** (not AWS Free Tier
eligible — factor that into cost expectations before you `terraform apply`).

---

## Prerequisites (one-time tool install)

```powershell
# Check what you already have
aws --version
terraform --version
kubectl version --client
helm version
gh --version

# If any are missing, install via winget:
winget install -e --id Amazon.AWSCLI
winget install -e --id Hashicorp.Terraform
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
winget install -e --id GitHub.cli
```

Configure your AWS credentials:

```powershell
aws configure
# Enter your access key, secret key, region = ap-south-1, output = json
aws sts get-caller-identity   # confirms it worked and shows your account ID/ARN
```

Note your own IAM identity ARN from that last command's output — you'll
need it in Part 3 for `additional_admin_arns`, so EKS console access
doesn't get locked to only the Terraform apply identity.

---

## Project layout

```
project/
  bootstrap/             <- Part 1: S3 + DynamoDB state backend (apply once, first)
  terraform/              <- Part 2-4: VPC, EKS, RDS, ECR, IAM, Secrets Manager, WAF, IRSA
  app/                    <- Flask application
  k8s/                    <- Kubernetes manifests
  .github/workflows/      <- CI/CD pipeline
```

---

## Part 1 — Bootstrap the Terraform state backend (S3 + DynamoDB)

This has to be a completely separate `terraform apply`, with **local**
state, because the backend can't reference itself.

```powershell
cd .\project\bootstrap
terraform init
terraform apply -auto-approve
```

Note the two outputs — you need them for Part 2:

```powershell
$STATE_BUCKET = terraform output -raw state_bucket_name
$LOCK_TABLE   = terraform output -raw lock_table_name
Write-Host "Bucket: $STATE_BUCKET"
Write-Host "Lock table: $LOCK_TABLE"
```

Write these down somewhere — you'll need them again any time you re-run
`terraform init` in Part 2 (e.g. from a fresh clone or a new machine).

---

## Part 2 — Initialize the main infrastructure project

```powershell
cd ..\terraform
terraform init `
  -backend-config="bucket=$STATE_BUCKET" `
  -backend-config="key=automobile-project/main.tfstate" `
  -backend-config="region=ap-south-1" `
  -backend-config="dynamodb_table=$LOCK_TABLE" `
  -backend-config="encrypt=true"
```

---

## Part 3 — Set your variables

```powershell
$MY_ARN = aws sts get-caller-identity --query Arn --output text

@"
github_org  = "your-github-username-or-org"
github_repo = "your-repo-name"
additional_admin_arns = ["$MY_ARN"]
"@ | Out-File -Encoding utf8 terraform.tfvars
```

Everything else (`vpc_cidr`, `eks_cluster_version`, `eks_node_instance_types
= ["c7i-flex.large"]`, `db_instance_class = "db.t3.micro"`, etc.) already
has sensible defaults in `variables.tf` — override any of them in the same
`terraform.tfvars` file if you want something different.

---

## Part 4 — Apply the core infrastructure

This single apply creates: VPC (2 AZs, single NAT for cost), EKS cluster
(`c7i-flex.large` nodes, K8s 1.34), ECR repo, RDS MySQL (private, gp2,
db.t3.micro), the three least-privilege IAM roles, the Secrets Manager
secret with generated credentials, the WAF Web ACL (not yet associated —
that needs the ALB to exist first), and IRSA roles for the EBS CSI driver
and the ALB controller.

```powershell
terraform plan -out=main.tfplan
terraform apply main.tfplan
```

This will take 12–18 minutes (EKS cluster creation is the slow part). When
it finishes, pull the outputs you'll need for the rest of this guide:

```powershell
$CLUSTER_NAME     = terraform output -raw eks_cluster_name
$ECR_REPO         = terraform output -raw ecr_repository_url
$ALB_IRSA_ARN     = terraform output -raw alb_controller_irsa_role_arn
$EBS_IRSA_ARN     = terraform output -raw ebs_csi_irsa_role_arn
$EXT_SECRETS_ARN  = terraform output -raw external_secrets_irsa_role_arn
$CICD_ROLE_ARN    = terraform output -raw cicd_role_arn
$WAF_ARN          = terraform output -raw waf_web_acl_arn
$SONAR_URL        = terraform output -raw sonarqube_url
$SONAR_INSTANCE_ID = terraform output -raw sonarqube_instance_id

aws eks update-kubeconfig --name $CLUSTER_NAME --region ap-south-1
kubectl get nodes   # should show your c7i-flex.large nodes as Ready within a couple minutes
```

This apply also launches the self-hosted SonarQube EC2 instance. It takes
**3-5 extra minutes after `terraform apply` finishes** for the instance to
boot, install Docker, and pull/start the SonarQube image — don't jump to
Part 10 immediately, or you'll hit a connection refused. You can watch it
come up:

```powershell
# Poll every 15s until SonarQube reports itself healthy
do {
  Start-Sleep -Seconds 15
  try { $status = (Invoke-RestMethod "$SONAR_URL/api/system/status" -TimeoutSec 5).status }
  catch { $status = "not reachable yet" }
  Write-Host $status
} until ($status -eq "UP")
```

---

## Part 5 — Install cluster add-ons (Helm)

### AWS Load Balancer Controller

```powershell
kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system `
  eks.amazonaws.com/role-arn=$ALB_IRSA_ARN --overwrite

$VPC_ID = terraform output -raw vpc_id

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller `
  -n kube-system `
  --set clusterName=$CLUSTER_NAME `
  --set serviceAccount.create=false `
  --set serviceAccount.name=aws-load-balancer-controller `
  --set region=ap-south-1 `
  --set vpcId=$VPC_ID

kubectl get deployment -n kube-system aws-load-balancer-controller
```

### EBS CSI driver's service account annotation

The `aws-ebs-csi-driver` was installed as a cluster addon in Part 4
already, but its service account still needs the IRSA annotation pointed
at it (the module wires the role in via `cluster_addons`, so this step is
usually already done for you — verify it):

```powershell
kubectl get serviceaccount ebs-csi-controller-sa -n kube-system -o jsonpath="{.metadata.annotations}"
# Should show eks.amazonaws.com/role-arn matching $EBS_IRSA_ARN.
# If it's missing, run:
kubectl annotate serviceaccount ebs-csi-controller-sa -n kube-system `
  eks.amazonaws.com/role-arn=$EBS_IRSA_ARN --overwrite
```

### External Secrets Operator

```powershell
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets `
  -n external-secrets --create-namespace

kubectl create serviceaccount external-secrets-sa -n external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount external-secrets-sa -n external-secrets `
  eks.amazonaws.com/role-arn=$EXT_SECRETS_ARN --overwrite
```

---

## Part 6 — Namespace, RBAC, secrets, and the database schema

```powershell
cd ..\k8s

# Namespace + least-privilege ServiceAccount/Role for the app itself
kubectl apply -f .\rbac.yaml

# Pull AWS Secrets Manager values into a k8s Secret named app-credentials
kubectl apply -f .\external-secret.yaml
kubectl get externalsecret -n automobile-app
kubectl get secret app-credentials -n automobile-app
# If it doesn't show up within ~60s: kubectl describe externalsecret app-credentials -n automobile-app
```

---

## Part 7 — Build and push the app image

```powershell
cd ..\app
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $ECR_REPO
docker build -t "${ECR_REPO}:v1" .
docker push "${ECR_REPO}:v1"
```

Now update the two files that reference the image placeholder:

```powershell
cd ..\k8s
(Get-Content deployment.yaml) -replace '<ECR_REPO_URI>:<IMAGE_TAG>', "${ECR_REPO}:v1" | Set-Content deployment.yaml
(Get-Content db-init-job.yaml) -replace '<ECR_REPO_URI>:<IMAGE_TAG>', "${ECR_REPO}:v1" | Set-Content db-init-job.yaml
```

Run the one-time schema init job (RDS is private, so this has to run
inside the cluster, not from your laptop):

```powershell
kubectl apply -f .\db-init-job.yaml
kubectl wait --for=condition=complete job/db-init -n automobile-app --timeout=120s
kubectl logs job/db-init -n automobile-app   # should end with "schema ready"
```

---

## Part 8 — Deploy the app and the network policies

```powershell
kubectl apply -f .\deployment.yaml
kubectl apply -f .\ingress.yaml
kubectl apply -f .\networkpolicy.yaml

kubectl get pods -n automobile-app -w
# Ctrl+C once both pods show Running/2-2 or Running/1-1 depending on your probe config
```

Wait for the ALB to provision, then get its address:

```powershell
kubectl get ingress automobile-app-ingress -n automobile-app -w
# Ctrl+C once ADDRESS is populated (takes 2-4 minutes)
$ALB_URL = "http://" + (kubectl get ingress automobile-app-ingress -n automobile-app -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")
Write-Host $ALB_URL
Start-Process $ALB_URL
```

Log in with the generated admin credentials (never typed by hand — pull
them once from Secrets Manager if you need to see them):

```powershell
aws secretsmanager get-secret-value `
  --secret-id automobile-project/app-credentials `
  --query SecretString --output text | ConvertFrom-Json | Select ADMIN_USERNAME, ADMIN_PASSWORD
```

---

## Part 9 — Associate the WAF with the now-existing ALB

The WAF Web ACL was created in Part 4, but couldn't be attached to an ALB
that didn't exist yet. Now that Part 8 created it, do the second apply
pass:

```powershell
cd ..\terraform
Add-Content terraform.tfvars 'associate_waf = true'
terraform apply -auto-approve

aws wafv2 get-web-acl-for-resource --resource-arn (aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'automobile')].LoadBalancerArn" --output text)
```

Quick test that it's actually blocking SQLi (expect a 403 from the WAF, not
your app):

```powershell
Invoke-WebRequest "$ALB_URL/login?username=' OR '1'='1" -SkipHttpErrorCheck
```

---

## Part 10 — Wire up CI/CD (Trivy + self-hosted SonarQube on EC2)

SonarQube runs on its own EC2 instance (provisioned in Part 4, in the
VPC's **public** subnet, reachable on port 9000). This replaces both
earlier attempts — SonarCloud (missing options on the free plan) and the
first EC2 attempt (which had four connectivity/SSM problems, all fixed in
this version — see the appendix at the bottom if you're curious what was
wrong).

### 10.1 — Open SonarQube and finish first-time setup

```powershell
Write-Host "SonarQube URL: $SONAR_URL"
Start-Process $SONAR_URL
```

- Log in with the default credentials `admin` / `admin`.
- You'll be forced to set a new password immediately — do that.
- Click **Create a local project** (not "from GitHub/GitLab" — keep it
  simple): Project key = `gowthamsaikadali_Automobile-Manufacturing-Dashboard-SonarQube-Trivy-Security`
  (must match `sonar.projectKey` in `sonar-project.properties`), Display
  name = anything, Main branch name = `main`.
- Choose **Locally** as the analysis method, then **Generate a token** —
  copy it immediately, it's shown only once.

### 10.2 — Set the GitHub secrets

```powershell
gh secret set CICD_ROLE_ARN --body $CICD_ROLE_ARN
gh secret set ECR_REPOSITORY_URI --body $ECR_REPO
gh secret set SONAR_HOST_URL --body $SONAR_URL
gh secret set SONAR_TOKEN --body "<paste the token from 10.1 here>"
```

### 10.3 — If step 10.1 doesn't load, or SSM won't connect: troubleshooting

These are the exact four symptoms from before, and what to check for each
now that the fixes are baked into `terraform/sonarqube-ec2.tf`:

```powershell
# 1. Confirm the instance is actually running and has a public IP
aws ec2 describe-instances --instance-ids $SONAR_INSTANCE_ID `
  --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,SubnetId]"

# 2. Confirm the security group really has port 9000 open
aws ec2 describe-security-groups --filters "Name=group-name,Values=automobile-project-sonarqube-*" `
  --query "SecurityGroups[0].IpPermissions"

# 3. SSM into the instance (no SSH key needed -- this now works because the
#    instance has an IAM instance profile with AmazonSSMManagedInstanceCore)
aws ssm start-session --target $SONAR_INSTANCE_ID

# --- once connected via SSM, run these ON the instance ---
cat /var/log/user-data.log | tail -60      # full boot/install log
sudo docker ps                              # sonarqube container should show "Up"
sudo docker logs sonarqube --tail 50        # if it's not up, this shows why
sysctl vm.max_map_count                     # must read 262144
exit
```

If `aws ssm start-session` itself fails with "TargetNotConnected", the SSM
Agent hasn't registered yet — wait another minute after boot and retry;
Amazon Linux 2023 ships the agent pre-installed and it registers
automatically once the IAM role is attached (which happens at launch, not
after).

### 10.4 — Trigger the pipeline

Push to trigger the pipeline (SonarQube quality gate → Trivy scan,
fails on CRITICAL/HIGH CVEs → push to ECR → deploy):

```powershell
cd ..
git init
git add .
git commit -m "Full from-scratch build: infra + app + security pipeline"
git branch -M main
git remote add origin https://github.com/your-org/your-repo.git
git push -u origin main
gh run watch
```

---

## Verification checklist

```powershell
# App is reachable
Invoke-WebRequest $ALB_URL

# IAM: confirm scoped roles, nothing has AdministratorAccess
aws iam list-attached-role-policies --role-name automobile-project-eks-node-role
aws iam list-attached-role-policies --role-name automobile-project-cicd-role

# Secrets Manager: no plaintext secrets committed anywhere
git grep -i "password" -- '*.tf' '*.py' '*.yaml'

# RDS is private
aws rds describe-db-instances --db-instance-identifier automobile-project-db --query "DBInstances[0].PubliclyAccessible"

# WAF is associated and blocking
aws wafv2 list-resources-for-web-acl --web-acl-arn $WAF_ARN --resource-type APPLICATION_LOAD_BALANCER

# Network Policies are active
kubectl get networkpolicy -n automobile-app

# RBAC: app's own ServiceAccount has only the narrow permissions expected
kubectl auth can-i --list --as=system:serviceaccount:automobile-app:automobile-app-sa -n automobile-app

# CI/CD: last pipeline run passed both the SonarQube gate and Trivy scan
gh run list --limit 5
```

---

## Cost note

`c7i-flex.large` × 2 nodes, `db.t3.micro`, a NAT gateway, an ALB, and the
`t3.medium` SonarQube EC2 instance are **not** covered by AWS Free Tier.
Check current On-Demand pricing for `ap-south-1` before leaving this
running, and tear it down when you're done (below) rather than leaving it
up overnight by accident.

## Tearing everything down

Order matters — Kubernetes-created resources (the ALB, EBS volumes) have to
go before Terraform destroy, or Terraform will time out waiting on
dependencies it doesn't know about:

```powershell
cd .\project\k8s
kubectl delete -f .\ingress.yaml
kubectl delete -f .\deployment.yaml
kubectl delete -f .\networkpolicy.yaml
kubectl delete -f .\external-secret.yaml
kubectl delete -f .\rbac.yaml

cd ..\terraform
terraform destroy -auto-approve

cd ..\bootstrap
terraform destroy -auto-approve
```

The SonarQube EC2 instance is destroyed automatically as part of the
`terraform destroy` in `terraform/` above — it's a resource in that same
root module, not a separate stack.

---

## Appendix — Why the previous SonarQube-on-EC2 attempt failed

For reference, in case any of this resurfaces on a future rebuild:

| Symptom | Root cause | Fix (now in `terraform/sonarqube-ec2.tf`) |
|---|---|---|
| SonarQube not listening on port 9000 | SonarQube bundles Elasticsearch, which refuses to start unless `vm.max_map_count >= 262144` and file-descriptor/process ulimits are raised on the **host** first. Without that, the container exits seconds after starting. | `sysctl`/`limits.d` set in `user_data` at boot, plus `SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true` as a safety net. |
| `Test-NetConnection`/browser can't reach port 9000 | Instance had no public IP and/or sat in a subnet without a route to an Internet Gateway, and/or the security group never actually had a 9000 ingress rule. | Instance launched in the VPC module's **public** subnet with `associate_public_ip_address = true`, plus a dedicated SG with an explicit 9000 ingress rule. |
| SSM can't connect to the instance | No IAM instance profile attached (or one missing `AmazonSSMManagedInstanceCore`), so the pre-installed SSM Agent had no permission to register with Systems Manager. | Dedicated IAM role + instance profile with `AmazonSSMManagedInstanceCore` attached at launch. |
| (General) SonarCloud path abandoned | Some analysis options weren't available on the SonarCloud plan in use. | Switched to self-hosted SonarQube Community Edition entirely — no `sonar.organization` key (that's SonarCloud-only). |
