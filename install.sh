#!/bin/bash
# Refatoração do script de NETINSTALL para instalação SEM INTERAÇÃO DO USUÁRIO.

# Variáveis para armazenar os valores padrão
CURRDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZABBIX_CONFIG_FILE=zabbix_agentd.conf
ZABBIX_INSTALL_FOLDER=/etc/zabbix
ZABBIX_CONFIG_FILE=$ZABBIX_INSTALL_FOLDER/$ZABBIX_CONFIG_FILE

ZABBIX_AGENT_VERSION="5.0.42"
ZABBIX_AGENT_RPM="https://repo.zabbix.com/zabbix/5.0/rhel/7/x86_64/zabbix-agent-$ZABBIX_AGENT_VERSION-1.el7.x86_64.rpm"

# LOGGING
LOG_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOGFILE_NAME="zabbix-installer" # Nome (prefixo) pro arquivo de log. "log-0000-11-22.log"
LOGFILE="$LOGFILE_NAME-$(date '+%Y-%m-%d').log"
if ! [ -f "$LOGFILE" ]; then # checa se o arquivo de log já existe
        echo -e "[$LOG_TIMESTAMP] Iniciando novo logfile" > $LOGFILE
fi

# DECLARAÇÃO DE FUNÇÕES ÚTEIS <--------------------->
log () {
    if [ -z $2 ]; then
        local muted=false
    else
        local muted=true
    fi
    echo -e "[$LOG_TIMESTAMP] $1" >> $LOGFILE
    if ! $muted; then
        echo -e "[$LOG_TIMESTAMP] $1" # Comentando pra não atrapalhar nas funções.
    fi
}

# ----------------------------------------------------------------------------------------- #
# Tratação de argumentos.
#

show_help() {
    cat << EOF
Uso: 
sudo bash $CURRDIR/$0 -s IP -a IP --hostname NOME
sudo bash $CURRDIR/$0 -s IP -a IP --hostname NOME --quicksetup
sudo bash $CURRDIR/$0 [opções...]

Opções:

CONFIGURAÇÕES PRINCIPAIS DO ZABBIX
 -H, --hostname <STRING>             *Hostname do HOST que será adicionado ao Zabbix Server.
 -s, --server <IP>                   *Endereço IP ou DNS do Servidor Zabbix.
 -a, --active-server <IP>            Endereço IP ou DNS do Servidor para checks Ativos.
 
 MANIPULAÇÃO DA METADATA
 --comment-hostmetadataitem          Comenta o parâmetro "HostMetadataItem" do arquivo de configuração.
 --metadata="<STRING>"               Repassa meta-dados customizados, para adicionar ao arquivo de configuração.
 --metadata-asterisk                 Meta-dado pré-setado para obter a versão do asterisk no padrão "ast:<valor>".
 --metadata-os-id                    Meta-dado pré-setado para obter o ID do sistema operacional. Padrão "OSid:<valor>".
 --metadata-os-name                  Meta-dado pré-setado para obter o nome do sistema operacional. Padrão "OSNAME:<valor>".
 --location <STRING>                 Meta-dado pré-setado recebendo 1 argumento. Padrão "location:<STRING>".

EXTRAS
 --quicksetup                        Substituto para todas as outras opções exceto as obrigatórias.
 --no-sudo                           Não adicionar o usuário "zabbix" à lista de usuários sudo. O usuário "zabbix"
                                     precisa de permissões sudoer pra executar scripts no host.
 -h, --help                          Exibe este menu de ajuda.
EOF
}

if ! [[ $# -gt 0 ]]; then
    #  TRATAMENTO CASO SEJA EXECUTADO SEM ARGUMENTOS
    if [ ${#args[@]} -eq 0 ]; then
        show_help
        exit 0
    fi
fi

declare -A args
args+=()

# Necessário para não haver erros de duplicação, adicionando mais de uma vez à mesma var.
function add_arg() 
{
    local ARGUMENT=$1
    local VALUE=$2

    if [ ! ${args[$ARGUMENT]} ]; then
        if $DEBUG_MODE; then
            log "$DEBUG [${FUNCNAME[0]}] $ARGUMENT -> $VALUE"
        fi
        args+=( [$ARGUMENT]=$2 )
        return 0
    else
        if $DEBUG_MODE; then
            log "$WARN [${FUNCNAME[0]}] $ARGUMENT -> $VALUE (Ignoring repeating argument. Current value: ${args[$ARGUMENT]})"
        fi
        return 1
    fi
}

# Processa os argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--hostname)
            shift
            add_arg "HOSTNAME" $1
        ;;
        -s|--server)
            shift
            add_arg "ZABBIX_SERVER" $1
        ;;
        -a|--active-server)
            shift
            add_arg "ZABBIX_ACTIVE_SERVER" $1
        ;;
        -sa|-as)
            shift
            add_arg "ZABBIX_SERVER" $1
            add_arg "ZABBIX_ACTIVE_SERVER" $1
        ;;
        -L|--location)
            shift
            add_arg "METADATA_LOCATION" $1
        ;;
        --metadata=*)
            add_arg "METADATA" "${1#*=}"
        ;;
        --quick|--quicksetup)
            add_arg "ADD_METADATA_ASTERISK_VERSION" true
            add_arg "ADD_METADATA_OS_ID" true
            add_arg "ADD_METADATA_OS_NAME" true
            add_arg "COMMENT_HOSTMETADATAITEM_IF_UNCOMMENTED" true
        ;;
        --metadata-asterisk)
            add_arg "ADD_METADATA_ASTERISK_VERSION" true
        ;;
        --metadata-os-id)
            add_arg "ADD_METADATA_OS_ID" true
        ;;
        --metadata-os-name)
            add_arg "ADD_METADATA_OS_NAME" true
        ;;
        --comment-hostmetadataitem)
            add_arg "COMMENT_HOSTMETADATAITEM_IF_UNCOMMENTED" true
        ;;
        --no-sudo)
            add_arg "SUDOER" false
        ;;
        -h|--help)
            show_help
            exit 0
        ;;
        *)
            # Argumento desconhecido
            echo "FATAL: Argumento inválido: $1"
            exit 1
        ;;
    esac
    shift
done

# ----------------------------------------------------------------------------------------- #
# Funções utilitárias.
#


# simply: Primeiro verifica se $2 existe, e então busca texto $1 dentro do arquivo $2.
# param 1 ; Texto a ser pesquisado
# param 2 ; Local onde $1 será pesquisado
# return  ; boolean (true/false)
function text_in_file()
{
    TEXT_TO_SEARCH=$1
    FILE_TO_SEARCH=$2

    if [ -f $FILE_TO_SEARCH ]; then
        cat $FILE_TO_SEARCH | grep "$TEXT_TO_SEARCH" > /dev/null 2>&1
        return $?
    else # file does not exist
        return 1
    fi
}


# simply: Retorna o texto, com cor.
# param 1 ; Cor que deseja utilizar
# param 2 ; Texto que deseja colorir
# return  ; $2, porém formatado com cor $1
# Deve ser chamado em subshell. 
# Exemplo de uso: echo "isso é um teste com $(colorir 'vermelho' 'a cor vermelha')"
function colorir() 
{
    declare -A cores
    local cores=(
        [preto]="0;30"
        [vermelho]="0;31"
        [verde]="0;32"
        [amarelo]="0;33"
        [azul]="0;34"
        [magenta]="0;35"
        [ciano]="0;36"
        [branco]="0;37"
        [preto_claro]="1;30"
        [vermelho_claro]="1;31"
        [verde_claro]="1;32"
        [amarelo_claro]="1;33"
        [azul_claro]="1;34"
        [magenta_claro]="1;35"
        [ciano_claro]="1;36"
        [branco_claro]="1;37"
    )

    local cor=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local texto=$2
    local string='${cores['"\"$cor\""']}'
    eval "local cor_ansi=$string"
    local cor_reset="\e[0m"

    if [[ -z "$cor_ansi" ]]; then
        cor_ansi=${cores["branco"]}  # Cor padrão, caso a cor seja inválida
    fi

    # Imprimir o texto com a cor selecionada
    echo -e "\e[${cor_ansi}m${texto}${cor_reset}"
}

# ----------------------------------------------------------------------------------------- #
# Sub-Util Functions ( Funções utilitárias específicas pra este script )
#

function is_valid_hostname() 
{
    local hostname="$1"
    if [[ $hostname =~ ^[a-zA-Z0-9.-]+$ ]]; then
        return 0  # O hostname é válido
    else
        return 1  # O hostname contém caracteres inválidos
    fi
}

# Verifica se a escrita do IP está correta
is_valid_ip() {
    local ip="$1"
    local ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

    if [[ $ip =~ $ip_regex ]]; then
        return 0  # O endereço IP é válido
    else
        return 1  # O endereço IP está em um formato inválido
    fi
}

rpm_is_installed () {
    local var=$(rpm -qa | grep -i $1)
    if [[ "$var" = "" ]]; then
        return 1
    else
        return 0
    fi
}

# ----------------------------------------------------------------------------------------- #
# MAIN/SUB-ACTIONS
#

clear_agent_rpm(){
    yum remove -y $ZABBIX_RPM_INSTALLED
    if ! [ $? -eq 0 ]; then
        log "FATAL: $FUNCNAME: Não foi possível deletar a RPM $ZABBIX_RPM_INSTALLED"
        exit 1
    fi
}

install_rpm_and_agent(){
    log "DEBUG: install_rpm_and_agent: Instalando \"rpm -Uvh $ZABBIX_AGENT_RPM\""
    sudo rpm -Uvh $ZABBIX_AGENT_RPM
    if ! [ $? -eq 0 ]; then
        log "FATAL: $FUNCNAME: Não foi possível instalar a RPM $ZABBIX_AGENT_RPM"
        exit 1
    fi

    log "DEBUG: $FUNCNAME: Instalando \"yum -y install zabbix-agent-$ZABBIX_AGENT_VERSION-1.el7.x86_64\""
    sudo yum -y install zabbix-agent-$ZABBIX_AGENT_VERSION-1.el7.x86_64
    if ! [ $? -eq 0 ]; then
        log "FATAL: $FUNCNAME: install_rpm_and_agent: Não foi possível instalar zabbix-agent-$ZABBIX_AGENT_VERSION-1.el7.x86_64 através do yum. "
        exit 1
    fi
}

# ----------------------------------------------------------------------------------------- #
# MAIN ACTIONS
#

function check_inputs()
{
    if [ ${args[HOSTNAME]} = "" ]; then
        echo "FATAL: $FUNCNAME: Argumento obrigatório: HOSTNAME"
        exit 1
    elif ! is_valid_hostname ${args[HOSTNAME]}; then
        echo "FATAL: $FUNCNAME: Hostname inválido. '${args[HOSTNAME]}'"
        exit 1
    elif [ ${args[ZABBIX_SERVER]} = "" ]; then
        echo "FATAL: $FUNCNAME: Argumento obrigatório: ZABBIX SERVER"
        exit 1
    else
    :
    fi

    HOSTNAME=${args[HOSTNAME]}
    ZABBIX_SERVER=${args[ZABBIX_SERVER]}

    if ! ${args[SUDOER]}; then
        NEED_SUDO=false
    else
        NEED_SUDO=true
    fi
}

function install_agent()
{
    echo "<#> <#> <#> <#> <#> <#> <#> <#> <#> INSTALLING AGENT <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#>"

    if rpm_is_installed "zabbix.*agent-"; then # [ zabbix6.0-agent-6... // zabbix-agent-5... ] Preciso desse "-" no final para ele não pegar o "zabbix.*agent2-X.X.X"

        ZABBIX_RPM_INSTALLED=$(rpm -qa | grep -i "zabbix.*agent-")
        if [[ ! "$ZABBIX_RPM_INSTALLED" =~ ^zabbix-agent-5\.0.* ]]; then # Se não for o Zabbix 5
            log "DEBUG: $FUNCNAME: RPM -> $(colorir "vermelho_claro" "$ZABBIX_RPM_INSTALLED") (não é a versão esperada 6.0.X). Tentando reinstalar a RPM."
            clear_agent_rpm
            install_rpm_and_agent
        fi
        log "DEBUG: $FUNCNAME: RPM -> $(colorir "verde_claro" "$ZABBIX_RPM_INSTALLED")"
    else
        install_rpm_and_agent
    fi

    if ! rpm_is_installed "zabbix.*agent"; then
        log "FATAL: $FUNCNAME: Parece que mesmo após o fluxo de instalação da RPM/ZA, não foi instalado. Melhor verificar. (Possibilidade de ter havido um conflito e a reinstalação da RPM falhou)"
    fi

    # Instalando o Zabbix Agent
    log "DEBUG: $FUNCNAME: systemctl start zabbix-agent."
    sudo systemctl start zabbix-agent
}

function edit_config_file()
{
    echo "<#> <#> <#> <#> <#> <#> <#> <#> <#> EDITING CONFIG FILES <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#>"

    if ! [ -d $ZABBIX_INSTALL_FOLDER ]; then
        log "FATAL: $FUNCNAME: Diretório esperado de instalação do Zabbix-Agent \"$ZABBIX_INSTALL_FOLDER\" não existe."
        exit 1
    fi

    if ! [ -f $ZABBIX_CONFIG_FILE ]; then
        log "FATAL: $FUNCNAME: Arquivo esperado de configuração do Zabbix-Agent \"$ZABBIX_INSTALL_FOLDER\" não existe."
        exit 1
    fi

    declare -A parameter_exist
    declare -A parameter_value

    parameter_has_duplicate() {
        # Esta função acrescenta ao array associativo 'parameter_exist'
        local PARAMETER=$1
        local QTY_MATCH_LINES=$(cat $ZABBIX_CONFIG_FILE | grep -i "^$PARAMETER=" | wc -l)

        if [[ $QTY_MATCH_LINES > 1 ]]; then
            #log "FATAL: parameter_has_duplicate: Há diversas ocorrências do parâmetro '$PARAMETER'. ($QTY_MATCH_LINES)"
            return 0
        elif [[ $QTY_MATCH_LINES < 1 ]]; then
            #log "DEBUG: parameter_has_duplicate: Parâmetro '$PARAMETER' não existe. ($QTY_MATCH_LINES)"
            parameter_exist[$PARAMETER]+=false
            return 1
        else
            #log "DEBUG: parameter_has_duplicate: Parâmetro '$PARAMETER' é único. ($QTY_MATCH_LINES)"
            parameter_exist[$PARAMETER]+=true
            return 1
        fi
    }

    parameter_empty() {
        # Esta função acrescenta ao array associativo 'parameter_value'
        local PARAMETER=$1
        local PARAMETER_VALUE=$(cat $ZABBIX_CONFIG_FILE | grep -i "^$PARAMETER=" | awk -F"$PARAMETER=" '{print $2}')
        if [ -z "$PARAMETER_VALUE" ]; then
            return 0
        else
            parameter_value[$PARAMETER]+=$PARAMETER_VALUE
            return 1
        fi

    }

    check_parameter() {
        local PARAMETER=$1
        if ! parameter_has_duplicate "$PARAMETER"; then
            if parameter_empty "$PARAMETER"; then
                if ! ${parameter_exist[$PARAMETER]}; then
                    log "DEBUG: $FUNCNAME: '$PARAMETER' não está sendo setado."
                else
                    log "DEBUG: $FUNCNAME: '$PARAMETER' está vazio."
                fi
                
            else
                log "DEBUG: $FUNCNAME: '$PARAMETER' tem valor: ${parameter_value[$PARAMETER]}"
            fi
        else
            log "FATAL: $FUNCNAME: '$PARAMETER' tem duplicatas."
            exit 1
        fi
    }

    set_parameter() {
        local PARAMETER=$1
        local VALUE=$2

        if ${parameter_exist[$PARAMETER]}; then
            if [[ "${parameter_value[$PARAMETER]}" != "" ]]; then
                if ! [ "${parameter_value[$PARAMETER]}" = "$VALUE" ]; then
                    # Valor diferente do esperado: edito pro correto.
                    sed -i "s~$PARAMETER=${parameter_value[$PARAMETER]}~$PARAMETER=$VALUE~g" $ZABBIX_CONFIG_FILE
                else
                    # Valor bate com o esperado: não faço nada.
                    :
                fi
            else
                # Parâmetro existe e não tem valor: edito adicionando valor correto.
                sed -i "s~$PARAMETER=~$PARAMETER=$VALUE~g" $ZABBIX_CONFIG_FILE
            fi
        else
            # Parâmetro não existe: adiciono junto com o valor correto.
            echo "$PARAMETER=$VALUE" | tee -a $ZABBIX_CONFIG_FILE
        fi
    }

    prepare_custom_metadata() {

        add_custom_metadata () {
            NEW_METADATA=$1
            CUSTOM_METADATA+="$NEW_METADATA "
        }

        if [ ${args[COMMENT_HOSTMETADATAITEM_IF_UNCOMMENTED]} ] ; then
            if text_in_file "^HostMetadataItem=" "$ZABBIX_CONFIG_FILE"; then
                sed -i "s~HostMetadataItem=~#HostMetadataItem=~g" $ZABBIX_CONFIG_FILE
                log "O parâmetro \"HostMetadataItem\" foi comentado!"
            fi
        fi

        # ADICIONANDO AS METADATAS A PARTIR DAQUI

        add_custom_metadata "os:linux" # Informando ao servidor que essa é uma máquina Linux duh...

        if [ ${args[ADD_METADATA_OS_NAME]} ]; then
            OS_NAME=$(cat /etc/os-release | grep "^NAME=" | awk -F"NAME=" '{print $2}' | sed 's/"//g')
            add_custom_metadata "OSNAME:$OS_NAME"
        fi

        if [ ${args[ADD_METADATA_OS_ID]} ]; then
            OS_ID=$(cat /etc/os-release | grep "^ID=" | awk -F"ID=" '{print $2}' | sed 's/"//g')
            add_custom_metadata "OSid:$OS_ID"
        fi


        if [ ${args[ADD_METADATA_ASTERISK_VERSION]} ]; then
            ASTERISK_VERSION=$(asterisk -V | awk -F"Asterisk " '{print $2}')
            add_custom_metadata "ast:$ASTERISK_VERSION"
        fi

        log "[DEBUG] Metadata Location: ${args[METADATA_LOCATION]}"
        if [ -n "$args[METADATA_LOCATION]" ]; then
            add_custom_metadata "location:${args[METADATA_LOCATION]}"
        fi

        add_custom_metadata "${args[METADATA]}" # Adicionando metadados especiais repassados pelo --metadata=""

        if [[ ${#CUSTOM_METADATA} -gt 255 ]]; then
            log "FATAL: Metadados grandes demais. (${#CUSTOM_METADATA}>255) (METADATA: $CUSTOM_METADATA)"
            exit 1
        fi
    }

    check_parameter "Server"
    check_parameter "ServerActive"
    check_parameter "Hostname"
    check_parameter "HostMetadata"

    prepare_custom_metadata
    set_parameter "Server" "${args[ZABBIX_SERVER]}"
    set_parameter "ServerActive" "${args[ZABBIX_ACTIVE_SERVER]}"
    set_parameter "Hostname" "${args[HOSTNAME]}"
    set_parameter "HostMetadata" "$CUSTOM_METADATA"

}

function add_zabbix_to_sudo()
{
    if ! text_in_file "%zabbix ALL=(ALL) NOPASSWD: ALL" "/etc/sudoers"; then
        log "[DEBUG] Adicionando como SUDOER"
        echo '%zabbix ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers > /dev/null 2>&1 # Adicionando ZABBIX à lista de sudoers
    fi
}

function post_install()
{
    echo "<#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#> <#>"

    # Ajustes finais
    sudo systemctl restart zabbix-agent
    sudo systemctl enable zabbix-agent
}

function bye()
{
    log "$(colorir "verde" "Instalação concluida")!"
}


# ----------------------------------------------------------------------------------------- #
# MAIN SCRIPT
#

check_inputs

install_agent
edit_config_file
if [ ${args[SUDOER]} ]; then
    add_zabbix_to_sudo
fi
post_install
bye