echo '-------Creating a GKE Cluster (typically in less than 10 mins)'
starttime=$(date +%s)
. setenv.sh
MY_PREFIX=$(echo $(whoami) | sed -e 's/\_//g' | sed -e 's/\.//g' | awk '{print tolower($0)}')
GCP_K8S_VERSION=$(gcloud container get-server-config --region $MY_REGION | grep $MY_K8S_VERSION | awk '{print $2}' | head -1)
gcloud container clusters create $MY_PREFIX-$MY_CLUSTER-$(date +%s) \
  --zone $MY_ZONE \
  --num-nodes 1 \
  --machine-type $MY_MACHINE_TYPE \
  --cluster-version=$GCP_K8S_VERSION \
  --no-enable-basic-auth \
  --addons=GcePersistentDiskCsiDriver \
  --enable-autoscaling --min-nodes 1 --max-nodes 3

echo '-------Creating a gke pd vsc'
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1beta1
kind: VolumeSnapshotClass
metadata:
  name: gke-pd-vsc
driver: pd.csi.storage.gke.io
deletionPolicy: Delete
EOF

echo '-------Annotate the GKE-PD CSI VSC'
kubectl annotate volumesnapshotclass gke-pd-vsc \
    k10.kasten.io/is-snapshot-class=true

echo '-------Install K10'
sa_key=$(base64 -w0 k10-sa-key.json)
kubectl create ns kasten-io
helm repo add kasten https://charts.kasten.io/
helm install k10 kasten/k10 --namespace=kasten-io \
  --set global.persistence.metering.size=1Gi \
  --set prometheus.server.persistentVolume.size=1Gi \
  --set global.persistence.catalog.size=1Gi \
  --set global.persistence.jobs.size=1Gi \
  --set global.persistence.logging.size=1Gi \
  --set secrets.googleApiKey=$sa_key \
  --set auth.tokenAuth.enabled=true \
  --set externalGateway.create=true

echo '-------Set the default ns to k10'
kubectl config set-context --current --namespace kasten-io

echo '-------Waiting for K10 services are up running'
kubectl wait --for=condition=ready --timeout=180s -n kasten-io pod -l component=catalog

echo '-------Output the Cluster ID, Web UI IP and token'
clusterid=$(kubectl get namespace default -ojsonpath="{.metadata.uid}{'\n'}")
echo "" | awk '{print $1}' > gke-token
echo My Cluster ID is $clusterid >> gke-token
k10ui=http://$(kubectl get svc gateway-ext | awk '{print $4}'|grep -v EXTERNAL)/k10/#
echo -e "\nLogin to K10 Web UI click here -->> $k10ui" >> gke-token
echo "" | awk '{print $1}' >> gke-token
sa_secret=$(kubectl get serviceaccount k10-k10 -o jsonpath="{.secrets[0].name}" --namespace kasten-io)
echo "Please enter below token to login" >> gke-token
echo "" | awk '{print $1}' >> gke-token
kubectl get secret $sa_secret --namespace kasten-io -ojsonpath="{.data.token}{'\n'}" | base64 --decode | awk '{print $1}' >> gke-token
echo "" | awk '{print $1}' >> gke-token

echo '-------Deploying a PostgreSQL database'
kubectl create namespace postgresql
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install --namespace postgresql postgres bitnami/postgresql --set persistence.size=1Gi

echo '-------Creating a GCS profile secret'
myproject=$(gcloud config get-value core/project)
kubectl create secret generic k10-gcs-secret \
      --namespace kasten-io \
      --from-literal=project-id=$myproject \
      --from-file=service-account.json=k10-sa-key.json

echo '-------Creating a GCS profile'
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: mygcs1
  namespace: kasten-io
spec:
  type: Location
  locationSpec:
    credential:
      secretType: GcpServiceAccountKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-gcs-secret
        namespace: kasten-io
    type: ObjectStore
    objectStore:
      name: $MY_PREFIX-$MY_BUCKET
      objectStoreType: GCS
      region: $MY_REGION
EOF

echo '------Create backup policies'
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: postgresql-backup
  namespace: kasten-io
spec:
  comment: ""
  frequency: "@hourly"
  actions:
    - action: backup
      backupParameters:
        profile:
          namespace: kasten-io
          name: $MY_OBJECT_STORAGE_PROFILE
    - action: export
      exportParameters:
        frequency: "@hourly"
        migrationToken:
          name: ""
          namespace: ""
        profile:
          name: $MY_OBJECT_STORAGE_PROFILE
          namespace: kasten-io
        receiveString: ""
        exportData:
          enabled: true
      retention:
        hourly: 0
        daily: 0
        weekly: 0
        monthly: 0
        yearly: 0
  retention:
    hourly: 4
    daily: 1
    weekly: 1
    monthly: 0
    yearly: 0
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - postgresql
EOF

echo '-------Kickoff the on-demand backup job'
sleep 5
cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-backup-
spec:
  subject:
    kind: Policy
    name: postgresql-backup
    namespace: kasten-io
EOF

echo '-------Accessing K10 UI'
cat gke-token

endtime=$(date +%s)
duration=$(( $endtime - $starttime ))
echo "-------Total time is $(($duration / 60)) minutes $(($duration % 60)) seconds."
echo "" | awk '{print $1}'
echo "-------Created by Yongkang"
echo "-------Email me if any suggestions or issues he@yongkang.cloud"
