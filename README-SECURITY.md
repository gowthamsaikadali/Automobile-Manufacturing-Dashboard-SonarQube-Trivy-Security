# Automobile Manufacturing Dashboard — Security Hardening Guide (PowerShell)

This guide assumes you already have the base EKS + VPC + RDS + ECR infra from
your existing Terraform (per your project history: `vpc`, `eks`, `rds`,
`ecr` modules). This guide adds the **Flask app** and the **six security
requirements** on top of it. Every command below is PowerShell syntax.

---

## Part 0 — Folder layout

Unzip/copy this project so you have:

```
project/
  app/                  <- Flask application
  terraform/            <- new .tf files to ADD to your existing terraform folder
  k8s/                  <- new/updated Kubernetes manifests
  .github/workflows/    <- CI/CD pipeline
```

Copy the `terraform/*.tf` files into your **existing** terraform root
(alongside your `vpc.tf`, `eks.tf`, `rds.tf`, etc.) — they reference
`module.eks` and `module.rds`, so they must live in the same root module.

```powershell
Copy-Item .\project\terraform\*.tf .\your-existing-terraform-folder\ -Force
```

---

## Part 1 — Requirement: IAM least privilege

**File:** `terraform/iam-least-privilege.tf`

This creates three separate roles:
1. `eks-node-role` — worker nodes: ECR read-only, CNI, worker-node policy only
2. `ec2-bastion-role` — any utility EC2 instance: SSM access only, no SSH keys
3. `cicd-role` — GitHub Actions, via **OIDC federation** (no AWS access keys
   stored in GitHub at all), scoped to push-to-this-ECR-repo and
   describe-this-cluster only

You need two variables. Add them to your `terraform.tfvars`:

```powershell
Add-Content .\terraform.tfvars @"
github_org  = "your-github-username-or-org"
github_repo = "your-repo-name"
"@
```

Then wire your existing EKS node group to use this role instead of whatever
default role your `eks` module created — in your `eks.tf` module block, set:

```hcl
module "eks" {
  # ...existing config...
  eks_managed_node_groups = {
    default = {
      # ...
      iam_role_arn = aws_iam_role.eks_node_role.arn
    }
  }
}
```

---

## Part 2 — Requirement: Secrets in AWS Secrets Manager

**File:** `terraform/secrets-manager.tf`

This generates the DB password, Flask secret key, and admin password with
`random_password` (Terraform generates them — you never type a password
anywhere), encrypts them with a dedicated KMS key, and stores them as one
JSON secret. It also creates a scoped IRSA role so only the External
Secrets Operator's service account can read *this one secret* — not every
secret in your account.

Apply it:

```powershell
cd .\your-existing-terraform-folder\
terraform init -upgrade
terraform plan -out=security.tfplan
terraform apply security.tfplan
```

Install External Secrets Operator (if not already installed from your prior
work):

```powershell
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets `
  -n external-secrets --create-namespace
```

Create the app namespace and RBAC (also covers Part 6 below):

```powershell
kubectl apply -f .\project\k8s\rbac.yaml
```

Annotate the External Secrets service account with the IRSA role so it can
actually reach Secrets Manager:

```powershell
$IRSA_ARN = terraform output -raw external_secrets_irsa_role_arn
kubectl annotate serviceaccount external-secrets-sa `
  -n external-secrets `
  eks.amazonaws.com/role-arn=$IRSA_ARN --overwrite
```

Apply the ExternalSecret so the `app-credentials` Kubernetes Secret gets
created from AWS Secrets Manager:

```powershell
kubectl apply -f .\project\k8s\external-secret.yaml
kubectl get externalsecret -n automobile-app
kubectl get secret app-credentials -n automobile-app
```

If `get secret` doesn't show it after a minute, check:

```powershell
kubectl describe externalsecret app-credentials -n automobile-app
```

---

## Part 3 — Requirement: HTTPS/TLS via ACM on the ALB/Ingress

**File:** `terraform/acm-https.tf`

**Read this first:** ACM cannot issue a certificate for the ALB's raw
`*.elb.amazonaws.com` DNS name — it needs a domain you actually own, because
certificate issuance requires domain validation. You have two paths:

### Option A — you have (or will buy) a domain

1. Register or use an existing domain, and get its Route 53 hosted zone ID:

```powershell
aws route53 list-hosted-zones-by-name --dns-name "example.com"
```

2. Add to `terraform.tfvars`:

```powershell
Add-Content .\terraform.tfvars @"
domain_name     = "dashboard.example.com"
route53_zone_id = "Z0123456789ABCDEF"
"@
```

3. Apply — Terraform will request the cert and auto-create the DNS
   validation record in Route 53:

```powershell
terraform apply
terraform output acm_certificate_arn
```

4. Paste that ARN into `k8s/ingress.yaml` in place of `<ACM_CERTIFICATE_ARN>`,
   then apply the Ingress:

```powershell
kubectl apply -f .\project\k8s\ingress.yaml
```

5. Once the ALB is up, point your domain's Route 53 record (an `A`/ALIAS
   record) at the ALB's DNS name so the cert's hostname actually resolves
   to it.

### Option B — staying domain-free (dev/demo only)

Uncomment the `tls_private_key` / `tls_self_signed_cert` block at the bottom
of `acm-https.tf`, and skip the Route 53 steps. You'll get TLS in transit
but browsers will show "Not Secure" since it's not a publicly trusted CA.
This is fine for a portfolio demo but say so explicitly if you present it —
don't claim it's a "real" HTTPS setup.

If you don't want HTTPS at all yet, just leave `domain_name = ""` and remove
the `alb.ingress.kubernetes.io/certificate-arn` annotation from
`k8s/ingress.yaml` — the Ingress will stay HTTP-only, same as your current
setup.

---

## Part 4 — Requirement: WAF blocking SQLi/XSS

**File:** `terraform/waf.tf`

This creates a WAFv2 Web ACL with AWS's managed Common Rule Set, SQL
injection rule set, known-bad-inputs rule set, and a per-IP rate limit —
covers the SQLi/XSS requirement without you writing custom rules.

The tricky part: the ALB itself is created by the AWS Load Balancer
Controller *after* you apply the Ingress (Part 3), not by Terraform
directly. So this is a two-pass apply:

```powershell
# Pass 1: create the WAF ACL itself (no association yet)
terraform apply

# Apply your Ingress so the ALB gets created
kubectl apply -f .\project\k8s\ingress.yaml
kubectl get ingress -n automobile-app   # wait until ADDRESS is populated

# Pass 2: now associate the WAF with that ALB
Add-Content .\terraform.tfvars 'alb_arn_lookup_tag_value = "automobile-project-dev"'  # your EKS cluster name
terraform apply
```

Verify the association:

```powershell
terraform output waf_web_acl_arn
aws wafv2 list-resources-for-web-acl --web-acl-arn (terraform output -raw waf_web_acl_arn) --resource-type APPLICATION_LOAD_BALANCER
```

Test it's actually blocking SQLi (should get a 403 from the WAF, not your app):

```powershell
$ALB_URL = "http://" + (kubectl get ingress automobile-app-ingress -n automobile-app -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")
Invoke-WebRequest "$ALB_URL/login?username=' OR '1'='1"
```

---

## Part 5 — Requirement: Kubernetes Network Policies

**File:** `k8s/networkpolicy.yaml`

Default-deny everything in the `automobile-app` namespace, then explicit
allows for: DNS, ALB → app pods on 5000, app pods → RDS on 3306, app pods →
AWS APIs on 443 (for Secrets Manager/STS).

**Before applying:** open the file and replace `10.0.0.0/16` in the
`allow-egress-to-rds-and-aws-apis` policy with your actual VPC CIDR:

```powershell
terraform output -raw vpc_cidr_block   # if you have this output; otherwise check your vpc.tf
```

Apply:

```powershell
kubectl apply -f .\project\k8s\networkpolicy.yaml
```

Confirm the app can still reach the DB (should succeed) and that a random
pod in a different namespace can't reach your app pods (should hang/timeout):

```powershell
kubectl exec -n automobile-app deploy/automobile-app -- python -c "from db import get_db_connection; get_db_connection(); print('DB OK')"
```

Note: Network Policies are only enforced if your CNI supports them. The AWS
VPC CNI supports `NetworkPolicy` enforcement as of the versions installed
with recent EKS add-ons — confirm yours is enabled:

```powershell
kubectl get daemonset aws-node -n kube-system -o jsonpath="{.spec.template.spec.containers[0].env}" | Select-String "ENABLE_NETWORK_POLICY"
```

If that env var isn't set to `"true"`, enable it via the EKS add-on config
in Terraform (`aws_eks_addon "vpc_cni"` → `configuration_values` →
`ENABLE_NETWORK_POLICY=true`), then re-apply.

---

## Part 6 — Requirement: Kubernetes RBAC

**File:** `k8s/rbac.yaml` (already applied in Part 2)

This gives:
- The app's own ServiceAccount (`automobile-app-sa`) only `get/list/watch`
  on ConfigMaps/Secrets in its own namespace — nothing else.
- A separate read-only `automobile-app-viewer` role for anyone who needs to
  check logs/status but shouldn't edit anything.

If you have specific IAM users/roles who should get that read-only access,
map them via an EKS access entry and bind them to the `automobile-app-viewers`
group referenced in the RoleBinding:

```powershell
aws eks create-access-entry `
  --cluster-name automobile-project-dev `
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/someone `
  --kubernetes-groups automobile-app-viewers
```

---

## Part 7 — Requirement: Trivy + SonarQube in CI/CD

**File:** `.github/workflows/security-pipeline.yml`

Pipeline order: **SonarQube (fails the build on a broken quality gate) →
build the Docker image → Trivy scan (fails on CRITICAL/HIGH CVEs) → push to
ECR only if the scan passed → deploy to EKS.**

### Set up GitHub repo secrets

```powershell
gh secret set CICD_ROLE_ARN --body (terraform output -raw cicd_role_arn 2>$null)
gh secret set ECR_REPOSITORY_URI --body "<your-ecr-repo-uri>"
gh secret set SONAR_TOKEN --body "<token from your SonarQube instance>"
gh secret set SONAR_HOST_URL --body "<your SonarQube server URL>"
```

(If you don't have `gh` CLI, set these manually under repo Settings →
Secrets and variables → Actions.)

You'll also need a `terraform output` for the CI/CD role ARN — add this to
`iam-least-privilege.tf` if it's not already exposed:

```powershell
Add-Content .\your-existing-terraform-folder\outputs.tf @"
output "cicd_role_arn" {
  value = aws_iam_role.cicd_role.arn
}
"@
terraform apply
```

### Run SonarQube locally to test before your first CI run (optional)

If you don't already have a SonarQube server, the fastest way for a
portfolio project is a small EC2/local Docker instance:

```powershell
docker run -d --name sonarqube -p 9000:9000 sonarqube:community
```

Log in at `http://localhost:9000` (default admin/admin, you'll be forced to
change it), create a project + token, and use those as `SONAR_HOST_URL`
and `SONAR_TOKEN` above.

### Trigger the pipeline

```powershell
git add .
git commit -m "Add security hardening: IAM, secrets, WAF, network policies, RBAC, CI scanning"
git push origin main
```

Watch it run:

```powershell
gh run watch
```

---

## Part 8 — Building and deploying the Flask app itself

```powershell
cd .\project\app
$ECR_REPO = terraform output -raw ecr_repository_url  # from your existing ecr.tf output
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $ECR_REPO
docker build -t "${ECR_REPO}:v1" .
docker push "${ECR_REPO}:v1"
```

Update `k8s/deployment.yaml`: replace `<ECR_REPO_URI>:<IMAGE_TAG>` with
`${ECR_REPO}:v1`, then:

```powershell
kubectl apply -f .\project\k8s\deployment.yaml
kubectl apply -f .\project\k8s\ingress.yaml
kubectl get pods -n automobile-app -w
```

Once pods are `Running` and the Ingress has an address, open it in a
browser (HTTP if you skipped Part 3's domain setup, HTTPS if you did it):

```powershell
kubectl get ingress -n automobile-app
```

Log in with the `ADMIN_USERNAME`/`ADMIN_PASSWORD` from Secrets Manager —
never printed to console, so pull it if you need to see it once:

```powershell
aws secretsmanager get-secret-value --secret-id automobile-project/app-credentials --query SecretString --output text | ConvertFrom-Json
```

---

## Part 9 — Container vulnerability scanning outside CI (one-off check)

To scan the image manually before it ever goes through CI:

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy image "${ECR_REPO}:v1"
```

Or with AWS Inspector (scans images already pushed to ECR automatically if
enabled):

```powershell
aws inspector2 enable --resource-types ECR
aws inspector2 list-findings --filter-criteria "{\"ecrImageRepositoryName\":[{\"comparison\":\"EQUALS\",\"value\":\"automobile-project-dev\"}]}"
```

---

## Quick verification checklist

```powershell
# IAM: confirm the three roles exist and nothing has AdministratorAccess
aws iam list-attached-role-policies --role-name automobile-project-eks-node-role
aws iam list-attached-role-policies --role-name automobile-project-cicd-role

# Secrets Manager: confirm the secret exists, no plaintext anywhere in git
git grep -i "password" -- '*.tf' '*.py' '*.yaml'   # should return nothing sensitive

# HTTPS: confirm the listener
kubectl get ingress -n automobile-app -o yaml | Select-String "certificate-arn"

# WAF: confirm rules are active
aws wafv2 get-web-acl --name automobile-project-waf --scope REGIONAL --id (terraform output -raw waf_web_acl_arn).Split("/")[-1]

# Network Policies: confirm they're applied
kubectl get networkpolicy -n automobile-app

# RBAC: confirm least-privilege role
kubectl auth can-i --list --as=system:serviceaccount:automobile-app:automobile-app-sa -n automobile-app

# CI scanning: confirm the last pipeline run passed both gates
gh run list --limit 5
```
