# Show the reminder on interactive console shells as well as PAM logins.
case $- in
    *i*)
        if [ -r /etc/motd.d/80-openruyi-grub ]; then
            cat /etc/motd.d/80-openruyi-grub
        fi
        ;;
esac
