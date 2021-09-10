#-------Creating a Google Cloud Service Account"
myproject=$(gcloud config get-value core/project)
gcloud iam service-accounts create k10-yong-sa --display-name "K10 Service Account"
k10saemail=$(gcloud iam service-accounts list --filter "k10-yong-sa" --format="value(email)")
gcloud iam service-accounts keys create --iam-account=${k10saemail} k10-sa-key.json
gcloud projects add-iam-policy-binding ${myproject} --member serviceAccount:${k10saemail} --role "roles/compute.storageAdmin"
gcloud projects add-iam-policy-binding ${myproject} --member serviceAccount:${k10saemail} --role "roles/storage.admin"
