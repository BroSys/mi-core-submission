# $Id$
# Copyright 2014 core.io

LOCALCONF = /opt/local/etc/exim/exim.conf.local
MAILSTORE = /tmp

# Prefix for Mail- and Alias-Lookup
ACCOUNTPREFIX 	= mail.account:obj:
ALIASPREFIX 	= mail.alias:obj:

.include LOCALCONF

domainlist local_domains = LOCALDOMAIN : $primary_hostname

redis_servers = 127.0.0.1//

#>> AV Scanner - we use ClamAV at localhost port 3310
av_scanner = clamd:127.0.0.1 3310

#>> SmapScanner - we use rspamd in a spamassassins mannor
spamd_address = 127.0.0.1 11333

#>> submission from a local MUA or script 
#>> messages from these hosts will get fixups
# hostlist submission_hosts = <\n ${lookup redis{SMEMBERS submission_hosts}}
hostlist submission_hosts = <; 127.0.0.1;:1

#>> relay from these hosts
# hostlist relay_from_hosts = <\n ${lookup redis{SMEMBERS relay_from_hosts}}
hostlist relay_from_hosts = <; 127.0.0.1;:1

#>> ACLs to use
acl_smtp_helo = acl_check_helo
acl_smtp_rcpt = acl_check_rcpt
acl_smtp_data = acl_check_data

never_users = root
host_lookup = *
rfc1413_hosts = *
rfc1413_query_timeout = 5s
ignore_bounce_errors_after = 2d
timeout_frozen_after = 7d
queue_only_load = 8
message_size_limit = 100M

tls_advertise_hosts = *
tls_certificate = /opt/local/etc/ssl/exim/submission.core.io.crt
tls_privatekey = /opt/local/etc/ssl/exim/submission.core.io.key

daemon_smtp_ports = 25 : 465 : 587
tls_on_connect_ports = 465 : 587


#>>
#>> ACL
#>>
begin acl
	acl_check_helo:
		#>> Hosts listed on submissionlist are allowed to submit messages
		accept
		  hosts         = +submission_hosts
		#>> Hosts listed on relaylist are allowed to submit messages
		accept
		  hosts         = +relay_from_hosts
		#>> deny if listed at spamhaus
		deny
		  message       = Sorry: $sender_host_address failed in Reverse DNS Lookup (get serious!)
		  log_message   = $sender_host_address failed in Reverse DNS Lookup - Connection denied after HELO
		  !verify		= reverse_host_lookup
		deny
		  message       = Sorry: HELO not suitable (has to match hostname)
		  log_message   = $sender_host_address failed in HELO/EHLO - Connection denied after HELO
		  !verify		= helo
		#>> DNSBLs
		#>> deny if listed at spamhaus
		deny
		  message       = Sorry: $sender_host_address is listed at $dnslist_domain ($dnslist_text)
		  log_message   = $sender_host_address is listed at $dnslist_domain ($dnslist_value: $dnslist_text)
		  dnslists      = zen.spamhaus.org
		accept

	acl_check_rcpt:
		#>> deny if no HELO/EHLO send first
		deny
		  message		= HELO first please
		  log_message 	= $sender_host_address failed - HELO/EHLO missing
		  !verify		= helo
		  
		#>> deny strange characters
		deny
		  message       = Restricted characters in address
		  local_parts   = ^[./|] : ^.*[@%!] : ^.*/\\.\\./
		
		#>> local generated and authenticated mails will get header fixups 
		accept
		  authenticated = *
		  hosts         = +submission_hosts
		  control       = submission/domain=

		#>> libspf2 library from http://www.libspf2.org/
		deny 
		  message = [SPF] $sender_host_address is not allowed to send mail from \
		              ${if def:sender_address_domain {$sender_address_domain}{$sender_helo_name}}.  \
		              Please see http://www.openspf.org/why.html?sender=$sender_address&ip=$sender_host_address
		  log_message = SPF check failed.
		  spf = fail

		#>> dns host lookup
		warn
		  message        = X-Host-Lookup-Failed: Reverse DNS lookup failed for $sender_host_address \
		                   (${if eq{$host_lookup_failed}{1}{failed}{deferred}})
		  condition      = ${if and{{def:sender_host_address}{!def:sender_host_name}}\
		                   {yes}{no}}

		#>> relay only for mails in alias-list or main-list
		#>> redis' HEXISTS leads to 1 for success and 0 for not found - perfect for 'condition'
		accept
		  message = accepted (user found)
		  #>> wildcard for catchall
		  condition 	= ${if or{	{bool{${lookup redis{EXISTS ALIASPREFIX${local_part}@${domain}}}}} \
		  				{bool{${lookup redis{EXISTS ACCOUNTPREFIX${local_part}@${domain}}}}} \
						{bool{${lookup redis{EXISTS ALIASPREFIX*@${domain}}}}} \
						} }

		#>> relay also mails tagged with + in address
		accept
		  message = accepted (origin found)
		  #>> localpart+tag@domainnaame.tld
		  condition 	= ${if match{$local_part}{\N^([^+]+)\+([^+]+)\N} \
		  				  {${lookup redis{EXISTS ACCOUNTPREFIX${lc:$1}@${domain}}}}}

		#>> SRS/RPR Bounce - check if valid
		accept
		  message 	= accepted (our reverse path)
		  condition = ${if match{$local_part}{\N^[sS][rR][sS]0\+([^+]+)\+([0-9]+)\+([^+]+)\+(.*)\N}{\
		  			${if and{\
					{or{{eq {$1}{${length_SRS_HASH_LENGTH:${hmac{sha1}{SRS_SECRET}{${lc:$2+$3+$4@$domain}}}}}}\
					{eq{$1}{${length_SRS_HASH_LENGTH:${hmac{sha1}{SRS_OLD_SECRET}{${lc:$2+$3+$4@$domain}}}}}}}\
					}\
					{>{$2}{${eval:$tod_epoch/86400-13370-SRS_DSN_TIMEOUT}}}\
					{<={$2}{${eval:$tod_epoch/86400-13370}}}\
					}{true}{false}}}}

		deny
		  message = relay not permitted - recipient unknown

	acl_check_data:
		#>> the clamav job 
		deny message = This message contains malware ($malware_name)
		  demime = *
		  malware = *
		
		# put headers in all messages (no matter if spam or not)
		warn  spam = nobody:true
		  add_header = X-Spam-Score: $spam_score
		  add_header = X-Spam-Level: $spam_bar
		  add_header = X-Spam-Report: $spam_report
		# put Spam Flag in messages with score > 5
		warn spam = nobody:true
		  condition = ${if >{$spam_score_int}{50}{true}{false}}
		  add_header = X-Spam-Flag: YES
		# reject spam at high scores (> 12)
		deny message = This message scored $spam_score spam points.
		  spam = nobody:true
		  condition = ${if >{$spam_score_int}{120}{true}{false}}
		accept

#>>
#>> router
#>>
begin routers

	rpr_bounce:
		caseful_local_part
		driver = redirect
		data = ${if match {$local_part}{\N^[sS][rR][sS]0\+([^+]+)\+([0-9]+)\+([^+]+)\+(.*)\N} \
		  {${quote_local_part:$4}@$3}\
		  }
		headers_add = X-SRS-Return: DSN routed via $primary_hostname. See SRS_URL

	rpr_outgoing_goto:
		caseful_local_part
		driver = redirect
		# Don't rewrite if it's a bounce, or from one of our own addresses.
		senders = ! : ! ${lookup redis{EXISTS ACCOUNTPREFIX${local_part}@${domain}}}
		# Rewrite only if Entry in Alias-DB and Aliasdestination is external
		condition = ${if or {\
			{${lookup redis{EXISTS ACCOUNTPREFIX${${lookup redis{HGET ALIASPREFIX${quote_local_part:local_part}@${domain} to}}}}{false}{true}}}\
			{${lookup redis{EXISTS ACCOUNTPREFIX${${lookup redis{HGET ALIASPREFIX*@${domain} to}}}}{false}{true}}}\
			}{true}}
		# We want to rewrite. We just jump to the rpr_rewrite router which is itself unconditional.
		data = ${quote_local_part:$local_part}@$domain
		redirect_router = rpr_rewrite

	tag_rewrite:
		caseful_local_part
		driver = redirect
		data = ${if match{$local_part}{\N^([^+]+)\+([^+]+)\N} \
		  {${quote_local_part:$1}@$domain}\
		  }
		headers_add = X-Tag: {$2}

	#>> look up adress and get some more adresses
	alias:
		driver = redirect
		data = ${lookup redis{HGET ALIASPREFIX${local_part}@${domain} to}}

	#>> look up adress and get some more adresses, catch all
	aliascatchall:
		driver = redirect
		data = ${lookup redis{HGET ALIASPREFIX*@${domain} to}}

	#>> futher internal mailserver
	intmailserver:
		driver = manualroute
		route_data = ${lookup redis{EXISTS ACCOUNTPREFIX${lc:local_part}@${domain}}{MAILBOX_SERVER}}
		transport = remote_smtp

	#>> dnslookup - for all mails to external recipients - if it's not in thedatabase
	lookuphost:
		driver = dnslookup
		transport = remote_smtp
		ignore_target_hosts = 0.0.0.0 : 127.0.0.0/8
		no_more

	rpr_rewrite:
		caseful_local_part
		headers_add = "X-SRS-Rewrite: SMTP reverse-path rewritten from <$sender_address> by $primary_hostname\n\tSee SRS_URL"
		# Encode sender address, hash and timestamp according to http://www.anarres.org/projects/srs/
		# We try to keep the generated localpart small. We add our own tracking info to the domain part.
		address_data = ${eval:($tod_epoch/86400)-13370}+\
			${sender_address_domain}+$sender_address_local_part
		errors_to = ${quote_local_part:SRS0+${length_SRS_HASH_LENGTH:${hmac{sha1}{SRS_SECRET}{${lc:$address_data}}}}+\
			${$address_data}@\
			${domain}
		driver = redirect
		data = ${lookup redis{HGET ALIASPREFIX${quote_local_part:local_part}@${domain} to}{$value}{${lookup redis{HGET ALIASPREFIX*@${domain} to}{$value}fail}}}
		# Straight to output; don't start routing again from the beginning.
		redirect_router = lookuphost
		no_verify

#>>
#>> transport
#>>
begin transports
	#>> smtp
	remote_smtp:
		driver = smtp
		interface = SMTPINTERFACE
		dkim_domain = ${sender_address_domain}
		dkim_selector = dkim
#		dkim_private_key = ${lookup redis{HGET domainkey *@${domain}}}
		dkim_private_key = /etc/exim4/dkim/core.io.key
		dkim_canon = relaxed
	#>> Maildir at this host
	localdir:
		driver = appendfile
		user = mail
		maildir_format
#		directory = MAILSTORE/$domain/$local_part/
		delivery_date_add
		envelope_to_add
		return_path_add



#>>
#>> retry
#>>
begin retry
#	*                      *           F,2h,15m; G,16h,1h,1.5; F,24d,6h
	*                      *           F,2h,15m; G,16h,1h,1.5; F,4d,6h


#>>
#>> rewrite
#>>
begin rewrite


#>>
#>> authenticators
#>>
begin authenticators

plain_auth:
	driver = plaintext
	public_name = PLAIN
#	server_advertise_condition = ${if eq{$tls_cipher}{}{false}{true}}
	server_prompts             = :
	server_set_id = $2
	server_condition = "\
		${if and { \
			{!eq{$2}{}} \
			{!eq{$3}{}} \
			{crypteq {$3}{\\\{crypt\\\}${lookup sqlite {MAILDB select password from accounts where email='$2';}}}} \
			}{yes}{no}}"

login_auth:
	driver = plaintext
	public_name = LOGIN
#	server_advertise_condition = ${if eq{$tls_cipher}{}{false}{true}}
	server_prompts             = Username:: : Password::
	server_set_id = $auth1
	server_condition = "\
		${if and { \
			{!eq{$auth1}{}} \
			{!eq{$auth2}{}} \
			{crypteq {$auth2}{\\\{crypt\\\}${lookup sqlite {MAILDB select password from accounts where email='$auth1';}}}} \
			}{yes}{no}}"

