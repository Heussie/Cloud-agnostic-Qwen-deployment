terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}

provider "google" {
  region      = var.region
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.gke.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.gke.master_auth.0.cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.gke.endpoint}"
    cluster_ca_certificate = base64decode(google_container_cluster.gke.master_auth.0.cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

resource "google_project" "sue_project" {
  name            = var.project_name
  project_id      = var.project_id
  org_id          = var.org_id
  billing_account = var.billing_account

  deletion_policy = "DELETE"
}

resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "serviceusage.googleapis.com"
  ])

  project = google_project.sue_project.project_id
  service = each.key
}

resource "google_compute_network" "vpc" {
  name                    = "sue-vpc"
  auto_create_subnetworks = false

  project = google_project.sue_project.project_id
}

resource "google_compute_subnetwork" "subnet" {
  name          = "gke-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region

  network = google_compute_network.vpc.id
  project = google_project.sue_project.project_id
}

resource "google_container_cluster" "gke" {
  name     = "sue-cluster"
  location = var.region

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  project = google_project.sue_project.project_id

  workload_identity_config {
    workload_pool = "${google_project.sue_project.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.services]
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "system-pool"
  location   = var.region
  cluster    = google_container_cluster.gke.name
  node_count = 2

  project = google_project.sue_project.project_id

  node_config {
    machine_type = "e2-standard-4"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = "cert-manager"
  create_namespace = true

  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.15.3"


  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [google_container_node_pool.primary_nodes]
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = "istio-system"
  create_namespace = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"

  depends_on = [google_container_node_pool.primary_nodes]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  name              = "istio-ingressgateway"
  namespace         = "istio-ingress"
  create_namespace  = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"

  depends_on = [helm_release.istiod]
}

resource "helm_release" "kserve_crds" {
  name              = "kserve-crds"
  namespace         = "kserve"
  create_namespace  = true

  repository = "oci://ghcr.io/kserve/charts"
  chart      = "kserve-crds"
  version    = "v0.15.0"

  depends_on = [
    helm_release.cert_manager,
    helm_release.istiod
  ]
}

resource "helm_release" "kserve" {
  name              = "kserve"
  namespace         = "kserve"

  repository = "oci://ghcr.io/kserve/charts"
  chart      = "kserve"
  version    = "v0.15.0"

  set {
    name  = "kserve.controller.gateway.ingressGateway.createGateway"
    value = "true"
  }

  depends_on = [helm_release.kserve_crds]
}

resource "kubernetes_namespace" "llm" {
  metadata {
    name = "llm"
  }

  depends_on = [helm_release.kserve]
}

resource "kubernetes_manifest" "qwen_llm" {
  manifest = {
    apiVersion = "serving.kserve.io/v1beta1"
    kind       = "InferenceService"

    metadata = {
      name      = "qwen-small"
      namespace = kubernetes_namespace.llm.metadata[0].name
    }

    spec = {
      predictor = {
        model = {
          modelFormat = {
            name = "huggingface"
          }

          storageUri = "hf://Qwen/Qwen2.5-0.5B-Instruct"

          args = [
            "--model_name=qwen-small"
          ]

          resources = {
            requests = {
              cpu    = "2"
              memory = "8Gi"
            }
            limits = {
              cpu    = "4"
              memory = "12Gi"
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kserve]
}