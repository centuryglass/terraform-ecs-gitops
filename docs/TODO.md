# TODO:

## Misc. tasks:
- Budget permissions are very broadly scoped on both the AWS and GCP sides. For a personal project that's fine, but it wouldn't fly in a corporate environment. Consider making budget tracking something we only apply locally.


## Improvement priorities:

#### 1. *Implement branch protections*
Pushing changes directly to main should be blocked. PRs targeting main should only be allowed to merge when all checks pass and at least one reviewer approves the changes. This is easy to configure, and is an absolutely essential security step.

#### 2. *Set up a registered domain*
Using the default URL exposed by the CloudFront is fairly unprofessional, and custom domains can be relatively cheap. I would prioritize buying a custom domain through Amazon Route 53, and adjusting network configuration to use HTTPS traffic through that domain. I skipped this step only because DNS redirects are slow, and it would be unlikely that the domain would be up and running by the time this project is done.

#### 3. *Modularize terraform files and GitHub actions for multiple environments.*
At the very least, there should be two environments, one for developers and internal testing, and another for production traffic. Depending on business needs, we could eventually need any number of other environments. Environment-specific variable handling should be configured within GitHub Actions and in `/infra`. Build targets could be selected based on branch name or tags.

#### 4. *Set up a separate developer test environment.*
Once multi-environment deployment is configured, set up a second environment that updates when changes are pushed to a `dev` branch. Configuration could be largely the same, although resource use should stay minimal, and security rules should limit incoming traffic to an internal company VPN.

#### 5. *Expand logging and alerts.*
Email alerts are fine for now, but don't work for production. Slack notifications are an easy improvement for tracking builds, deployments, and incidents as a team. New Relic would be extremely useful for monitoring network trends and the like, and handling more complicated alert conditions. 

#### 6. *Add linting, testing, and security scans.*
Right now, the build process only checks to make sure the code compiles, and it doesn't even trigger until after code is already merged to main. We should know the code compiles, passes relevant tests, and doesn't contain any other notable issues before we're even allowed to merge the PR. `ci-build-push` should be divided into two steps: one that builds the code, runs tests, and caches the image in the GitHub Actions cache, running as soon as a PR is opened. The image should be pushed to ECR and deployed only once the PR is merged.

#### 7. *Set up a canary deployment pattern.*
Once more sophisticated logging and application behavior are present, deploying changes broadly across production all at once becomes an unnecessary risk. Instead of replacing the old container the moment the new one comes online, have both running in parallel for a half hour, with only five percent of traffic going to the new container. Developers can monitor the logs for new problems during this period and revert if anything turns up, reducing the chances of broad customer impact if changes contain uncaught bugs.

#### 8. *Kubernetes.*
This project absolutely does not need the overhead of an entire Kubernetes cluster, but Kubernetes is the gold standard for complex microservice architectures, and implementing it correctly would make this project a more useful template for larger works.
