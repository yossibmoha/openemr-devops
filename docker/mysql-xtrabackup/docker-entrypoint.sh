#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [[ "${1:0:1}" = '-' ]]; then
    set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
    case "${arg}" in
        -'?'|--help|--print-defaults|-V|--version)
            wantHelp=1
            break
            ;;
    esac
done

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [[ "${!var:-}" ]] && [[ "${!fileVar:-}" ]]; then
        echo >&2 "error: both ${var} and ${fileVar} are set (but are exclusive)"
        exit 1
    fi
    local val="${def}"
    if [[ "${!var:-}" ]]; then
        val="${!var}"
    elif [[ "${!fileVar:-}" ]]; then
        val="$(< "${!fileVar}")"
    fi
    export "${var}"="${val}"
    unset "${fileVar}"
}

_check_config() {
    toRun=( "$@" --verbose --help )
    if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
        echo 'ERROR: mysqld failed while attempting to check config'
        echo "command was: '${toRun[*]}'"
        echo "${errors}"
        exit 1
        fi >&2
    }

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
    local conf="$1"; shift
    "$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "'"${conf}"'" { print $2; exit }'
}

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "${wantHelp}" -a "$(id -u)" = '0' ]; then
    _check_config "$@"
    DATADIR="$(_get_config 'datadir' "$@")"
    mkdir -p "${DATADIR}"
    chown -R mysql:mysql "${DATADIR}"

    if [[ -f /root/pending-restore ]]; then
        /root/xrecovery-final.sh
    fi

    exec gosu mysql "${BASH_SOURCE}" "$@"
fi

if [ "$1" = 'mysqld' -a -z "${wantHelp}" ]; then
    # still need to check config, container may have started with --user
    _check_config "$@"
    # Get config
    DATADIR="$(_get_config 'datadir' "$@")"

    if [[ ! -d "${DATADIR}/mysql" ]]; then
        file_env 'MYSQL_ROOT_PASSWORD'
        if [ -z "${MYSQL_ROOT_PASSWORD}" -a -z "${MYSQL_ALLOW_EMPTY_PASSWORD}" -a -z "${MYSQL_RANDOM_ROOT_PASSWORD}" ]; then
            echo >&2 'error: database is uninitialized and password option is not specified '
            echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
            exit 1
        fi

        mkdir -p "${DATADIR}"

        echo 'Initializing database'
        "$@" --initialize-insecure
        echo 'Database initialized'

        if command -v mysql_ssl_rsa_setup > /dev/null && [[ ! -e "${DATADIR}/server-key.pem" ]]; then
            # https://github.com/mysql/mysql-server/blob/23032807537d8dd8ee4ec1c4d40f0633cd4e12f9/packaging/deb-in/extra/mysql-systemd-start#L81-L84
            echo 'Initializing certificates'
            mysql_ssl_rsa_setup --datadir="${DATADIR}"
            echo 'Certificates initialized'
        fi

        SOCKET="$(_get_config 'socket' "$@")"
        "$@" --skip-networking --socket="${SOCKET}" &
        pid="$!"

        mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )

        for i in {30..0}; do
            if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
                break
            fi
            echo 'MySQL init process in progress...'
            sleep 1
        done
        if [[ "${i}" = 0 ]]; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        if [[ -z "${MYSQL_INITDB_SKIP_TZINFO}" ]]; then
            # sed is for https://bugs.mysql.com/bug.php?id=20545
            mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
        fi

        if [[ ! -z "${MYSQL_RANDOM_ROOT_PASSWORD}" ]]; then
            export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
            echo "GENERATED ROOT PASSWORD: ${MYSQL_ROOT_PASSWORD}"
        fi

        rootCreate=()
        # default root to listen for connections from anywhere
        file_env 'MYSQL_ROOT_HOST' '%'
        if [ ! -z "${MYSQL_ROOT_HOST}" -a "${MYSQL_ROOT_HOST}" != 'localhost' ]; then
            rootCreate=(
                "CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
                "GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION;"
            )
        fi

        sql=(
            "-- What's done in this file shouldn't be replicated"
            "--  or products like mysql-fabric won't work"
            'SET @@SESSION.SQL_LOG_BIN=0;'
            "DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root') OR host NOT IN ('localhost');"
            "SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}');"
            "GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION;"
            "${rootCreate[@]}"
            'DROP DATABASE IF EXISTS test;'
            'FLUSH PRIVILEGES;'
        )

        printf '%s\n' "${sql[@]}" | "${mysql[@]}"

        if [[ ! -z "${MYSQL_ROOT_PASSWORD}" ]]; then
            mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
        fi

        file_env 'MYSQL_DATABASE'
        if [[ "${MYSQL_DATABASE}" ]]; then
            echo "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` ;" | "${mysql[@]}"
            mysql+=( "${MYSQL_DATABASE}" )
        fi

        file_env 'MYSQL_USER'
        file_env 'MYSQL_PASSWORD'
        if [ "${MYSQL_USER}" -a "${MYSQL_PASSWORD}" ]; then
            echo "CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}' ;" | "${mysql[@]}"

            if [[ "${MYSQL_DATABASE}" ]]; then
                echo "GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%' ;" | "${mysql[@]}"
            fi

            echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
        fi

        echo
        for f in /docker-entrypoint-initdb.d/*; do
            case "${f}" in
                *.sh)     echo "$0: running ${f}"; . "${f}" ;;
                *.sql)    echo "$0: running ${f}"; "${mysql[@]}" < "${f}"; echo ;;
                *.sql.gz) echo "$0: running ${f}"; gunzip -c "${f}" | "${mysql[@]}"; echo ;;
                *)        echo "$0: ignoring ${f}" ;;
            esac
            echo
        done

        if [[ ! -z "${MYSQL_ONETIME_PASSWORD}" ]]; then
            "${mysql[@]}" <<< "ALTER USER 'root'@'%' PASSWORD EXPIRE;"
        fi
        if ! kill -s TERM "${pid}" || ! wait "${pid}"; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        echo
        echo 'MySQL init process done. Ready for start up.'
        echo
    fi
fi

if [[ -f /root/pending-restore ]]; then
    /root/xrecovery-final.sh
fi


exec "$@"
