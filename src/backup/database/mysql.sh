#!/bin/bash
# Name:mysql.sh
# This is a ShellScript For Auto DB Backup and Delete old Backup
#
# create mysql backup user:
#   grant select,lock tables,show databases,show view,event,reload,super,file on *.* to 'mysqlbackuper'@'localhost' identified by 'PASSWORD';
#   flush privileges;
#

set -e

readonly BASE_PATH=$(cd `dirname $0`; pwd)
readonly ROOT_PATH=${BASE_PATH%%/backup/*}

source ${ROOT_PATH}/bin/ini-file.sh

readonly CONFIG_INI_FILE="${ROOT_PATH}/config.ini"
readonly BACKUP_PATH=$(get_field_value ${CONFIG_INI_FILE} backup path)
readonly BACKUP_KEEP_DAY=$(get_field_value ${CONFIG_INI_FILE} backup keep_day)
readonly BACKUP_USER=$(get_field_value ${CONFIG_INI_FILE} backup user)
readonly BACKUP_USER_GROUP=$(get_field_value ${CONFIG_INI_FILE} backup user_group)
readonly BACKUP_SYNC_ENTABLED=$(get_field_value ${CONFIG_INI_FILE} backup remote_sync)
readonly MYSQL_BIN_DIR=$(get_field_value ${CONFIG_INI_FILE} mysql bin_path)
readonly DB_HOST=$(get_field_value ${CONFIG_INI_FILE} mysql host)
readonly DB_PORT=$(get_field_value ${CONFIG_INI_FILE} mysql port)
readonly DB_SOCK=$(get_field_value ${CONFIG_INI_FILE} mysql sock)
readonly DB_USER=$(get_field_value ${CONFIG_INI_FILE} mysql user)
readonly DB_PASSWD=$(get_field_value ${CONFIG_INI_FILE} mysql password)
readonly IGONRE_TABLES=$(get_field_value ${CONFIG_INI_FILE} mysql igonre_tables)

readonly BACKUP_DIR="${BACKUP_PATH}/mysql/"
readonly BACKUP_SYNC_DIR="${BACKUP_PATH}/sync/mysql/"
readonly LOG_FILE="${ROOT_PATH}/logs/backup/mysql.log"


function make_mysql_connect() {
    if [ "$1" == "" ] || [ "${MYSQL_BIN_DIR}" == "" ]; then
        return 1
    fi

    local command_name=$1
    local command="${MYSQL_BIN_DIR}${command_name}"

    if [ "$1" != "mysqldump" ]; then
        if [ "${DB_USER}" != "" ]; then
            command="${command} -u${DB_USER}"
        fi

        if [ "${DB_HOST}" != "" ]; then
            command="${command} -h${DB_HOST}"
        fi

        if [ "${DB_PORT}" != "" ]; then
            command="${command} -P${DB_PORT}"
        fi

        if [ "${DB_PASSWD}" != "" ]; then
            command="${command} -p${DB_PASSWD}"
        fi

        if [ "${DB_SOCK}" != "" ]; then
            command="${command} -S ${DB_SOCK}"
        fi

        command="${command} --show-warnings=false "
    fi

    echo ${command}
    return 0
}

# list mysql database
function list_all_database() {
    if [ "${MYSQL_BIN_DIR}" == "" ]; then
        return 1
    fi

    local connect=$(make_mysql_connect mysql)
    local all_db=$(${connect} -Bse 'show databases')
    if [ "$?" == 0 ]; then
        echo ${all_db}
        return 0
    else
        reutrn 1
    fi
}

function backup() {
    if [ "$1" == "" ] || [ "${MYSQL_BIN_DIR}" == "" ]; then
        return 1
    fi

    if [ "${BACKUP_PATH}" == "" ]; then
        return 1
    fi

    if [ ! -d "${BACKUP_DIR}" ]; then
        mkdir -p ${BACKUP_DIR}
    fi

    local database_name=$1
    printf "find database: ${database_name} ..... " >> ${LOG_FILE}

    # filter: information_schema, performance_schema, test, mysql
    if [ "${database_name}" == "information_schema" ] || [ "${database_name}" == "performance_schema" ] \
        || [ "${database_name}" == "test" ] || [ "${database_name}" == "mysql" ]; then
        printf "[INGORE ]\n" >> ${LOG_FILE}
        return 0
    fi

    # todo ingore tables ...

    local connect=$(make_mysql_connect mysqldump)
    local commad="${connect} --routines --events ${database_name}"
    local yesterday=$(date -d "yesterday" +"%Y%m%d")

    # backup
    local flag="Y"
    local backup_file="${BACKUP_DIR}${database_name}_${yesterday}.sql.gz"
    # no safe
    # ${commad} | gzip > ${backup_file}
    local dump_flag_file="${ROOT_PATH}/runtime/backup.mysql.dumpflag"
    cat /dev/null > ${dump_flag_file}  #清空dumpflagfile（用来临时存放备份结果状态）
    (${commad} || echo "N" > ${dump_flag_file}) | (gzip || echo "N" > ${dump_flag_file} ) > ${backup_file}
    if [ -e "${dump_flag_file}" ] && [ -s "${dump_flag_file}" ]; then
        flag="N"
        read flag < ${dump_flag_file}
    fi

    if [ "${flag}" == "Y" ]; then
        chmod 600 ${backup_file} > /dev/null 2>&1

        printf "[SUCCESS]\n" >> ${LOG_FILE}
    else
        rm -f ${backup_file} > /dev/null 2>&1
        echo ${database_name} >> ${BACKUP_DIR}.$(date +"%Y%m%d").error

        printf "[FAILD  ]\n" >> ${LOG_FILE}
        return 0
    fi

    return 0
}

function compress() {
    local yesterday=$(date -d "yesterday" +"%Y%m%d")
    local compress_file="${yesterday}.tar.gz"

    printf "compress backup to tar.gz ... " >> ${LOG_FILE}

    # count
    local count=$(ls ${BACKUP_DIR} | grep ${yesterday}.sql.gz | wc -l)
    if [ "${count}" -lt 1 ]; then
        printf "[NOFOUND]\n" >> ${LOG_FILE}
        return 1
    fi

    tar -zcf ${compress_file} ${BACKUP_DIR}*_${yesterday}.sql.gz > /dev/null 2>&1
    if [ "$?" == 0 ]; then
        printf "[SUCCESS]\n" >> ${LOG_FILE}
    else
        printf "[FAILD  ]\n" >> ${LOG_FILE}
        return 1
    fi

    # not found compress file.
    if [ ! -f ${compress_file} ]; then
        return 1
    fi

    printf "move backup compress file to sync dir ... " >> ${LOG_FILE}
    mv ${compress_file} ${BACKUP_SYNC_DIR}  > /dev/null 2>&1
    if [ "$?" == 0 ]; then
        printf "[SUCCESS]\n" >> ${LOG_FILE}
    else
        printf "[FAILD  ]\n" >> ${LOG_FILE}
        return 1
    fi

    # write finished time, for local backup.
    echo $(date +"%Y%m%d") > ${BACKUP_SYNC_DIR}.finished

    # change the backup file permissions
    if [ "${BACKUP_USER}" != "" -a "${BACKUP_USER_GROUP}" != "" ]; then
        printf "change compress file own ..." >> ${LOG_FILE}
        chown -R ${BACKUP_USER}.${BACKUP_USER_GROUP} ${BACKUP_SYNC_DIR} > /dev/null 2>&1
        if [ "$?" == 0 ]; then
            printf "[SUCCESS]\n" >> ${LOG_FILE}
        else
            printf "[FAILD  ]\n" >> ${LOG_FILE}
        fi
    fi

    return 0
}

function lock() {
    local lock_file="${ROOT_PATH}/runtime/.backup.mysql.lock"

    if [ "$1" == "" ]; then
        printf "Please Usage: lock [start | end]\n"
        return 1
    elif [ "$1" == "start" ]; then
        # lock
        if [ -f "${lock_file}" ]; then
            printf "The running!\n"
            exit 1
        fi
        touch .lock
    elif [ "$1" == "end" ]; then
        # delete lock file
        rm -f ${lock_file} > /dev/null 2>&1
    fi
}

function clear() {
    if [ "${BACKUP_PATH}" == "" ]; then
        return 1
    fi

    local keep=${BACKUP_KEEP_DAY}
    if [ "${keep}" -lt 1 ]; then
        keep=7
    fi

    # find & delete
    find ${BACKUP_DIR} -name "*.sql.gz" -type f -mtime +${keep} -exec rm {} \; > /dev/null 2>&1
    if [ "${BACKUP_SYNC_ENTABLED}" != "false" ]; then
        find ${BACKUP_SYNC_DIR} -name "*.tar.gz" -type f -mtime +${keep} -exec rm {} \; > /dev/null 2>&1
    fi

    # delete lock file
    lock end
    return 0
}

function init() {
    # check log file dir
    local log_path=$(dirname ${LOG_FILE})
    if [ ! -d ${log_path} ]; then
        mkdir -p ${log_path} > /dev/null 2>&1
        if [ "$?" != 0 ]; then
            return 1
        fi
    fi

    # check backup path
    if [ "${BACKUP_PATH}" == "" ] || [ ! -d ${BACKUP_PATH} ]; then
        echo "[ERROR] not dir backup_path(=${BACKUP_PATH})" >> ${LOG_FILE}
        return 1
    fi

    # check backup down path
    if [ "${BACKUP_SYNC_ENTABLED}" != "false" ]; then
        if [ "${BACKUP_SYNC_DIR}" == "" ] || [ ! -d ${BACKUP_SYNC_DIR} ]; then
            echo "[ERROR] not dir sync_path(=${BACKUP_SYNC_DIR})" >> ${LOG_FILE}
            return 1
        fi
    fi

    # lock
    lock start
    return 0
}


# Backup Done.
init
ALL_DATABASE=$(list_all_database)
if [ "$?" == 0 ]; then
    for db in ${ALL_DATABASE}
    do
        backup ${db}
    done

    # write finished time.
    echo $(date +"%Y%m%d") > ${BACKUP_DIR}.finished

    # Compress backup file
    if [ "${BACKUP_SYNC_ENTABLED}" != "false" ]; then
        compress
    fi

    # Clear runtime file
    clear
fi

exit 0
