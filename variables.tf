variable "region" {
  default = "us-east-1"
}

variable "instance_count" {
  default = 2
}

variable "ami_id" {
  default = "ami-08b5b3a93ed654d19"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "key_name" {
  description = "SSH Key"
  default = "my-new-key"
}