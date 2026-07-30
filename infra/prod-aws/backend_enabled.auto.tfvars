# On/off switch for the pay-per-hour backend tier (ALB + ECS/Fargate + the three
# interface VPC endpoints + the CloudFront /api/* origin & behavior). This is a
# committed *.auto.tfvars so CI reads it (terraform.tfvars is gitignored).
#
# To spin the backend UP: set this to true in a PR. aws-tf-plan will show the
# resources to add; merging runs aws-tf-apply and brings it online.
# To tear it back DOWN: set to false the same way. Returns to the ~$0/mo state.
#
# See variable "backend_enabled" in variables.tf.
backend_enabled = false
