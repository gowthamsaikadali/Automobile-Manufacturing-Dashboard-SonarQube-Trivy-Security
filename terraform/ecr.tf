resource "aws_ecr_repository" "app_repo" {
  name                 = var.project_name
  image_tag_mutability = "IMMUTABLE" # blocks anyone from silently overwriting a tag like "v1"

  image_scanning_configuration {
    scan_on_push = true # basic vulnerability scan on every push, on top of the CI Trivy scan
  }
}

resource "aws_ecr_lifecycle_policy" "app_repo_lifecycle" {
  repository = aws_ecr_repository.app_repo.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app_repo.repository_url
}
