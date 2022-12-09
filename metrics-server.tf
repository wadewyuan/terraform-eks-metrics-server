# This is meant to create create an equivalent metrics-server on AWS EKS as defined in:
# https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.20.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
  }
}

# Get terraform state from the EKS cluster provision project
data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = "terraform-wy"
    key            = "learn-terraform-kubernetes"
    region         = "us-west-2"
    dynamodb_table = "dynamodb-state-locking"
  }
}

# Retrieve EKS cluster information
provider "aws" {
  region = data.terraform_remote_state.eks.outputs.region
}

data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.eks.outputs.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      data.aws_eks_cluster.cluster.name
    ]
  }
}

resource "kubernetes_service_account_v1" "metrics-server" {
  metadata {
    name = "metrics-server"
    labels = {
      k8s-app = "metrics-server"
    }
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role" "aggregated-metrics-reader" {
  metadata {
    name = "system:aggregated-metrics-reader"
    labels = {
      k8s-app                                        = "metrics-server"
      "rbac.authorization.k8s.io/aggregate-to-admin" = "true"
      "rbac.authorization.k8s.io/aggregate-to-edit"  = "true"
      "rbac.authorization.k8s.io/aggregate-to-view"  = "true"
    }
  }
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role" "metrics-server" {
  metadata {
    name = "system:metrics-server"
    labels = {
      k8s-app = "metrics-server"
    }
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/metrics"]
    verbs      = ["get"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "metrics-server-auth-reader" {
  metadata {
    name      = "metrics-server-auth-reader"
    namespace = "kube-system"
    labels = {
      k8s-app = "metrics-server"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "extension-apiserver-authentication-reader"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "metrics-server"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "auth-delegator" {
  metadata {
    name = "metrics-server:system:auth-delegator"
    labels = {
      k8s-app = "metrics-server"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "metrics-server"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding_v1" "metrics-server" {
  metadata {
    name = "system:metrics-server"
    labels = {
      k8s-app = "metrics-server"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:metrics-server"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "metrics-server"
    namespace = "kube-system"
  }
}

resource "kubernetes_service_v1" "metrics-server" {
  metadata {
    name = "metrics-server"
    labels = {
      k8s-app = "metrics-server"
    }
    namespace = "kube-system"
  }

  spec {
    selector = {
      k8s-app = "metrics-server"
    }

    port {
      port        = 443
      target_port = "https"
      protocol    = "TCP"
      name        = "https"
    }
  }
}

resource "kubernetes_deployment_v1" "metrics-server" {
  metadata {
    name      = "metrics-server"
    namespace = "kube-system"
    labels = {
      k8s-app = "metrics-server"
    }
  }
  spec {
    selector {
      match_labels = {
        k8s-app = "metrics-server"
      }
    }
    strategy {
      rolling_update {
        max_unavailable = 0
      }
    }
    template {
      metadata {
        labels = {
          k8s-app = "metrics-server"
        }
      }
      spec {
        container {
          image             = "k8s.gcr.io/metrics-server/metrics-server:v0.6.2"
          name              = "metrics-server"
          args              = ["--cert-dir=/tmp", "--secure-port=4443", "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname", "--kubelet-use-node-status-port", "--metric-resolution=15s"]
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 4443
            name           = "https"
            protocol       = "TCP"
          }
          liveness_probe {
            failure_threshold = 3
            http_get {
              path   = "/livez"
              port   = "https"
              scheme = "HTTPS"
            }
            period_seconds = 10
          }
          readiness_probe {
            failure_threshold = 3
            http_get {
              path   = "/readyz"
              port   = "https"
              scheme = "HTTPS"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "200Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 1000
          }
          volume_mount {
            mount_path = "/tmp"
            name       = "tmp-dir"
          }
        }
        node_selector = {
          "kubernetes.io/os" = "linux"
        }
        priority_class_name  = "system-cluster-critical"
        service_account_name = "metrics-server"
        volume {
          empty_dir {}
          name = "tmp-dir"
        }
      }
    }
  }
}

resource "kubernetes_api_service_v1" "metrics-server" {
  metadata {
    labels = {
      k8s-app = "metrics-server"
    }
    name = "v1beta1.metrics.k8s.io"
  }
  spec {
    group                    = "metrics.k8s.io"
    group_priority_minimum   = 100
    insecure_skip_tls_verify = true
    service {
      name      = "metrics-server"
      namespace = "kube-system"
    }
    version          = "v1beta1"
    version_priority = 100
  }
}