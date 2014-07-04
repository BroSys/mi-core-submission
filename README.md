mi-core-mx
==========

Please refer to https://github.com/joyent/mibe for use of this repo.

## mdata variables

- <code>api_redis_addr</code>: ip or hostname of api server
- <code>api_redis_key</code>: base64 encoded spipe key for api server
- <code>mx_ssl</code>: ssl cert, key and CA for smtp in pem format
- <code>domainkey</code>: Default Domainkey for DKIM
- `munin_allow`: hosts that are allowed to connect to munin, separated by space
- `munin_deny`: hosts that are explicit not allowed, separated by space

## services

- <code>25/tcp</code>: smtp
- <code>465/tcp</code>: smtp encrypted
- <code>587/tcp</code>: smtp encrypted
