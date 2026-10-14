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
