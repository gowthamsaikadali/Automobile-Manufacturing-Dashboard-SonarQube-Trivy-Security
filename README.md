# Automobile Manufacturing Dashboard — Complete Build Guide (Final)

This is the full, from-scratch build: Terraform state backend → VPC/EKS/RDS/ECR
→ IAM least-privilege → Secrets Manager → self-hosted SonarQube on EC2 → WAF
→ the Flask app → Kubernetes deployment with RBAC/NetworkPolicies → CI/CD
with SonarQube + Trivy gating every deploy.

**No domain name is used anywhere** — the app is served over the ALB's own
`*.elb.amazonaws.com` DNS name on plain HTTP.

Every command is **PowerShell**, run from an **empty AWS account**. This
version has every fix from the previous build cycle already applied — you
should not hit the same errors again, but if something new comes up, the
"Known-fixed issues" section at the bottom explains what was already solved
and why, in case it's useful for diagnosing something adjacent.

---

## Prerequisites

```powershell
aws --version
terraform --version
kubectl version --client
helm version
gh --version
docker --version

# Install anything missing:
winget install -e --id Amazon.AWSCLI
winget install -e --id Hashicorp.Terraform
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
winget install -e --id GitHub.cli
winget install -e --id Docker.DockerDesktop
```

```powershell
aws configure
# region = ap-south-1, output = json
aws sts get-caller-identity
```

Note your ARN from that last command's output — you'll need it in Part 3.

---

## Project layout

```
project/
  bootstrap/               <- Part 1: S3 + DynamoDB state backend
  terraform/                <- Part 2-4: all infra, including EC2 SonarQube
  app/                      <- Flask application
  k8s/                      <- Kubernetes manifests
  .github/workflows/        <- CI/CD pipeline
  sonar-project.properties  <- SonarQube scan config
```

---

## Part 1 — Bootstrap the Terraform state backend (S3 + DynamoDB)

Separate apply, local state (the backend can't reference itself):

```powershell
cd .\project\bootstrap
terraform init
terraform apply -auto-approve

$STATE_BUCKET = terraform output -raw state_bucket_name
$LOCK_TABLE   = terraform output -raw lock_table_name
Write-Host "Bucket: $STATE_BUCKET"
Write-Host "Lock table: $LOCK_TABLE"
```

**Write these two values down somewhere.** PowerShell variables don't
survive closing the window — if you come back later in a fresh terminal,
re-derive them by re-running the two `terraform output` lines above from
inside `bootstrap`, or by looking them up directly:
```powershell
$STATE_BUCKET = (aws s3api list-buckets --query "Buckets[?starts_with(Name,'automobile-project-tfstate')].Name" --output text)
$LOCK_TABLE   = "automobile-project-tfstate-lock"
```

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

You may see `Warning: Deprecated Parameter -- "dynamodb_table" is
deprecated. Use parameter "use_lockfile" instead.` — harmless, ignore it;
this project deliberately uses DynamoDB for locking.

---

## Part 3 — Set your variables

```powershell
$MY_ARN = aws sts get-caller-identity --query Arn --output text
Write-Host $MY_ARN   # confirm it printed a real ARN before continuing

@"
github_org  = "gowthamsaikadali"
github_repo = "Automobile-Manufacturing-Dashboard-SonarQube-Trivy-Security"
additional_admin_arns = ["$MY_ARN"]
"@ | Out-File -Encoding utf8 terraform.tfvars

Get-Content terraform.tfvars   # sanity check: real values, not literal $MY_ARN text
```

`github_org` and `github_repo` come straight from your repo URL:
`github.com/<github_org>/<github_repo>`. Match capitalization exactly —
this feeds into an IAM trust policy condition later, and it's case-sensitive.

Don't worry about `additional_admin_arns` containing your own ARN — the
Terraform config filters it out automatically to avoid a duplicate access
entry conflict with the auto-granted apply-identity admin access.

---

## Part 4 — Apply the core infrastructure

Creates: VPC (2 AZs, single NAT), EKS cluster (`c7i-flex.large` nodes, K8s
1.34, Network Policy enforcement enabled), ECR (immutable tags), RDS MySQL
(private, gp2), the least-privilege IAM roles, the Secrets Manager secret
with generated credentials (DB password, Flask secret key, admin password
— none typed by hand), the WAF Web ACL, IRSA roles for the ALB controller
and EBS CSI driver, and a self-hosted SonarQube instance on EC2.

```powershell
terraform plan -out=main.tfplan
terraform apply main.tfplan
```

Takes 12–18 minutes (EKS is the slow part). Pull the outputs you'll need:

```powershell
$CLUSTER_NAME     = terraform output -raw eks_cluster_name
$ECR_REPO         = terraform output -raw ecr_repository_url
$ALB_IRSA_ARN     = terraform output -raw alb_controller_irsa_role_arn
$EBS_IRSA_ARN     = terraform output -raw ebs_csi_irsa_role_arn
$EXT_SECRETS_ARN  = terraform output -raw external_secrets_irsa_role_arn
$CICD_ROLE_ARN    = terraform output -raw cicd_role_arn
$WAF_ARN          = terraform output -raw waf_web_acl_arn
$SONAR_URL        = terraform output -raw sonarqube_url

aws eks update-kubeconfig --name $CLUSTER_NAME --region ap-south-1
kubectl get nodes   # should show your c7i-flex.large nodes as Ready within a couple minutes
```

**Cost note:** `c7i-flex.large` × 2 nodes, `db.t3.micro`, a NAT gateway, an
ALB, and the `t3.medium` SonarQube instance are all outside AWS Free Tier.
See the teardown section at the bottom — use it when you're not actively
working on this.

---

## Part 5 — Set up SonarQube (on the EC2 instance you just created)

```powershell
Write-Host $SONAR_URL
Start-Process $SONAR_URL
```

Wait ~2 minutes after `terraform apply` finished for Docker/SonarQube to
boot inside the instance before this loads.

1. Log in with `admin` / `admin` — you'll be forced to set a new password immediately
2. **Administration → Projects → Management → Create Project** (manually, not via the GitHub import flow — that's a SonarCloud-only concept, not relevant for self-hosted)
   - Project key: `automobile-manufacturing-dashboard` (must exactly match `sonar-project.properties` in your repo root)
   - Display name: whatever you like
3. Choose **"Locally"** as the analysis method when prompted, then **"Use existing token"** → **Generate a token** and copy it — you won't see it again

Save both values for Part 10:

```powershell
Write-Host "Sonar URL: $SONAR_URL"
Write-Host "Save the token you just generated somewhere safe -- you'll paste it into a GitHub secret in Part 10"
```

---

## Part 6 — Install cluster add-ons (Helm)

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

# The annotation above only works if it happens BEFORE the controller pod
# starts (IRSA env vars get injected at pod creation, not live). Since we
# annotated first here, this should work on the first try. If you ever see
# an AccessDenied error mentioning the EKS NODE role instead of
# alb-controller-irsa, it means the pod started before the annotation
# landed -- fix with:
#   kubectl rollout restart deployment aws-load-balancer-controller -n kube-system

kubectl get deployment -n kube-system aws-load-balancer-controller
```

### EBS CSI driver service account annotation

Already wired via `cluster_addons` in `eks.tf`, but verify:

```powershell
kubectl get serviceaccount ebs-csi-controller-sa -n kube-system -o jsonpath="{.metadata.annotations}"
# Should show eks.amazonaws.com/role-arn matching $EBS_IRSA_ARN
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

## Part 7 — Namespace, RBAC, and secrets

```powershell
cd ..\k8s
kubectl apply -f .\rbac.yaml
kubectl apply -f .\external-secret.yaml
```

This applies a **`ClusterSecretStore`**, not a namespaced `SecretStore` —
that distinction matters: a namespaced `SecretStore` can only authenticate
via a ServiceAccount in its *own* namespace, but `external-secrets-sa` lives
in the `external-secrets` namespace while the app lives in `automobile-app`.
`ClusterSecretStore` is what correctly bridges that.

```powershell
kubectl get clustersecretstore aws-secrets-manager
kubectl get externalsecret -n automobile-app
kubectl get secret app-credentials -n automobile-app
```

Give it 10–30 seconds. If `READY` stays `False`, check:

```powershell
kubectl describe externalsecret app-credentials -n automobile-app
```

The two most common causes: the ServiceAccount annotation didn't take (try
`kubectl rollout restart deployment -n external-secrets`), or — if the
error mentions KMS/decrypt — this project's Secrets Manager secret is
encrypted with a customer-managed KMS key, and the IRSA role's policy
already includes `kms:Decrypt` for exactly this reason, so this shouldn't
come up, but if it does, confirm `terraform/secrets-manager.tf`'s
`external_secrets_read_only` policy includes both the `secretsmanager:*`
and `kms:Decrypt`/`kms:DescribeKey` statements.

---

## Part 8 — Build, push, and initialize the database

```powershell
cd ..\app
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $ECR_REPO
docker build -t "${ECR_REPO}:v1" .

# Confirm the image actually works before pushing -- this catches dependency
# issues early instead of after a failed Job
docker run --rm "${ECR_REPO}:v1" python -c "import mysql.connector; print('ok')"

docker push "${ECR_REPO}:v1"
```

Update the two files that reference the image:

```powershell
cd ..\k8s
(Get-Content deployment.yaml) -replace '<ECR_REPO_URI>:<IMAGE_TAG>', "${ECR_REPO}:v1" | Set-Content deployment.yaml
(Get-Content db-init-job.yaml) -replace '<ECR_REPO_URI>:<IMAGE_TAG>', "${ECR_REPO}:v1" | Set-Content db-init-job.yaml
```

Run the one-time schema init job (RDS is private — this has to run inside
the cluster, not from your laptop):

```powershell
kubectl apply -f .\db-init-job.yaml
kubectl wait --for=condition=complete job/db-init -n automobile-app --timeout=120s
kubectl logs job/db-init -n automobile-app   # should end with "schema ready"
```

---

## Part 9 — Deploy the app

```powershell
kubectl apply -f .\deployment.yaml
kubectl apply -f .\ingress.yaml
kubectl apply -f .\networkpolicy.yaml

kubectl get pods -n automobile-app -w
# Ctrl+C once both pods show 1/1 Running
```

Wait for the ALB, then open it:

```powershell
kubectl get ingress automobile-app-ingress -n automobile-app -w
# Ctrl+C once ADDRESS is populated (2-4 minutes)
$ALB_URL = "http://" + (kubectl get ingress automobile-app-ingress -n automobile-app -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")
Start-Process $ALB_URL
```

The bare URL redirects straight to `/login` automatically. Log in with the
generated admin credentials:

```powershell
aws secretsmanager get-secret-value `
  --secret-id automobile-project/app-credentials `
  --query SecretString --output text | ConvertFrom-Json | Select ADMIN_USERNAME, ADMIN_PASSWORD
```

---

## Part 10 — Associate the WAF, then wire up CI/CD

Associate WAF (needs the ALB to exist first, which it now does):

```powershell
cd ..\terraform
Add-Content terraform.tfvars 'associate_waf = true'
terraform apply -auto-approve

Invoke-WebRequest "$ALB_URL/login?username=' OR '1'='1" -SkipHttpErrorCheck
# Should get a 403 from the WAF, not your app -- confirms SQLi rules are active
```

GitHub secrets for CI/CD:

```powershell
gh secret set CICD_ROLE_ARN --body $CICD_ROLE_ARN
gh secret set ECR_REPOSITORY_URI --body $ECR_REPO
gh secret set SONAR_HOST_URL --body $SONAR_URL
gh secret set SONAR_TOKEN --body "<the token you generated in Part 5>"
```

Push to trigger it:

```powershell
cd ..
git init
git add .
git commit -m "Full from-scratch build: infra + app + EC2 SonarQube + Trivy + gated deploy"
git branch -M main
git remote add origin https://github.com/gowthamsaikadali/Automobile-Manufacturing-Dashboard-SonarQube-Trivy-Security.git
git push -u origin main
gh run watch
```

Pipeline order: **SonarQube quality gate → build image → Trivy scan (fails
on CRITICAL/HIGH CVEs) → push to ECR → deploy to EKS.** Every stage has to
pass before the next runs.

---

## Verification checklist

```powershell
Invoke-WebRequest $ALB_URL

aws iam list-attached-role-policies --role-name automobile-project-eks-node-role
aws iam list-attached-role-policies --role-name automobile-project-cicd-role

git grep -i "password" -- '*.tf' '*.py' '*.yaml'   # should return nothing sensitive

aws rds describe-db-instances --db-instance-identifier automobile-project-db --query "DBInstances[0].PubliclyAccessible"   # should be false

aws wafv2 list-resources-for-web-acl --web-acl-arn $WAF_ARN --resource-type APPLICATION_LOAD_BALANCER

kubectl get networkpolicy -n automobile-app

kubectl auth can-i --list --as=system:serviceaccount:automobile-app:automobile-app-sa -n automobile-app

gh run list --limit 5
```

---

## Tearing everything down (do this when you're not actively working)

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

Just want to stop paying without fully tearing down (e.g. overnight)? Stop
the SonarQube EC2 instance instead of destroying everything:

```powershell
$SONAR_ID = (aws ec2 describe-instances --filters "Name=tag:Name,Values=automobile-project-sonarqube" --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ec2 stop-instances --instance-ids $SONAR_ID
```
(You still pay for the EKS control plane and RDS while they exist — only a
full `terraform destroy` stops that.)

---

## Known-fixed issues (already applied in this codebase)

These were real bugs hit and fixed during earlier build cycles of this
exact project. They're already corrected in the files you have — this
section exists purely so you recognize the symptom instantly if something
*adjacent* ever resurfaces, rather than re-diagnosing from scratch:

1. **`terraform init` backend errors** — caused by empty PowerShell
   variables in a fresh session, not a file bug. Always re-derive
   `$STATE_BUCKET`/`$LOCK_TABLE` per Part 1's note.
2. **`waf.tf` "Argument definition required"** — single-line nested blocks
   (`override_action { none {} }`) aren't valid HCL; must be multi-line.
   Already fixed in `waf.tf`.
3. **EKS access-entry 409 conflict** — your own ARN ending up in both the
   auto-admin grant and `additional_admin_arns`. `eks.tf` filters your own
   ARN out automatically now.
4. **vpc-cni addon `InvalidParameterException`** — Network Policy
   enforcement is a top-level `enableNetworkPolicy` field, not nested under
   `env`. Already correct in `eks.tf`.
5. **`kubectl apply` OpenAPI validation DNS failure** — a flaky
   schema-download step, not a real connectivity problem if `kubectl get
   nodes` works. Add `--validate=false` if it recurs.
6. **External Secrets CRDs "not found"** — means the Helm chart wasn't
   installed/ready yet. Part 6 installs it before Part 7 applies anything
   that depends on it.
7. **Namespaced `SecretStore` "is not ready"** — can't reference a
   ServiceAccount in a different namespace. `k8s/external-secret.yaml`
   already uses `ClusterSecretStore`, which supports this correctly.
8. **`ExternalSecret` `SecretSyncedError` after the store went Ready** —
   missing `kms:Decrypt`/`kms:DescribeKey` on the customer-managed KMS key
   (`secretsmanager:GetSecretValue` alone isn't enough for an
   encrypted-with-a-custom-key secret). Already in
   `terraform/secrets-manager.tf`.
9. **`db-init` Job `ModuleNotFoundError: No module named 'mysql'`** — the
   old Dockerfile installed packages with `pip install --user`, which
   depends on `$HOME` matching between build and runtime; it didn't, since
   the container user's home dir was set differently. Fixed by installing
   to `/usr/local` via `pip install --prefix=/install`, which doesn't
   depend on `$HOME` at all. Already in `app/Dockerfile`.
10. **ALB controller `AccessDenied` on `DescribeLoadBalancers`, but the
    error shows the EKS *node* role, not `alb-controller-irsa`** — means
    IRSA env vars never got injected because the ServiceAccount was
    annotated *after* the pod already started. Part 6 annotates before
    installing the Helm chart specifically to avoid this.
11. **ALB reachable but the bare URL 404s** — `app.py` had no route for
    `/` itself. Already fixed — visiting `/` redirects to `/login` or
    `/dashboard`.
12. **Login page loads, but logging in silently fails / bounces back with
    no error** — `FORCE_SECURE_COOKIES=true` sets a `Secure` session
    cookie, which browsers refuse to store over plain HTTP (this build has
    no domain/TLS). Already set to `"false"` in `k8s/deployment.yaml`.
13. **SonarQube job fails with `java.net.ConnectException: Connection
    refused`** — happens when `SONAR_HOST_URL` points at `localhost`,
    which means nothing from inside a GitHub-hosted runner (a different
    machine than yours). This build avoids the problem entirely by hosting
    SonarQube on a publicly reachable EC2 instance instead (Part 5) —
    no `localhost`, no tunnel required.
14. **SonarCloud "Automatic Analysis" conflict** — only relevant if you'd
    used SonarCloud instead of this EC2 approach; not applicable here.

Since your ECR repo has `image_tag_mutability = "IMMUTABLE"` (deliberately,
so a tag can never be silently overwritten), every rebuild after `:v1`
needs a new tag (`:v2`, `:v3`, ...) with the corresponding `-replace`
updates in `k8s/deployment.yaml` and `k8s/db-init-job.yaml` — or let the
CI/CD pipeline handle this automatically, since it tags images with the
git commit SHA.
