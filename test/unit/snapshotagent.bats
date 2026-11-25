#!/usr/bin/env bats

load _helpers

@test "snapshotagent/cronjob: disabled by default" {
  cd `chart_dir`
  local
  local actual=$( (helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    . || echo "---") | tee /dev/stderr |
    yq 'length > 0' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "snapshotagent/cronjob: namespace:" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.metadata.namespace' | tee /dev/stderr)
  [ "${actual}" = "foo" ]
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.namespace=bar' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.metadata.namespace' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "snapshotagent/cronjob: annotations:" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.annotations.example\.com/foo=bar' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.metadata.annotations["example.com/foo"]' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "snapshotagent/cronjob: schedule:" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.schedule=0 0 0 0 0' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.schedule' | tee /dev/stderr)
  [ "${actual}" = "0 0 0 0 0" ]

}

@test "snapshot/cronjob: extraVolumes" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.extraVolumes[0].name=my-volume' \
    --set 'snapshotAgent.extraVolumes[0].emptyDir={}' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.volumes[1].name' | tee /dev/stderr)
  [ "${actual}" = "my-volume" ]
}

@test "snapshot/cronjob: image overwrite" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.image.repository=my-repo' \
    --set 'snapshotAgent.image.tag=my-tag' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' | tee /dev/stderr)
  [ "${actual}" = "my-repo:my-tag" ]
}

@test "snapshot/cronjob: resources" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.resources.requests.cpu=100m' \
    --set 'snapshotAgent.resources.requests.memory=100Mi' \
    --set 'snapshotAgent.resources.limits.cpu=1000m' \
    --set 'snapshotAgent.resources.limits.memory=1Gi' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.cpu' | tee /dev/stderr)
  [ "${actual}" = "100m" ]
}

@test "snapshot/cronjob: configuration: s3CredentialsSecret" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.s3CredentialsSecret=creds' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "AWS_SECRET_ACCESS_KEY") | .valueFrom.secretKeyRef.name' | tee /dev/stderr)
  [ "${actual}" = "creds" ]
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.s3CredentialsSecret=creds' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "AWS_ACCESS_KEY_ID") | .valueFrom.secretKeyRef.name' | tee /dev/stderr)
  [ "${actual}" = "creds" ]
}

@test "snapshot/cronjob: s3CredentialsSecret optional (not rendered by default)" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq -r '[.spec.jobTemplate.spec.template.spec.containers[0].env // [] | .[] | select(.name == "AWS_ACCESS_KEY_ID" or .name == "AWS_SECRET_ACCESS_KEY")] | length' | tee /dev/stderr)
  [ "${actual}" = "0" ]
}

#--------------------------------------------------------------------
# CronJob / Job options

@test "snapshot/cronjob: concurrencyPolicy defaults to Forbid" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq -r '.spec.concurrencyPolicy' | tee /dev/stderr)
  [ "${actual}" = "Forbid" ]
}

@test "snapshot/cronjob: concurrencyPolicy can be set" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.concurrencyPolicy=Replace' \
    . | tee /dev/stderr |
    yq -r '.spec.concurrencyPolicy' | tee /dev/stderr)
  [ "${actual}" = "Replace" ]
}

@test "snapshot/cronjob: history limits and deadlines not set by default" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq '[.spec.startingDeadlineSeconds, .spec.successfulJobsHistoryLimit, .spec.failedJobsHistoryLimit, .spec.jobTemplate.spec.backoffLimit, .spec.jobTemplate.spec.activeDeadlineSeconds] | map(. == null) | all' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "snapshot/cronjob: history limits and deadlines can be set (including 0)" {
  cd `chart_dir`
  local object=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.startingDeadlineSeconds=300' \
    --set 'snapshotAgent.successfulJobsHistoryLimit=0' \
    --set 'snapshotAgent.failedJobsHistoryLimit=2' \
    --set 'snapshotAgent.backoffLimit=1' \
    --set 'snapshotAgent.activeDeadlineSeconds=600' \
    . | tee /dev/stderr)
  [ "$(echo "$object" | yq -r '.spec.startingDeadlineSeconds')" = "300" ]
  [ "$(echo "$object" | yq -r '.spec.successfulJobsHistoryLimit')" = "0" ]
  [ "$(echo "$object" | yq -r '.spec.failedJobsHistoryLimit')" = "2" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.backoffLimit')" = "1" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.activeDeadlineSeconds')" = "600" ]
}

@test "snapshot/cronjob: imagePullSecrets from global" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.imagePullSecrets[0]=regcred' \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.imagePullSecrets[0].name' | tee /dev/stderr)
  [ "${actual}" = "regcred" ]
}

@test "snapshot/cronjob: image defaults to upstream 0.4.5" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' | tee /dev/stderr)
  [ "${actual}" = "ghcr.io/openbao/openbao-snapshot-agent:0.4.5" ]
}

@test "snapshot/cronjob: snapshotDirSizeLimit" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.snapshotDirSizeLimit=2Gi' \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.volumes[0].emptyDir.sizeLimit' | tee /dev/stderr)
  [ "${actual}" = "2Gi" ]
}

@test "snapshot/cronjob: extra labels and annotations on CronJob, Job and Pod" {
  cd `chart_dir`
  local object=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.extraLabels.c=cron' \
    --set 'snapshotAgent.job.extraLabels.j=job' \
    --set 'snapshotAgent.job.annotations.ja=job' \
    --set 'snapshotAgent.pod.extraLabels.p=pod' \
    --set 'snapshotAgent.pod.annotations.pa=pod' \
    . | tee /dev/stderr)
  [ "$(echo "$object" | yq -r '.metadata.labels.c')" = "cron" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.metadata.labels.j')" = "job" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.metadata.annotations.ja')" = "job" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.metadata.labels.p')" = "pod" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.metadata.annotations.pa')" = "pod" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.metadata.labels["app.kubernetes.io/component"]')" = "snapshot-agent" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.metadata.labels.component')" = "snapshot-agent" ]
}

@test "snapshot/cronjob: nodeSelector and affinity" {
  cd `chart_dir`
  local object=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.nodeSelector.disk=ssd' \
    --set 'snapshotAgent.affinity.nodeAffinity.foo=bar' \
    . | tee /dev/stderr)
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.spec.nodeSelector.disk')" = "ssd" ]
  [ "$(echo "$object" | yq -r '.spec.jobTemplate.spec.template.spec.affinity.nodeAffinity.foo')" = "bar" ]
}

@test "snapshot/cronjob: nodeSelector and affinity not set by default" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq '.spec.jobTemplate.spec.template.spec | (.nodeSelector == null) and (.affinity == null)' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

#--------------------------------------------------------------------
# TLS

@test "snapshot/cronjob: TLS Secret mounted when TLS is on" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.tlsDisable=false' \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "tls") | .secret.secretName' | tee /dev/stderr)
  [ "${actual}" = "release-name-openbao-tls" ]
}

@test "snapshot/cronjob: TLS Secret not mounted in external mode" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.tlsDisable=false' \
    --set 'global.externalBaoAddr=https://bao.example.com' \
    . | tee /dev/stderr |
    yq -r '[.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "tls")] | length' | tee /dev/stderr)
  [ "${actual}" = "0" ]
}

@test "snapshot/configmap: BAO_CACERT not set in external mode" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.tlsDisable=false' \
    --set 'global.externalBaoAddr=https://bao.example.com' \
    . | tee /dev/stderr |
    yq -r '.data.BAO_CACERT' | tee /dev/stderr)
  [ "${actual}" = "null" ]
}

@test "snapshot/serviceaccount: disabled" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.serviceAccount.create=false' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.serviceAccountName' | tee /dev/stderr)
  [ "${actual}" = "default" ]
}

@test "snapshot/serviceaccount: own name" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-cronjob.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.serviceAccount.create=true' \
    --set 'snapshotAgent.serviceAccount.name=my-sa' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.spec.jobTemplate.spec.template.spec.serviceAccountName' | tee /dev/stderr)
  [ "${actual}" = "my-sa" ]
}

@test "snapshot/configmap: configuration: s3Host" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.s3Host=s3.us-west-1.amazonaws.com' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.S3_HOST' | tee /dev/stderr)
  [ "${actual}" = "s3.us-west-1.amazonaws.com" ]
}

@test "snapshot/configmap: configuration: s3Bucket" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.s3Bucket=my-bucket' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.S3_BUCKET' | tee /dev/stderr)
  [ "${actual}" = "my-bucket" ]
}

@test "snapshot/configmap: configuration: s3Uri" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.s3Uri=s3://my-bucket' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.S3_URI' | tee /dev/stderr)
  [ "${actual}" = "s3://my-bucket" ]
}

@test "snapshot/configmap: configuration: s3ExpireDays" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set-string 'snapshotAgent.config.s3ExpireDays=1' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.S3_EXPIRE_DAYS' | tee /dev/stderr)
  [ "${actual}" = 1 ]
}

@test "snapshot/configmap: configuration: s3cmdExtraFlag" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.s3cmdExtraFlag=-q' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.S3CMD_EXTRA_FLAG' | tee /dev/stderr)
  [ "${actual}" = "-q" ]
}

@test "snapshot/configmap: configuration: baoAuthPath" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.baoAuthPath=jwt' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.BAO_AUTH_PATH' | tee /dev/stderr)
  [ "${actual}" = "jwt" ]
}

@test "snapshot/configmap: configuration: baoRole" {
  cd `chart_dir`
  local actual=$(
    helm template \
      --show-only templates/snapshotagent-configmap.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.config.baoRole=backup' \
      --namespace foo \
      . | tee /dev/stderr |
      yq -r '.data.BAO_ROLE' | tee /dev/stderr
  )
  [ "${actual}" = "backup" ]
}

@test "snapshot/configmap: configuration: baoAddr" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.BAO_ADDR' | tee /dev/stderr)
  [ "${actual}" = "http://release-name-openbao.foo.svc:8200" ]
}

@test "snapshot/configmap: specify baoAddr" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'server.ha.enabled=true' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.BAO_ADDR' | tee /dev/stderr)
  [ "${actual}" = "http://release-name-openbao-active.foo.svc:8200" ]
}

@test "snapshot/configmap: configuration: externalBaoAddr" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'global.externalBaoAddr=https://bao.example.com' \
    --namespace foo \
    . | tee /dev/stderr |
    yq -r '.data.BAO_ADDR' | tee /dev/stderr)
  [ "${actual}" = "https://bao.example.com" ]
}

@test "snapshot/configmap: optional agent variables not set by default" {
  cd `chart_dir`
  local actual=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    . | tee /dev/stderr |
    yq '.data | has("BAO_NAMESPACE") or has("BAO_AUTH_NAMESPACE") or has("BAO_SECRET_PATH") or has("TOKEN_PATH")' | tee /dev/stderr)
  [ "${actual}" = "false" ]
}

@test "snapshot/configmap: baoNamespace, baoAuthNamespace, baoSecretPath, tokenPath" {
  cd `chart_dir`
  local object=$(helm template \
    --show-only templates/snapshotagent-configmap.yaml \
    --set 'snapshotAgent.enabled=true' \
    --set 'snapshotAgent.config.baoNamespace=ns1' \
    --set 'snapshotAgent.config.baoAuthNamespace=ns2' \
    --set 'snapshotAgent.config.baoSecretPath=kv/s3' \
    --set 'snapshotAgent.config.tokenPath=/var/run/token' \
    . | tee /dev/stderr)
  [ "$(echo "$object" | yq -r '.data.BAO_NAMESPACE')" = "ns1" ]
  [ "$(echo "$object" | yq -r '.data.BAO_AUTH_NAMESPACE')" = "ns2" ]
  [ "$(echo "$object" | yq -r '.data.BAO_SECRET_PATH')" = "kv/s3" ]
  [ "$(echo "$object" | yq -r '.data.TOKEN_PATH')" = "/var/run/token" ]
}

#--------------------------------------------------------------------
# extraEnvironmentVars

@test "snapshot/cronjob: specify extraEnvironmentVar" {
  cd `chart_dir`
  local object=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.extraEnvironmentVars.BAO_FOO=bar' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].env' | tee /dev/stderr )

  local actual=$(echo "$object" |
     yq -r 'map(select(.name=="BAO_FOO")) | .[0].name' | tee /dev/stderr)
  [ "${actual}" = "BAO_FOO" ]

  local actual=$(echo "$object" |
      yq -r 'map(select(.name=="BAO_FOO")) | .[0].value' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

#--------------------------------------------------------------------
# extraSecretEnvironmentVars

@test "snapshot/cronjob: set extraSecretEnvironmentVars" {
  cd `chart_dir`
  local object=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml  \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[0].envName=ENV_FOO_0' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[0].secretName=secret_name_0' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[0].secretKey=secret_key_0' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[1].envName=ENV_FOO_1' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[1].secretName=secret_name_1' \
      --set 'snapshotAgent.extraSecretEnvironmentVars[1].secretKey=secret_key_1' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].env' | tee /dev/stderr)

  local value=$(echo "$object" |
      yq -r 'map(select(.name=="ENV_FOO_0")) | .[] .valueFrom.secretKeyRef.name' | tee /dev/stderr)
  [ "${value}" = "secret_name_0" ]

  local value=$(echo "$object" |
      yq -r 'map(select(.name=="ENV_FOO_0")) | .[] .valueFrom.secretKeyRef.key' | tee /dev/stderr)
  [ "${value}" = "secret_key_0" ]

  local value=$(echo "$object" |
      yq -r 'map(select(.name=="ENV_FOO_1")) | .[] .valueFrom.secretKeyRef.name' | tee /dev/stderr)
  [ "${value}" = "secret_name_1" ]

  local value=$(echo "$object" |
      yq -r 'map(select(.name=="ENV_FOO_1")) | .[] .valueFrom.secretKeyRef.key' | tee /dev/stderr)
  [ "${value}" = "secret_key_1" ]
}

#--------------------------------------------------------------------
# extraVolumeMounts

@test "snapshot/cronjob: specify extraVolumeMounts" {
  cd `chart_dir`
  local object=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.extraVolumeMounts[0].mountPath=/mnt' \
      --set 'snapshotAgent.extraVolumeMounts[0].name=secret' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts' | tee /dev/stderr )

  local actual=$(echo "$object" |
     yq -r '.[1].mountPath' | tee /dev/stderr)
  [ "${actual}" = "/mnt" ]

  local actual=$(echo "$object" |
      yq -r '.[1].name' | tee /dev/stderr)
  [ "${actual}" = "secret" ]
}

#--------------------------------------------------------------------
# securityContext

@test "snapshot/cronjob: default securityContext.pod" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.securityContext' | tee /dev/stderr)
  [ ! "${actual}" = "null" ]
}

@test "snapshot/cronjob: default securityContext.container" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].securityContext' | tee /dev/stderr)
  [ ! "${actual}" = "null" ]
}

@test "snapshot/cronjob: specify securityContext.pod yaml" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.securityContext.pod.foo=bar' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.securityContext.foo' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "snapshot/cronjob: specify securityContext.container yaml" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.securityContext.container.foo=bar' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].securityContext.foo' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "snapshot/cronjob: specify securityContext.pod yaml string" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.securityContext.pod=foo: bar' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.securityContext.foo' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

@test "snapshot/cronjob: specify securityContext.container yaml string" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.securityContext.container=foo: bar' \
      . | tee /dev/stderr |
      yq -r '.spec.jobTemplate.spec.template.spec.containers[0].securityContext.foo' | tee /dev/stderr)
  [ "${actual}" = "bar" ]
}

#--------------------------------------------------------------------
# tolerations

@test "snapshot/cronjob: tolerations not set by default" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      . | tee /dev/stderr |
      yq '.spec.jobTemplate.spec.template.spec | .tolerations? == null' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "snapshot/cronjob: tolerations can be set as string" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set 'snapshotAgent.tolerations=foobar' \
      . | tee /dev/stderr |
      yq '.spec.jobTemplate.spec.template.spec.tolerations == "foobar"' | tee /dev/stderr)
  [ "${actual}" = "true" ]
}

@test "snapshot/cronjob: tolerations can be set as YAML" {
  cd `chart_dir`
  local actual=$(helm template \
      --show-only templates/snapshotagent-cronjob.yaml \
      --set 'snapshotAgent.enabled=true' \
      --set "snapshotAgent.tolerations[0].foo=bar,snapshotAgent.tolerations[1].baz=qux" \
      . | tee /dev/stderr |
      yq -o json -I0 '.spec.jobTemplate.spec.template.spec.tolerations' | tee /dev/stderr)
  [ "${actual}" = '[{"foo":"bar"},{"baz":"qux"}]' ]
}
