# create cronjob for sa-update
CRON='0 10 * * * sudo -u spamd /opt/local/bin/sa-update && kill -SIGHUP $(cat /var/spamassassin/spamd.pid)'
(crontab -l 2>/dev/null || true; echo "$CRON" ) | sort | uniq | crontab

# enable spamd service
/usr/sbin/svcadm enable svc:/network/spamd
