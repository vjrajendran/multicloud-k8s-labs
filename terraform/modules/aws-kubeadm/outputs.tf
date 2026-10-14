output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "private_ips" {
  value = {
    master1 = aws_instance.master.private_ip
    client1 = aws_instance.workers[0].private_ip
    client2 = aws_instance.workers[1].private_ip
  }
}

# For each node's spec.providerID, which the cloud controller uses to find its instance
output "provider_ids" {
  value = {
    master1 = "aws:///${aws_instance.master.availability_zone}/${aws_instance.master.id}"
    client1 = "aws:///${aws_instance.workers[0].availability_zone}/${aws_instance.workers[0].id}"
    client2 = "aws:///${aws_instance.workers[1].availability_zone}/${aws_instance.workers[1].id}"
  }
}
