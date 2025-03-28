# Tekton Pipeline for Java WebApp

## Structure

### tasks/
Reusable Tekton tasks:
- `git-clone.yaml`: Clone the Git repo.
- `maven-build.yaml`: Compile and package Java `.war` file.
- `kaniko.yaml`: Build and push container image using Kaniko (rootless Dockerless build).

### pipeline.yaml
Defines the pipeline structure and task sequence:
1. Clone Git repo
2. Build WAR with Maven
3. Build and push image using Kaniko

### pipeline-run.yaml (not included here)
Use this file to manually trigger a `PipelineRun`.

---

## Notes

- You **must** grant the `pipeline` service account permission to use an appropriate SCC:
  
  ```bash
  oc adm policy add-scc-to-user anyuid -z pipeline -n java-pipeline
