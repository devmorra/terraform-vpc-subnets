variable "initial_cidr_block" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 4
}

variable "subnet_capacity" {
  type    = number
  default = 256
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azRange    = range(0, var.az_count, 2) 
  numRange   = range(1, var.az_count * 2 + 1)
  azs        = data.aws_availability_zones.available.names
  mask_shift = 32 - ceil(log(var.subnet_capacity, 2)) - parseint(split("/", var.initial_cidr_block)[1], 10)
  subnet_definitions = [
    for n in local.numRange : {
      name       = join(" ", [n % 2 == 1 ? "Terraform public subnet" : "Terraform private subnet", tostring(ceil(n / 2))])
      cidr_block = cidrsubnet(var.initial_cidr_block, local.mask_shift, n)
      az         = local.azs[ceil(n / 2 - 1) % length(local.azs)]
      public     = n % 2 == 1 ? true : false
    }
  ]
}

output "subnet_defs" {
  value = local.subnet_definitions
}

resource "aws_vpc" "main" {
  cidr_block = var.initial_cidr_block
  tags = {
    Name = "Terraform VPC"
  }
}

resource "aws_subnet" "subnets" {
  for_each          = { for i, v in local.subnet_definitions : i => v }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.az
  map_public_ip_on_launch = each.value.public
  tags = {
    Name = each.value.name
  }
}

resource "aws_internet_gateway" "igw"{
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Terraform internet gateway"
  }
}

resource "aws_route_table" "public_routing_tables"{
  vpc_id = aws_vpc.main.id
  count  = var.az_count
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "Terraform public route table ${count.index + 1}"
  }
}

resource "aws_route_table" "private_routing_tables"{
  vpc_id = aws_vpc.main.id
  count  = var.az_count
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_gateways[tostring(count.index)].id
  }
  tags = {
    Name = "Terraform private route table ${count.index + 1}"
  }
}

resource "aws_route_table_association" "public_rt_associations"{
  count = var.az_count
  subnet_id = aws_subnet.subnets[count.index * 2].id
  route_table_id = aws_route_table.public_routing_tables[count.index].id
}

resource "aws_route_table_association" "private_rt_associations"{
  count = var.az_count
  subnet_id = aws_subnet.subnets[count.index * 2 + 1].id
  route_table_id = aws_route_table.private_routing_tables[count.index].id
}

resource "aws_eip" "nat_eips"{
  depends_on = [aws_internet_gateway.igw]
  count      = var.az_count
}

resource "aws_nat_gateway" "nat_gateways"{
  count = var.az_count
  subnet_id = aws_subnet.subnets[count.index * 2].id
  allocation_id = aws_eip.nat_eips[count.index].id
  tags = {
    Name = "Terraform NAT gateway ${count.index}"
  }
  depends_on = [aws_internet_gateway.igw]
}
