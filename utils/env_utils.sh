append_env() {
    local name="$1"
    local value="$2"
    local env_value="$(eval echo "\${${name}}")"

    if [ "$env_value" = "" ]; then
        read -r $name <<EOF
$value
EOF
    else
        read -r $name <<EOF
$env_value:$value
EOF
    fi
    export $name
}

prepend_env() {
    local name="$1"
    local value="$2"
    local env_value="$(eval echo "\${${name}}")"

    if [ "$env_value" = "" ]; then
        read -r $name <<EOF
$value
EOF
    else
        read -r $name <<EOF
$value:$env_value
EOF
    fi
    export $name
}

remove_env() {
    local name="$1"
    local regex="$2"
    local env_value="$(eval echo "\${${name}}")"

    read -r $name <<EOF
$(echo "${env_value}" | tr ':' '\n' | grep -v -E "${regex}" | tr '\n' ':' | sed 's/:$//')
EOF
    export $name
}