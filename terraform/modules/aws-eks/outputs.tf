output "endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "ca" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}
