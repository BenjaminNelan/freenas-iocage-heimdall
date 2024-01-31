# freenas-iocage-heimdall
Modified version of [Dan's script](https://github.com/danb35/freenas-iocage-heimdall) to install the [Heimdall Dashboard](https://heimdall.site/) on FreeBSD/TrueNas 13.2

# Installation
- Go to Shell in TrueNas dashboard
- Download the script `wget https://raw.githubusercontent.com/BenjaminNelan/freenas-iocage-heimdall/master/heimdall-jail.sh`
- Make the script executable `chmod +x heimdall-jail.sh`
- Optionally create a config file `nano heimdall-config` (see configuration options below)
- Run the script `./heimdall-jail.sh`
- If any issues occur, you can resolve them and run the script again, the `heimdall.status` file keeps track of where it was up to and attempts to resume from before the error occurred.
- Once complete, heimdall will be accessible at `JAIL_NAME.local` - if you haven't configured anything it will default to `heimdall.local`

## Configuration options
**JAIL_NAME**
Name of the jail. Defaults to 'heimdall'

**JAIL_IP**
Address that heimdall will be accessible at. Defaults to automatic IP using DHCP since this script also sets up mdns - you should be able to access heimdall at `http://JAIL_NAME.local`

The IP address to assign the jail. You may optionally specify a netmask in CIDR notion.

**DEFAULT_GW_IP**
Gateway used by the jail. Defaults to same gateway used by TrueNas.

**POOL_PATH**
Pool path to store heimdall installation on your TrueNas, eg. `/mnt/mypool/heimdall`. Defaults to storing data within the jail, this means deleting the jail deletes any heimdall data.

**FILE**
The filename to download, which identifies the version of Heimdall to download.  Default is "V2.5.8.tar.gz".  
To check for a more recent release, see the [Heimdall release page](https://github.com/linuxserver/Heimdall/releases).

**PHP_VERSION**
Version of PHP to install. Defaults to "83".
As of writing, TrueNas running 13.2 uses php83 - this script may not work on older or newer versions without adjusting this. (Debugging: If you're having issues installing double check that the latest php versions have the same modules attempting to be installed `PKG_LIST`, php8 for instance bundles openssl, so the module is not installed separately as it was in older php versions)

**RELEASE**
Release for the jail to be based on. Defaults to "13.2-RELEASE"

## Post-install configuration
This script uses the [Caddy](https://caddyserver.com/) web server, which supports automatic HTTPS, reverse proxying, and many other powerful features.  It is configured using a Caddyfile, which is stored at `/usr/local/www/Caddyfile` in your jail, and under `/apps/heimdall/` on your main data pool.  You can edit it as desired to enable these or other features.  For further information, see [my Caddy script](https://github.com/danb35/freenas-iocage-caddy), specifically the included `Caddyfile.example`, or the [Caddy docs](https://caddyserver.com/docs/caddyfile).

This script installs Caddy from the FreeBSD binary package, which does not include any [DNS validation plugins](https://caddyserver.com/download).  If you need to use these, you'll need to build Caddy from source.  The tools to do this are installed in the jail.  To build Caddy, run these commands:
```
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
xcaddy build --output /usr/local/bin/caddy --with github.com/caddy-dns/${DNS_PLUGIN}
```
...with `${DNS_PLUGIN}` representing the name of the plugin, listed on the page linked above.  You'll then need to modify your configuration as described in the Caddy docs.

## Self-signed or local CA
If you're using self-signed certs, or a local certificate authority, for any of your local resources, you'll need to add the relevant root certificate to the trust store for your jail, or Heimdall won't be able to communicate securely with those resources.  To do this,

* Enter the jail with `iocage console heimdall`
* Place a copy of the cert in `/usr/share/certs/trusted/(descriptive cert name).pem`.
* `cd /etc/ssl/certs`
* `openssl x509 -noout -hash -in /usr/share/certs/trusted/(descriptive cert name).pem`
* This will return a hash value like `e94f1467`
* `ln -s /usr/share/certs/trusted/(descriptive cert name).pem (hash value).0`
* Exit and restart the jail

# Support
Further support at https://forum.freenas-community.org/t/install-heimdall-dashboard-in-a-jail-script-freenas-11-2/35
