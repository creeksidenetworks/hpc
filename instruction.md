Please create a bash script setup-ondemand.sh to install open ondemand server on a rocky linux 8 AMD64 server. it supports following commands
- install  # install use default conf file ./conf/hpc.conf. if not found, create an example file, and tell user to update and exit.
- cpn -add <cpn hostname or ip>  # add a cpn node to cluster
- cpn -remove <cpn hostname or ip>  # remove a cpn node from cluster
- update # add/remove cpn nodes per 

# install
- usage
```
./setup-hpc install -c <path to config directory>
```
- reference to /root/hpc-on-docker, which is docker based. 
- ./conf store all important configuration. if not exist, create it with sample conf files and exit.
- server is behind a nginx-proxy
- must be root to run this script
- server must join freeipa, if not joined, warn and exit
- create slurm user (1000:1000), check if it occupied, if yes, remove the existing user.
- detect if there is any existing installation, be graceful that do not overwrite existing installation.
- install all necessary linux packages, must include xfce desktop, GUI applications, EDA library, GTKwave etc. see ./hpc-on-docker/setup-cpn
- install open-ondemand, slurmctl and slurmsbd, xpra 
- use xpra html5 client to access xfce-desktop (desktop mode) and application (application window mode)
- implement oidc authentication
- add a timer to run slurm-ipa sync script <./scripts/sync-slurm-ipa.sh> every 10 minutes
- use this linux server as the only cpn node at the first time of install, all applications, shell access should be executed on this server. 
- config inter-active jobs menu, add an entry "Applications", allow user to launch applications in pull down menu. the applications are listed in ./conf/apps.conf. 
- open ondemand, 4.1, 
```bash
sudo rpm --import https://yum.osc.edu/ondemand/RPM-GPG-KEY-ondemand-SHA512
sudo dnf install https://yum.osc.edu/ondemand/4.1/ondemand-release-web-4.1-1.el10.noarch.rpm

sudo dnf install ondemand
```
- xpra 6.x
```
https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/rockylinux/xpra.repo
```
- config directory contents reference
/root/hpc-on-docker/config/oidc/oidc.conf
/root/hpc-on-docker/config/ipa/ipa.conf
/root/hpc-on-docker/build/hpc.conf

