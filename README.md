Small discription about Task:

I created only one extra file provider.tf file for user details and rest all code present in main.tf not created any module for now.

Created one VPC which includes:
VPC CIDR Block
Subnet
Gateways
Route Table
Network Access Control Lists (ACLs)
Security Group

Created ASG with root volume and secondary volume.
ASG for automatically add and remove node as per requirement.
EC2 instance: connected with private subnet and created one load balancer which connected with public subnet.
Created one script which run to install apache service in ec2 instance.
Set cloudwatch for monitoring and management.
