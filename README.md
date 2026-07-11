# AutoForge — Automobile Manufacturing Dashboard (Two-Tier, EKS + RDS)

This bundle gives you:
1. The Flask app (matches your dashboard screenshot) + MySQL schema
2. Docker image (hardened, non-root, Trivy-friendly)
3. Terraform for RDS, IAM (least privilege), Secrets Manager, ACM, WAF
4. Helm chart for EKS with RBAC, NetworkPolicies, ExternalSecrets
5. GitHub Actions pipeline with SonarQube + Trivy gates, OIDC deploy

Everything below is spoon-fed, in order. Do not skip steps — later steps
depend on outputs from earlier ones (ARNs, secret names, etc).

---

## 0. Prerequisites (run once, on your Windows/PowerShell machine)

```powershell
# Confirm tools are installed
aws --version
terraform -version
kubectl version --client
helm version
docker --version
```

You already have: AWS account `762131619075`, region `ap-south-1`, EKS
cluster `autoforge-eks`, ECR repo `autoforge-app`, S3 state bucket, and
GitHub OIDC federation set up from your earlier sessions. This bundle
builds ON TOP of that — it doesn't replace your VPC/EKS control-plane
Terraform, it adds the security layer + app.

---

## 1. Local app sanity check (before touching AWS)

```powershell
cd app
python -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt

# For local-only testing, create a .env file (NEVER commit this file):
@"
FLASK_SECRET_KEY=local-dev-only-change-me
DB_HOST=127.0.0.1
DB_USER=root
DB_PASSWORD=localpass
DB_NAME=autoforge_db
FLASK_ENV=development
"@ | Out-File -Encoding utf8 .env

python app.py
```

Visit `http://localhost:5000/login`. If you don't have a local MySQL,
spin one up quickly with Docker for testing:
```powershell
docker run -d --name autoforge-mysql -e MYSQL_ROOT_PASSWORD=localpass `
  -e MYSQL_DATABASE=autoforge_db -p 3306:3306 mysql:8.0
python seed.py   # requires ADMIN_USERNAME/ADMIN_PASSWORD env vars too
```

---

## 2. Terraform — provision RDS, IAM, Secrets Manager, ACM, WAF

```powershell
cd terraform/infra
```

Edit `variables.tf` defaults or pass `-var` flags for:
- `vpc_id`, `public_subnet_ids`, `private_subnet_ids` (from your existing network stack)
- `domain_name` (the domain you'll point at the ALB, e.g. `autoforge.yourdomain.com`)

```powershell
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This creates, among other things:
- `aws_secretsmanager_secret.rds_credentials` — the ONLY place DB creds live
- `aws_db_instance.mysql` — private-subnet-only, encrypted, TLS-required
- `aws_iam_role.eks_node_role` / `cicd_role` / `app_pod_role` — three
  **separate** least-privilege roles (this directly satisfies "separate
  roles for EC2, EKS nodes, CI/CD")
- `aws_acm_certificate.autoforge` — for HTTPS on the ALB
- `aws_wafv2_web_acl.autoforge` — SQLi/XSS managed rules + rate limiting

Note the outputs:
```powershell
terraform output acm_certificate_arn
```
Save this — you'll paste it into `helm/autoforge/values.yaml`.

If your domain's hosted zone is in Route53, uncomment the validation
block in `acm.tf` first, otherwise validate the cert manually via the
CNAME records ACM gives you in the console.

---

## 3. Install External Secrets Operator on the cluster (one-time)

This is what fixes your original bug (empty `DB_HOST`/`DB_PASSWORD` from
Helm placeholders). Credentials now flow: **Secrets Manager → ESO →
native K8s Secret → pod env** — never through a values file.

```powershell
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets `
  -n external-secrets --create-namespace
```

Also install the AWS Load Balancer Controller if not already present
(needed for the ALB Ingress + WAF association):
```powershell
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller `
  -n kube-system --set clusterName=autoforge-eks
```

---

## 4. Wire up the Helm values

Edit `helm/autoforge/values.yaml`:
```yaml
serviceAccount:
  roleArn: "arn:aws:iam::762131619075:role/autoforge-app-pod-role"
ingress:
  acmCertArn: "<paste terraform output acm_certificate_arn>"
  wafAclArn: "<terraform output for aws_wafv2_web_acl.autoforge.arn>"
  host: "autoforge.yourdomain.com"
```

---

## 5. GitHub Actions secrets (repo settings → Secrets and variables)

Add these (NOT AWS keys — you use OIDC, so none needed for AWS):
- `SONAR_TOKEN` — from your SonarQube/SonarCloud project
- `SONAR_HOST_URL` — e.g. `https://sonarcloud.io` or your self-hosted URL

Push to `main`. The pipeline runs, in order:
1. flake8 + pytest
2. SonarQube scan + quality gate (fails build on new vulnerabilities/smells)
3. Docker build → **Trivy scan** (fails build on CRITICAL/HIGH CVEs) → push to ECR
4. Terraform plan → manual approval gate → apply
5. `helm upgrade --install` to EKS (dev values, no secrets in the command)

---

## 6. Verify

```powershell
kubectl get pods -n autoforge
kubectl get externalsecret -n autoforge
kubectl get networkpolicy -n autoforge
kubectl logs -n autoforge deploy/autoforge-app
```

Then browse to `https://autoforge.yourdomain.com/login` — TLS should be
valid (ACM cert), and the WAF is blocking SQLi/XSS payloads automatically
(test with something like `' OR 1=1 --` in the username field — you should
get a 403 from WAF before it ever reaches Flask).

---

## What changed vs. your earlier setup (root-cause fixes)

| Old problem | Fix in this bundle |
|---|---|
| `values-dev.yaml` placeholders silently overwrote secrets on `helm upgrade` | DB creds removed entirely from all values files; ESO owns the Secret object |
| Username mismatch (`autoforge_admin` vs `admin`) | Single source of truth: `var.db_username` in Terraform → Secrets Manager → ESO. Never typed twice |
| Broad/shared IAM roles | Three scoped roles: EKS node, CI/CD (OIDC, resource-scoped), app pod (IRSA, read one secret) |
| No TLS, no WAF | ACM cert + WAF v2 (Common, SQLi, KnownBadInputs, rate-limit) attached to the ALB |
| Any pod could talk to any pod | Default-deny NetworkPolicy + explicit allow rules |
| No RBAC | Namespace-scoped Roles for app SA (near-zero), CI/CD deployer, and read-only developers |
| No vulnerability/quality gating | Trivy blocks CRITICAL/HIGH CVEs; SonarQube quality gate blocks vulnerabilities/high-complexity code — both fail the pipeline, not just warn |

---

## File map

```
autoforge/
├── app/                     # Flask application
│   ├── app.py, db.py, seed.py
│   ├── templates/, static/
│   ├── requirements.txt, Dockerfile
├── terraform/infra/         # RDS, IAM, Secrets Manager, ACM, WAF
├── helm/autoforge/          # K8s manifests via Helm
│   └── templates/           # deployment, service, ingress, rbac,
│                             # networkpolicy, externalsecret, hpa, seed-job
├── .github/workflows/ci-cd.yml
└── sonar-project.properties
```
