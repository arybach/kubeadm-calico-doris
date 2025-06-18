require 'yaml'

CONFIG = Hash[
  File.readlines("config.env").map { |l|
    next if l.strip.empty? || l.strip.start_with?("#")
    key, value = l.strip.split("=", 2)
    [key, value]
  }.compact
]

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.synced_folder ".", "/vagrant", type: "virtualbox", SharedFoldersEnableSymlinksCreate: false

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  nodes = [
    { name: "master", ip: CONFIG["MASTER_IP"], role: "control-plane" },
    { name: "worker1", ip: CONFIG["WORKER1_IP"], role: "worker" },
    { name: "worker2", ip: CONFIG["WORKER2_IP"], role: "worker" },
  ]

  nodes.each_with_index do |node, i|
    config.vm.define node[:name] do |vm_config|
      vm_config.vm.hostname = node[:name]

      vm_config.vm.network "private_network",
                           ip: node[:ip],
                           virtualbox__hostonlyif: "vboxnet2",
                           auto_config: true

      vm_config.vm.network "private_network",
                           ip: "#{CONFIG['METALLB_BASE']}.#{240 + i}",
                           virtualbox__hostonlyif: "vboxnet0",
                           auto_config: true

      vm_config.vm.provider "virtualbox" do |vb|
        if node[:role] == "control-plane"
          vb.memory = 8192
          vb.cpus = 2
        else # for FE - at least 16GB recommended. For BE - memory should be at least 4 times the number of CPU cores 
          vb.memory = 24576
          vb.cpus = 6
        end

        vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
        vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]
      end

      vm_config.vm.provision "shell", privileged: true, inline: <<-SHELL
        export NODE_IP=#{node[:ip]}
        export K8S_IFACE=#{CONFIG["K8S_IFACE"]}
        export METALLB_START=#{CONFIG["METALLB_START"]}
        export METALLB_END=#{CONFIG["METALLB_END"]}
        export POD_CIDR=#{CONFIG["POD_CIDR"]}

        if [ "#{node[:role]}" = "control-plane" ]; then
          bash -eu /vagrant/install-calico.sh "$NODE_IP" "$K8S_IFACE" "$METALLB_START" "$METALLB_END"
        else
          bash -eu /vagrant/join.sh "$NODE_IP" || (echo '[!] retrying join in 10s...' && sleep 10 && bash -eu /vagrant/join.sh "$NODE_IP")
        fi
      SHELL
    end
  end
end

system("bash ./parse-env.sh")
