#!/bin/bash

set -euo pipefail

############################################
# CONFIGURAÇÃO
############################################

ZABBIX_MAJOR="5.0"
ZABBIX_AGENT_VERSION="5.0.42"

CONFIG_FILE="/etc/zabbix/zabbix_agentd.conf"

ZABBIX_REPO_EL8="https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/rhel/8/x86_64/zabbix-release-${ZABBIX_MAJOR}-1.el8.noarch.rpm"
ZABBIX_AGENT_EL7="https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/rhel/7/x86_64/zabbix-agent-${ZABBIX_AGENT_VERSION}-1.el7.x86_64.rpm"

############################################
# VARIÁVEIS
############################################

HOSTNAME=""
SERVER=""
ACTIVE_SERVER=""
PORT="10050"

METADATA=""
ADD_OS_ID=false
ADD_OS_NAME=false
ADD_ASTERISK=false
LOCATION=""
QUICKSETUP=false
DRY_RUN=false

OS_ID=""
OS_VERSION=""
OS_MAJOR=""
INSTALL_METHOD=""

############################################
# LOG
############################################

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

############################################
# ROOT CHECK
############################################

if [[ $EUID -ne 0 ]]; then
log_error "Execute como root"
exit 1
fi

############################################
# HELP
############################################

show_help() {

cat <<EOF

Uso:

--hostname NOME_DO_HOST
--server IP_DO_ZABBIX
--active-server IP_DO_ZABBIX
--port PORTA

METADATA

--metadata TEXTO
--metadata-os-id
--metadata-os-name
--metadata-asterisk
--location STRING

AUTOMAÇÃO

--quicksetup
--dry-run

Exemplo simples:

install.sh --hostname srv-asterisk --server 10.0.0.10

10.0.0.10 = IP do servidor Zabbix

Exemplo completo:

install.sh \
--hostname asterisk-01 \
--server 10.0.0.10 \
--active-server 10.0.0.10 \
--port 10050 \
--metadata "cliente:isp1" \
--location dc-sp

EOF

exit 0
}

############################################
# VALIDAÇÃO IP
############################################

valid_server() {

local value=$1

# IP
local ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

# hostname ou FQDN
local host_regex="^([a-zA-Z0-9][-a-zA-Z0-9]*\.)*[a-zA-Z0-9][-a-zA-Z0-9]*$"

if [[ $value =~ $ip_regex ]] || [[ $value =~ $host_regex ]]; then
return 0
fi

return 1

}

############################################
# ARGUMENTOS
############################################

if [[ $# -eq 0 ]]; then
show_help
fi

while [[ $# -gt 0 ]]; do
case $1 in

--hostname)
HOSTNAME="$2"
shift 2
;;

--server)
SERVER="$2"
shift 2
;;

--active-server)
ACTIVE_SERVER="$2"
shift 2
;;

--port)
PORT="$2"
shift 2
;;

--metadata)
METADATA="$2"
shift 2
;;

--metadata-os-id)
ADD_OS_ID=true
shift
;;

--metadata-os-name)
ADD_OS_NAME=true
shift
;;

--metadata-asterisk)
ADD_ASTERISK=true
shift
;;

--location)
LOCATION="$2"
shift 2
;;

--quicksetup)
QUICKSETUP=true
shift
;;

--dry-run)
DRY_RUN=true
shift
;;

-h|--help)
show_help
;;

*)
log_error "Argumento inválido: $1"
exit 1
;;

esac
done

############################################
# INPUT CHECK
############################################

if [[ -z "$HOSTNAME" || -z "$SERVER" ]]; then
log_error "hostname e server são obrigatórios"
exit 1
fi

if ! valid_server "$SERVER"; then
log_error "Valor inválido para --server (use IP ou domínio)"
exit 1
fi

if [[ -z "$ACTIVE_SERVER" ]]; then
ACTIVE_SERVER="$SERVER"
fi

############################################
# DETECTAR OS
############################################

detect_os() {

. /etc/os-release

OS_ID=$ID
OS_VERSION=$VERSION_ID
OS_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)

}

############################################
# MÉTODO INSTALAÇÃO
############################################

set_install_method() {

if [[ "$OS_ID" == "centos" && "$OS_MAJOR" == "7" ]]; then
INSTALL_METHOD="centos7"
else
INSTALL_METHOD="el8"
fi

log_info "Sistema detectado: $OS_ID $OS_VERSION"

}

############################################
# REPOSITÓRIO
############################################

configure_repo() {

if [[ "$INSTALL_METHOD" == "el8" ]]; then

log_info "Instalando repo Zabbix"

$DRY_RUN || rpm -Uvh "$ZABBIX_REPO_EL8" || true

fi

}

############################################
# INSTALAÇÃO AGENT
############################################

install_agent() {

if rpm -q zabbix-agent >/dev/null 2>&1; then
log_info "zabbix-agent já instalado"
return
fi

log_info "Instalando zabbix-agent"

if [[ "$INSTALL_METHOD" == "centos7" ]]; then

$DRY_RUN || rpm -Uvh "$ZABBIX_AGENT_EL7"
$DRY_RUN || yum install -y zabbix-agent

else

$DRY_RUN || dnf clean all
$DRY_RUN || dnf install -y zabbix-agent

fi

}

############################################
# METADATA
############################################

build_metadata() {

CUSTOM_METADATA="os:linux"

if $QUICKSETUP; then
ADD_OS_ID=true
ADD_OS_NAME=true
ADD_ASTERISK=true
fi

if $ADD_OS_NAME; then
OSNAME=$(grep ^NAME= /etc/os-release | cut -d= -f2 | tr -d '"')
CUSTOM_METADATA="$CUSTOM_METADATA osname:$OSNAME"
fi

if $ADD_OS_ID; then
OSID=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
CUSTOM_METADATA="$CUSTOM_METADATA osid:$OSID"
fi

if $ADD_ASTERISK; then

if command -v asterisk >/dev/null; then
AST=$(asterisk -V | awk '{print $2}')
CUSTOM_METADATA="$CUSTOM_METADATA ast:$AST"
else
log_warn "asterisk não encontrado"
fi

fi

if [[ -n "$LOCATION" ]]; then
CUSTOM_METADATA="$CUSTOM_METADATA location:$LOCATION"
fi

if [[ -n "$METADATA" ]]; then
CUSTOM_METADATA="$CUSTOM_METADATA $METADATA"
fi

CUSTOM_METADATA=$(echo "$CUSTOM_METADATA" | tr '[:upper:]' '[:lower:]')

}

############################################
# CONFIGURAR AGENT
############################################

configure_agent() {

log_info "Configurando agent"

$DRY_RUN || sed -i "s|^Server=.*|Server=$SERVER|" $CONFIG_FILE
$DRY_RUN || sed -i "s|^ServerActive=.*|ServerActive=$ACTIVE_SERVER|" $CONFIG_FILE
$DRY_RUN || sed -i "s|^Hostname=.*|Hostname=$HOSTNAME|" $CONFIG_FILE
$DRY_RUN || sed -i "s|^ListenPort=.*|ListenPort=$PORT|" $CONFIG_FILE

if grep -q "^HostMetadata=" $CONFIG_FILE; then
$DRY_RUN || sed -i "s|^HostMetadata=.*|HostMetadata=$CUSTOM_METADATA|" $CONFIG_FILE
else
$DRY_RUN || echo "HostMetadata=$CUSTOM_METADATA" >> $CONFIG_FILE
fi

}

############################################
# FIREWALL
############################################

configure_firewall() {

if command -v firewall-cmd >/dev/null; then

log_info "Configurando firewall"

$DRY_RUN || firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
$DRY_RUN || firewall-cmd --reload >/dev/null 2>&1 || true

fi

}

############################################
# SERVICE
############################################

start_service() {

log_info "Iniciando serviço"

$DRY_RUN || systemctl enable zabbix-agent

if ! $DRY_RUN; then
systemctl restart zabbix-agent || {
log_error "falha ao iniciar zabbix-agent"
exit 1
}
fi

}

############################################
# EXECUÇÃO
############################################

detect_os
set_install_method

configure_repo
install_agent

build_metadata
configure_agent

configure_firewall
start_service

log_info "--------------------------------"
log_info "Zabbix Agent instalado"
log_info "Hostname: $HOSTNAME"
log_info "Server: $SERVER"
log_info "Active: $ACTIVE_SERVER"
log_info "Porta: $PORT"
log_info "Metadata: $CUSTOM_METADATA"
log_info "--------------------------------"