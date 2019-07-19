// Terraform plugin for creating random ids
resource "random_id" "instance_id" {
 byte_length = 8
}

// A single Google Cloud Engine instance
resource "google_compute_instance" "default" {
 name         = "my-vm-${random_id.instance_id.hex}"
 machine_type = "f1-micro"
 zone         = "us-west1-a"

 boot_disk {
   initialize_params {
     image = "${lookup(var.IMAGE,"${var.REGION}-${var.ZONE}")}"
   }
 }

 network_interface {
   network = "default"

   access_config {
     // Include this section to give the VM an external ip address
   }
 }
 metadata = {
   ssh-keys = "${var.VM_USERNAME}:${file("~/.ssh/id_rsa.pub")}"
 }

  // Install software using remote-exec provisioner
 provisioner "remote-exec" {
   inline = [
      "sudo apt-get -y install tcpdump"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"
  }
 }

  // Upload a file using file provisioner
 provisioner "file" {
       source      = "../scripts/my_script.sh"
       destination = "/tmp/my_script.sh"

    connection {
      type     = "ssh"
      host     = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
      user     = "${var.VM_USERNAME}"
      private_key = "${file("~/.ssh/id_rsa")}"
   }
 }

  // Execute a script remotely using remote-exec provisioner
 provisioner "remote-exec" {
   inline = [
     "chmod a+x /tmp/my_script.sh",
      "/tmp/my_script.sh"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"
  }
 }

  // Create the Ansible inventory locally using the local-exec provisioner 
 provisioner "local-exec" {
    command = "echo '[all]' > inventory.txt && echo ${google_compute_instance.default.network_interface.0.access_config.0.nat_ip} >> inventory.txt"
 }

  // Provision using Ansible with local-exec provisioner
 provisioner "local-exec" {
    command = "sleep 40; ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u ${var.VM_USERNAME} --private-key ~/.ssh/id_rsa -i inventory.txt ../playbooks/ansible-playbook.yml" 
 }
}

output "ip" {
    value = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
}

resource "google_compute_attached_disk" "disk1_attachment" {
  disk = "${google_compute_disk.disk1.self_link}"
  instance = "${google_compute_instance.default.self_link}"

  provisioner "remote-exec" {
   inline = [
     "sleep 60",
     "sudo parted /dev/sdb --script -- mklabel msdos",
     "sudo parted -a optimal /dev/sdb mkpart primary 0% 1024MB",
     "sudo mkfs.ext4 /dev/sdb1",
     "sudo mkdir dir /mnt/test-disk",
     "sudo mount -t ext4 /dev/sdb1 /mnt/test-disk"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"
  }
 }
}

// Two Google Cloud Engine instances

// Web server instance
resource "google_compute_instance" "webserver" {
 name         = "fe-${random_id.random_id.hex}"
 machine_type = "f1-micro"
 zone         = "${var.REGION}-${var.ZONE}"
 tags          = ["ssh","http"]
 provisioner "remote-exec" {
   inline = [
     "sudo apt-get install -y nginx"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"
  }
 }

 provisioner "file" {
       source      = "../config/nginx.conf"
       destination = "/tmp/demo"

    connection {
      type     = "ssh"
      host     = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
      user     = "${var.VM_USERNAME}"
      private_key = "${file("~/.ssh/id_rsa")}"
   }
}

provisioner "remote-exec" {
   inline = [
     "sudo cp /tmp/demo /etc/nginx/sites-available/demo",
     "sudo chmod 644 /etc/nginx/sites-available/demo",
     "sudo rm -f /etc/nginx/sites-enabled/default",
     "sudo ln -s /etc/nginx/sites-available/demo /etc/nginx/sites-enabled/demo",
     "sudo /etc/init.d/nginx restart"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"
  }
 }


 boot_disk {
   initialize_params {
    image = "${lookup(var.IMAGE,"${var.REGION}-${var.ZONE}")}"
   }
 }

 network_interface {
   subnetwork = "${google_compute_subnetwork.public_subnet.self_link}"
   network_ip = "${var.WEBSERVER_IP}"
   access_config {
     // Include this section to give the VM an external ip address
   }
 }

  metadata = {
   ssh-keys = "${var.VM_USERNAME}:${file("~/.ssh/id_rsa.pub")}"
 }

  
}

output "webserver-ip" {
    value = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
}



// App server instance
resource "google_compute_instance" "appserver" {
 name         = "be-${random_id.random_id.hex}"
 machine_type = "f1-micro"
 zone         = "${var.REGION}-${var.ZONE}"
 /*tags          = ["ssh","http"]*/
 provisioner "remote-exec" {
   inline = [
      "curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -",
      "sudo apt-get install -y build-essential nodejs",
      "mkdir ~/myapp",
      "npm install express --prefix ~/myapp --save",
      "npm install forever --prefix ~/myapp --save",
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.appserver.network_interface.0.network_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"

    bastion_host = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
    bastion_private_key = "${file("~/.ssh/id_rsa")}"
    bastion_port = "22"
    bastion_user = "${var.VM_USERNAME}"
  }
 }

 provisioner "file" {
    source      = "../app/"
    destination = "~/myapp/"

    connection {
      type     = "ssh"
      host     = "${google_compute_instance.appserver.network_interface.0.network_ip}"
      user     = "${var.VM_USERNAME}"
      private_key = "${file("~/.ssh/id_rsa")}"

      bastion_host = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
      bastion_private_key = "${file("~/.ssh/id_rsa")}"
      bastion_port = "22"
      bastion_user = "${var.VM_USERNAME}"
   }
}

provisioner "remote-exec" {
   inline = [
      "sudo chmod a+x /home/${var.VM_USERNAME}/myapp/start_app.sh",
      "/home/${var.VM_USERNAME}/myapp/start_app.sh",
      "sleep 10"
   ]

   connection {
    type     = "ssh"
    host     = "${google_compute_instance.appserver.network_interface.0.network_ip}"
    user     = "${var.VM_USERNAME}"
    private_key = "${file("~/.ssh/id_rsa")}"

    bastion_host = "${google_compute_instance.webserver.network_interface.0.access_config.0.nat_ip}"
    bastion_private_key = "${file("~/.ssh/id_rsa")}"
    bastion_port = "22"
    bastion_user = "${var.VM_USERNAME}"
  }
 }



 boot_disk {
   initialize_params {
    image = "${lookup(var.IMAGE,"${var.REGION}-${var.ZONE}")}"
   }
 }

 network_interface {
   subnetwork = "${google_compute_subnetwork.private_subnet.self_link}"
   network_ip = "${var.APPSERVER_IP}"
   /*access_config {
     // Include this section to give the VM an external ip address
   }*/
 }

  metadata = {
   ssh-keys = "${var.VM_USERNAME}:${file("~/.ssh/id_rsa.pub")}"
 }
}