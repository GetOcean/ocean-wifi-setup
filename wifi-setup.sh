#!/bin/bash
#
# Written by Kousha Talebian <Feb 02, 2016> - iCracked, Inc
# WiFi setup
#
PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/usr/bin/:/bin"
MANUAL="Usage requires {start|delete|check}

    start           Starts the WiFi setup guide
    remove ssid     Removes a network profile based on ssid
    check ssid      Determines if network profile exists
"

WPA_SUPPLICANT_FILE="/etc/wpa_supplicant/wpa_supplicant.conf"
TIMEOUT_SEC=30
PASSWORD=
PASSWORD_RETYPE=
SSID=
CONNECTION_EXISTS=false
SCAN=false

setup_start() {
    if [ "$SKIP_INTRO" != true ]
    then
        clear
        printf "This script will help you setup your WiFi credentials.\n"
    fi

    if yes_no_question "Would you like to setup your WiFi?"
    then
        setup_wifi
    else
        setup_done
    fi
}

setup_done() {
    printf "Run 'wifi-setup start' at any time to setup WiFi.\n"
}

has_ssid() {
    if [ -z "$1" ]; then
        echo "SSID is required"
        exit 1
    fi

    grep -q "ssid=\"$1\"" "$WPA_SUPPLICANT_FILE"
    [ $? -eq 0 ]
}

remove_ssid() {
    if [ -z "$1" ]; then
        echo "SSID is required"
        exit 1
    fi

    if has_ssid "$1"; then
        sed -i -n "1 !H;1 h;$ {x;s/[[:space:]]*network={\n[[:space:]]*ssid=\"${1}\"[^}]*}//g;p;}" "$WPA_SUPPLICANT_FILE"
    else
        echo "SSID '$1' does not exist."
    fi
}

#
# Setups up the wifi credentials
#
setup_wifi() {
    # Random name to ensure mismatch of password for first run
    PASSWORD=1
    PASSWORD_RETYPE=2
    SSID=

    scan_wifi
    read_ssid
    read_wifi_password

    local HASH=$(wpa_passphrase "${SSID}" "${PASSWORD}")
    if [[ $HASH == "network={"* ]]
    then
        printf "\nPlease wait while we attempt to connect you to the network...\n"
        # Save the passphrase and restart networking
        create_tmp_wpa_conf
        restart_networking

        # Now check for wifi connection
        check_wifi_connection
        if [ "$CONNECTION_EXISTS" = true ]
        then
            IP=$(hostname -I)
            SSID_CONNECTED=$(iwconfig wlan0 | sed -e '/ESSID/!d' -e 's/.*ESSID:"/"/')
            printf "You have successfully connected to Network ${SSID_CONNECTED}.\n"
            printf "Your device's IP is ${IP}.\n"
            printf "To use ssh to connect your Ocean, type the following into another console:\n"
            printf "\tssh root@`hostname`.local\n"
            update_wpa_conf
            setup_done
        else
            restore_wpa_conf
            printf "We could not connect you to Network ${SSID}.\n"
            if yes_no_question "Would you like to retry again?"
            then
                setup_wifi
            else
                restart_networking
                setup_done
            fi
        fi
    else
        printf "\n\nThere was a problem with the setup:\n"
        printf $HASH
        printf "\nPlease try again.\n"
        setup_wifi
    fi
}

read_ssid() {
    local RESCAN=false
    while :
    do
        # IF SSID has already been selected (from wifi scan), then skip
        if [ -z "$SSID" ]
        then
            read -e -p "Enter your SSID [ENTER]: " SSID
        fi

        if has_ssid "$SSID"
        then
            printf "SSID '$SSID' already exists in your wpa_supplicant profile.\n"
            if yes_no_question "Would you like to remove it?"
            then
                remove_ssid "$SSID"
                break
            else
                if [ "$SCAN" = true ]
                then
                    RESCAN=true
                    break
                fi
            fi
        else
            break
        fi
        SSID=
    done

    if [ "$RESCAN" = true ]
    then
        scan_wifi
    fi
}

yes_no_question() {
    read -e -p "$1 [Y/n]: " ANS
    [ "$ANS" = "y" ] || [ "$ANS" = "Y" ] || [ "$ANS" = "yes" ] || [ "$ANS" = "Yes" ] || [ "$ANS" = "YES" ] || [ -z "$ANS" ]
}

restart_networking() {
    systemctl daemon-reload
    /etc/init.d/networking restart  &>/dev/null
}

create_tmp_wpa_conf() {
    mv "${WPA_SUPPLICANT_FILE}" "${WPA_SUPPLICANT_FILE}.bak"
    touch "${WPA_SUPPLICANT_FILE}"
    echo "update_config=1" >> "${WPA_SUPPLICANT_FILE}"
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev" >> "${WPA_SUPPLICANT_FILE}"
    wpa_passphrase "${SSID}" "${PASSWORD}" >> "${WPA_SUPPLICANT_FILE}"
}

update_wpa_conf() {
    restore_wpa_conf
    wpa_passphrase "${SSID}" "${PASSWORD}" >> "${WPA_SUPPLICANT_FILE}"
}

restore_wpa_conf() {
    if [ -f "${WPA_SUPPLICANT_FILE}.bak" ]
    then
        mv "${WPA_SUPPLICANT_FILE}.bak" "${WPA_SUPPLICANT_FILE}"
    fi
}

read_wifi_password() {
    local FIRST_WIFI_RUN=true
    local SIZE=${#PASSWORD}

    # Loop until password is entered correctly
    until [ "$PASSWORD" = "$PASSWORD_RETYPE" ] && [ "$SIZE" -ge 8 ] && [ "$SIZE" -le 63 ]
    do
        if [ "$FIRST_WIFI_RUN" != true ]
        then
            if [ "$PASSWORD" != "$PASSWORD_RETYPE" ]
            then
                printf "\nYour password did not match; please try again.\n"
            else
                printf "\nPassword must be between 8 to 63 character long.\n"
            fi
        else
            FIRST_WIFI_RUN=false
        fi

        read -e -s -p "Enter your PASSWORD for the \"$SSID\" network [ENTER]: " PASSWORD
        printf "\n"
        read -e -s -p "Retype your PASSWORD for the \"$SSID\" network [ENTER]: " PASSWORD_RETYPE

        SIZE=${#PASSWORD}
    done
}

check_wifi_connection() {
    local TPREV=$(date +%s);
    while :
    do
        wget -q --tries=1 --timeout=1 --spider http://google.com

        if [ $? -eq 0 ]; then
            CONNECTION_EXISTS=true
            break
        fi

        # Timeout
        local TNOW=$(date +%s)
        if ((TNOW - TPREV>=TIMEOUT_SEC)); then
            break
        fi

        sleep 1
    done
}

scan_wifi() {
    printf "Scanning for networks ..."
    SCAN=true

    # Remove the empty byte (\x00)
    SSIDs=$(iwlist wlan0 scanning | sed 's/\\x00//g' | sed 's/""//g' | grep 'ESSID:"' )

    # get length of an array
    IFS=$'\n' read -d '' -r -a SSIDsArray <<< "$SSIDs"
    aLen=${#SSIDsArray[@]}

    # use for loop read all nameservers
    printf  "\n"
    for (( i=0; i<${aLen}; i++ ));
    do
        NAME=$(echo ${SSIDsArray[$i]} | sed 's/.*"\(.*\)"[^"]*$/\1/')
        echo -e "\t$((i+1)). $NAME"
    done

    #iwlist wlan0 scanning | grep "ESSID" | awk '{print "$t. $1"}'
    if yes_no_question "Is your WiFi network visible?"
    then
        # Now loop until user selects the corresponding number
        local FIRST_RUN=true
        SSID_NUM=0
        until [ $SSID_NUM -gt 0 ] && [ $SSID_NUM -le $aLen ]
        do
            if [ "$FIRST_RUN" != true ]
            then
                printf "Please enter a number between 1 and $aLen\n"
            fi
            FIRST_RUN=false
            read -e -p "Enter the number of the network you want to connect to [ENTER]: " SSID_NUM
        done

        # Make sure the user wants this network
        NAME=$(echo ${SSIDsArray[$((SSID_NUM-1))]} | sed 's/.*"\(.*\)"[^"]*$/\1/')
        if yes_no_question "Connect to \"$NAME\" network now?"
        then
            SSID="$NAME"
        else
            scan_wifi
        fi
    else
        printf "Ocean only supports 2.4GHz bandwidth. Ensure you have a 2.4GHz setup.\n"
        if yes_no_question "Rescan for Network?"
        then
            scan_wifi
        else
            setup_done
            exit 0
        fi
    fi



}

case $1 in
    start)
        setup_start
        ;;

    remove)
        remove_ssid "$2"
        ;;

    check)
        has_ssid "$2"
        # No-op
        ;;

    *)
        printf '%s\n' "$MANUAL"
        exit 1
        ;;
esac