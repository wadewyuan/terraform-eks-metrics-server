resource "kubernetes_config_map_v1_data" "aws-auth" {

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }


  data = {
    mapUsers = "${file("${path.module}/aws-auth.yml")}"
  }
}
