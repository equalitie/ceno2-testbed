# Server infrastructure for the testbed

There are two types of servers: collectors and jumpers. Collectors run an OONI
collector along with VPN endpoints, whereas jumpers only run VPN endpoints (as
well as `cjdns` and a Tor bridge) along with a reverse proxy to a collector.
Jumpers are only here to increase chances that a collector can be reached.

## VPN and other circumvention endpoints

### TCP port 443 splitting

A client connecting to port 443 will reach a running instance of
[Portsplit](https://github.com/kheops2713/portsplit), a simple TCP port
multiplexer comparable to [sslh](http://www.rutschle.net/tech/sslh.shtml).
Portsplit's configuration file lies in the dedicated `portsplit` user's
directory, at `~portsplit/portsplit-frontal.conf`:

    bind = :::4430
    timeout = 10
    maxconn = 250
    pid = /home/portsplit/portsplit.pid

    [openvpn]
    string = \00\0E\38
    connect = 127.0.0.1:1194

    [ssl]
    # These strings correspond to the "Client Hello" for SSLv3 and TLSv1.[012]
    # we forward to stunnel for TLS decryption
    string = \16\03\00
    string = \16\03\01
    string = \16\03\02
    string = \16\03\03
    connect = 127.0.0.1:4431

Along configuration is the systemd user service file
`~porstplit/.config/systemd/user/portsplit.service`:

    [Unit]
    Description=CENO2 testbed frontal portsplit
    After=network.target

    [Service]
    WorkingDirectory=/home/portsplit
    ExecStart=/usr/local/bin/portsplit portsplit-frontal.conf
    Restart=on-failure

    [Install]
    WantedBy=default.target

To enable and start the service, log in as `portsplit` (via the console or
SSH, not via `su`) and run:

    systemctl --user enable portsplit
    systemctl --user start portsplit

And allow the `portsplit` user to make it permanent in the system by running
as `root`:

    loginctl enable-linger portsplit

If OpenVPN connection initiation bytes are received, Portsplit will forward the
connection to the locally-running OpenVPN server.

If generic TLS header bytes are received, Portsplit will forward the connection
to a locally-running `stunnel` daemon.

`stunnel` will terminate the TLS encryption and forward its content depending on
the TLS SNI sent by the client. If a given predetermined domain is provided, the
connection will be forwarded to the locally-running OONI backend (on jumpers
it's a locally-running `nginx` reverse proxying to a HTTPS OONI collector). If
the SNI is the IP address directly, a PPP VPN session is started inside the TLS
stream.

The global picture is:

```
                  OpenVPN
                     ^
                     |
              (bytes: OpenVPN)
                     |
client --[443]--> Portsplit             +---------> HTTP (OONI backend or nginx)
                     |                  |
      (bytes: TLS Client Hello)   (SNI: "domain.tld")
                     |                  |
                     +------------> stunnel
                                        |
                                   (SNI: IP address)
                                        |
                                        +---------> pppd session
```

### OpenVPN

OpenVPN listens only on `localhost` on a TCP port and is thus reachable only
through Portsplit on port 443, as described above.

It uses TLS certificate authentication and distributes IP addresses in the range
`10.1.0.0/24`.

Through OpenVPN, the server is reachable on IP address `10.1.0.1`. This is valid
for any server (collector or jumper).

### PPP

`pppd` is spawn either through a TLS connection (a client will typically execute
`pppd` over `stunnel` and reach Portsplit, as described above) or through a
specific SSH user (SSH is listening on port 22 and the user has a fixed command
associated to a given SSH key). The TLS stream via `stunnel` or the SSH stream
will be seen as a PTY by `pppd`, allowing to start a point-to-point IP
connection between client and server, with `pppd` running on each side.

`pppd` does not directly handle dynamic address assignment, so a specific
wrapper script was made for this, see `/usr/local/bin/ppp-server-session.sh`. It
determines the address to assign to the client and invokes `pppd` accordingly.

PPP clients are assigned addresses in the range `10.0.0.0/24`, no matter if they
connect through TLS or through SSH. The server is reachable on `10.0.0.1`
through a PPP connection. This is valid on all servers.

### Tor and OnionCat

On collectors, Tor is only run as a client. It is also providing a hidden
service locally used by OnionCat, making the collector reachable to any Tor user
using OnionCat and knowing the hidden service name.

On jumpers, OnionCat is not running, but Tor is running as a private bridge with
`obfs4` pluggable transport. It aims at making the Tor network easier to reach,
so that a collector can eventually be reached through its Tor OnionCat address.

### cjdns

All servers run `cjdns` and have a unique IPv6 `cjdns` address. Collectors and
jumpers are connected together, and if any one of them is reachable from a probe
running `cjdns`, then the probe will be able to reach a collector via its IPv6
address inside `cjdns`.

## Node address reporting and remote maintenance

Nodes use the `report-addrs` Cron script to hourly get via HTTP a server URL
via VPN/tunnel and report their ID and permanent VPN addresses via the URL
query string.  They interpret the retrieved document as an script to be run as
`root`.  The use of this script is to provide maintenance commands to nodes
(directly or e.g. by pulling and running Ansible playbooks).

With an NginX server:

 1. Setup a [virtual host](data/server-nginx/sites-available/server.testbed)
    for `server.testbed`.
 2. Set an
    [index file](data/server-nginx/includes/server.testbed/addrs-index.conf)
    for the `/addrs/` path in the virtual host.
 3. Copy the [maintenance script](data/remote-node-maintenance.sh) to the
    previous index file (e.g. `index.txt`).  Make sure that permissions enable
    the file to be served.

Enable the virtual host and reload NginX.  When nodes access the reporting
URL, a new entry will reflect the provided data in the access log file.

For instance, to get the IDs of nodes reporting their addresses after May 10th
2017:

    $ sudo cat /path/to/access.log | sed '\#\[11/May/2017#,$!d' \
      | sed -En 's#.*GET /addrs/\?n=([-0-9a-f]*)&.*#\1#p' | sort -u

### Remote access to node data

The root user in nodes will be able to retrieve node data (e.g. Ansible
playbooks, experiment data files) using `rsync` and the SSH key shared by all
nodes, but for security reasons it will not be able to run other commands or
access other directories besides that containing node data (in read-only
mode).  The `rsync` package needs to be installed:

    $ sudo apt install rsync

Create a password-less user for accessing node data:

    $ sudo adduser --disabled-password node-data

Copy [node root SSH key](data/ssh/node-root/id_rsa.pub) and restrict it to
perform RSync on a single directory as explained in
<https://www.guyrutenberg.com/2014/01/14/restricting-ssh-access-to-rsync/>:

    $ sudo mkdir -m 0700 ~node-data/.ssh
    $ sudo install -m 0600 /path/to/data/ssh/node-root/id_rsa.pub ~node-data/.ssh/authorized_keys
    $ sudo sed -i 's#^#no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="/usr/local/bin/rrsync -ro /usr/local/lib/node-data/" #' ~node-data/.ssh/authorized_keys
    $ sudo chown -R node-data:node-data ~node-data/.ssh

Install the ``rrsync`` script:

    $ zcat /usr/share/doc/rsync/scripts/rrsync.gz | sudo install -m 0755 /dev/stdin /usr/local/bin/rrsync

Create the directory `/usr/local/lib/node-data` so that only `root` can write
it and only `node-data` can read it, since it may contain sensitive files:

    $ sudo mkdir -p -m 0750 /usr/local/lib/node-data
    $ sudo chgrp node-data /usr/local/lib/node-data

You can now put into `/usr/local/lib/node-data` whatever data you want nodes
to synchronize.  Remember that `node-data` should be able to read all files
contained in there.

### Ansible playbooks for nodes

Nodes should execute ansible playbooks automatically after retrieving the whole
tree.

The directory `ansible-node` in this repository must be copied under the name
`ansible`, in the directory `/usr/local/lib/node-data/` as described above. From
the `data/` subdirectory of this repository, do:

    rsync --delete -rvL ansible-node/ collector_address:ansible

On the collector server (remember that `/usr/local/lib/node-data` can only be
traversed by user `node-data`):

    tmp=$(sudo mktemp -d)
    sudo cp -R ansible $tmp/ansible.new
    sudo chmod -R a+rX $tmp/ansible.new
    sudo mv /usr/local/lib/node-data/ansible $tmp && sudo mv $tmp/ansible.new /usr/local/lib/node-data/ansible
    sudo rm -fr $tmp

### Replication of node data in jumpers

Since syncing of node data is done using `tnldo`, jumpers may also be
contacted for node data retrieval, so the steps from the previous section for
setting up the `node-data` user and the `/usr/local/lib/node-data` must be
replicated in jumpers.

However, instead of manually copying node data, jumpers also behave like nodes
to synchronize (more frequently) the node data directory.

Copy *node* root's private SSH key under the `root`'s home:

    $ sudo mkdir -p -m 0700 ~root/testbed-data/ssh/node-root/
    $ sudo install -m 0600 /path/to/id_rsa ~root/testbed-data/ssh/node-root/

Test it (and add the SSH host key if needed) with:

    $ sudo rsync -e "ssh -i /root/testbed-data/ssh/node-root/id_rsa" --delete -r node-data@SERVER: /usr/local/lib/node-data

Replacing `SERVER` with the host name of your actual server.  If working, add
the following script `/etc/cron.d/node-data-sync` (remember to replace
`SERVER`):

```cron
# Synchronize node data from base server.
SHELL=/bin/sh
PATH=/bin:/usr/bin

*/47 * * * *  root  rsync -e "ssh -i /root/testbed-data/ssh/node-root/id_rsa" --delete -r node-data@SERVER: /usr/local/lib/node-data
```

And reload Cron:

    $ sudo service cron reload

(Updates from nodes every hour and updates from jumpers every 47 minutes
overlap every 2820 hours, around 4 months.)

## OONI backend

### Reaching the OONI backend

On collectors, `oonib` listens on cleartext HTTP locally, behind `stunnel` (for
public HTTPS) and all the VPNs abovementioned.

On jumpers, `oonib` is replaced by `nginx`. When reached, `nginx` forwards the
HTTP connection to a given OONI backend using public HTTPS.

OONI probes can thus reach a collector in various ways:

- public HTTPS URLs to the collector or any of the jumpers;
- OnionCat IPv6 address, on port 11080, if Tor network is connected;
- Onion URL, port 80, if Tor network is connected;
- `cjdns` IPv6 address, on port 11080, if any of the collector or jumpers'
  `cjdns` are connected;
- `http://10.0.0.1:11080` if any collector or jumper's PPP (over TLS or SSH) is
  connected;
- `http://10.1.0.1:11080` if any collector or jumper's OpenVPN is connected.

### Installation and configuration

We are using a custom
[OONI backend fork](https://github.com/equalitie/ooni-backend/tree/eq-testbed)
based on work from Vmon. This version provides a test helper that we need for
our peer-to-peer tests. Installation in a Python virtual environment should be
straightforward:

    sudo apt-get install build-essential python-dev python-setuptools openssl libsqlite3-dev libffi-dev git curl
    mkdir -p ~/venvs
    virtualenv ~/venvs/ooni-backend-eq
    . ~/venvs/ooni-backend-eq/bin/activate
    pip install --upgrade setuptools  # the one provided by virtualenv can be outdated
    mkdir -p ~/vc/git
    git clone -b eq-testbed 'https://github.com/equalitie/ooni-backend.git' ~/vc/git/ooni-backend-eq
    cd ~/vc/git/ooni-backend-eq
    pip install -r requirements.txt
    python setup.py install
    cd
    ln -s vc/git/ooni-backend-eq/data

The last operation makes the data directory available using the symbolic link
`/home/ooni/data`, which can be used e.g. for packing data using the
[Testbed administration script](#testbed-administration-script).  Measurements
reported by nodes are stored in the `archive` subdirectory.

Copy `oonib.conf.example` to `oonib.conf` and edit it. Assuming the user running
`oonib` is called `ooni`, the following bits are of interest:

- `logfile` can be set to `/home/ooni/oonib.log` or any other file to better
  know what is happening;
- `debug` can be set to `true` for a more verbose logging;
- `tor_binary` must be set to `/usr/bin/tor`;
- `tor_datadir` can be set to `/home/ooni/.tor-oonib`;
- section `bouncer_endpoints` can be entirely commented out;
- section `collector_endpoints` must have two entries:
    - `{type: tcp, port: 11080, address: '::'}`
    - `{type: onion, hsdir: /home/ooni/oonibackend_hidden_services/collector}`
- `port` for all helpers should be set to `null` to deactivate them, except for
  `peer-locator` and `nat-detection` (main and alternate endpoints).

You may need to edit the file `data/policy.yaml` to make sure that the tests
names and versions as sent by the probes will be accepted by the backend. A HTTP
error 406 sent back by the backend indicates that the policy is probably
forbidding the test result to be submitted.

Finally, create the unit file `~ooni/.config/systemd/user/oonib.service` for
systemd to start the backend and restart it if it crashes:

    [Unit]
    Description=CENO2 testbed OONI backend
    After=network.target

    [Service]
    WorkingDirectory=/home/ooni/vc/git/ooni-backend-eq
    ExecStart=/home/ooni/venvs/ooni-backend-eq/bin/python bin/oonib
    Restart=on-failure

    [Install]
    WantedBy=default.target

To enable and start the service, log in as `ooni` (via the console or SSH, not
via `su`) and run:

    systemctl --user enable oonib
    systemctl --user start oonib

And allow the `ooni` user to make it permanent in the system by running as
`root`:

    loginctl enable-linger ooni

### Denial-of-service protection for UDP-based service

One of our custom helpers aims at allowing nodes detect which type of NAT they
are behind, if any. It listens on a UDP port and, when receiving a properly
formatted request, replies to the client with a single packet containing what
the client's originating IP address and port looks like. On the nodes, the
client side runs as a OONI probe test. On the server side, it is for now only a
standalone program, but will be integrated as a OONI backend helper.

For clients to collect enough data to detect NAT types, this helper must run on
(at least) two distinct servers, or on a server that has (at least) two distinct
IP addresses. Clients will contact both and compare the replies to try to guess
the NAT type, as defined in
[section 4](https://tools.ietf.org/html/rfc4787#section-4) of RFC 4787.

Since we use UDP, it is easy for attackers to trigger this helper in sending
unsollicited packets to arbitrary victims by spoofing the origin IP and port (a
common technique used for instance in DNS amplification attacks), potentially at
very high rate.

Consequently, you may want to use `iptables` to rate-limit the input traffic and
block packets from a specific IP address if too many are arriving too fast. The
`hashlimit` module is designed for that. Assuming your UDP helper runs on port
12345, the following command will make the kernel ignore UDP packets to port
12345 from any peer sending at more than 5 packets per minute to that:

    iptables -A INPUT -m comment --comment \
             "IPv4 NAT detection helper on UDP port 12345"
    iptables -A INPUT -p udp --dport 12345 -m hashlimit \
             --hashlimit-name natdet-v4-12345 \
             --hashlimit-above 5/minute --hashlimit-mode srcip,dstip \
             --hashlimit-burst 5 --hashlimit-srcmask 32 -j DROP

`ip6tables` also supports this option with the same syntax. However, since IPv6
addresses have 128 bits and end-users usually have /64 or /56 prefixes, you may
want to set the `--hashlimit-srcmask` option to 56 and/or 64:

    ip6tables -A INPUT -m comment --comment \
              "IPv6 NAT detection helper on UDP port 12345"
    ip6tables -A INPUT -p udp --dport 12345 -m hashlimit \
              --hashlimit-name natdet-v6-12345 \
              --hashlimit-above 5/minute --hashlimit-mode srcip,dstip \
              --hashlimit-burst 5 --hashlimit-srcmask 64 -j DROP

Make sure each `hashlimit` rule you add has a unique name, defined with the
option `--hashlimit-name`.

Save these rules to make them active at next reboot (you may need to install the
`iptables-persistent` package):

    iptables-save >/etc/iptables/rules.v4
    ip6tables-save >/etc/iptables/rules.v6

### Upgrade

We use an incremental number suffix for the Python environment name of OONI
backend upgrades.  Use the following command to see what the next version
shoud be:

    ls -d ~/venvs/ooni-backend-eq* | sort -n -t. -k2

Let's imagine that the last version is `ooni-backend-eq.41`, then set:

    NEXT=42

Use 1 if you have not yet installed any upgrade yet.  To upgrade:

    virtualenv ~/venvs/ooni-backend-eq.$NEXT
    . ~/venvs/ooni-backend-eq.$NEXT/bin/activate
    pip install --upgrade setuptools
    cd ~/vc/git/ooni-backend-eq
    git pull  # or fetch and checkout a particular version
    pip install -r requirements.txt
    python setup.py install
    cd ~/venvs
    systemctl --user stop oonib
    rm ooni-backend-eq
    ln -s ooni-backend-eq.$NEXT ooni-backend-eq
    systemctl --user start oonib

## Administrative tools

### Testbed administration script

The [admin script](./admin) can be used in a testbed server to perform several
operations.  To install it:

    # install /path/to/testbed/admin /usr/local/bin/testbed-admin

It must be run by ``root`` or some user that can ``sudo`` to ``root`` for
certain read-only operations like accessing logs and data files.

The script allows running several commands to operate on nodes:

``nodes_addrs``
: Print ``n=NODE_ID a=NODE_ADDR1/NODE_PFX1 a=NODE_ADDR2/NODE_PFX2…
i4=NODE_PUB_ADDR`` for each node which reported today.

``nodes_cjdns_addrs``
: Print the cjdns IPv6 address of each node which reported today.

``nodes_ocat_addrs``
: Print the OnionCat IPv6 address of each node which reported today.

``nodes_exec COMMAND ARG…``
: Execute the given command in each node which reported today.

``nodes_history``
: Print oldest-to-newest list of ``UTC_ISO_DATE NODE_ID`` occurrences in the
beacon log, i.e. show which nodes where available on which days.

``data_pack``
: Pack test results and other files useful for their interpretation.

``copy_http_beacon_logs``
: Copy the beacon log to a location where it can be read by the OONI user.

``convert_ooni_json``
: Flatten OONI reports into event-based JSON files and place them in a
location where it can be read by the OONI user.

Some of these commands use the entries created in the server's web access log
by [node address reporting](#node-address-reporting-and-remote-maintenance).
The location of the log file and other parameters can be set as environment
variables whose defaults sit at the beginning of the script.

### Publication of test data

The [update-data-pack](./update-data-pack) script can be run as ``root`` from
a ``crontab`` entry.  It uses the admin script to create a snapshot of test
results, which is placed in a given directory to be published by a web server,
both with its original name (which hints the user about the date of the
snapshot) and with a ``testbed-data.EXTENSION`` link pointing to it.

To install the script:

    # install /path/to/testbed/update-data-pack /usr/local/sbin/testbed-update-data-pack

The location of the admin script, the web directory and other parameters can
be set as environment variables whose defaults sit at the beginning of the
script.

An example of ``/etc/cron.d/testbed-update-data-pack``:

    # Refresh the CENO testbed data pack.
    WEB_DIR=/var/www/SOME_VIRTUAL_HOST/data
    @daily  root  /usr/local/sbin/testbed-update-data-pack

Then run ``service cron reload`` to apply it.  Remember to protect the web
directory with some kind of authorization if the tests may yield sensible
data.

## Using ElasticSearch to visualise test results

The amount of data collected by the OONI tests mentioned above may not be
practical to look at and analyse by simply looking at the JSON files produced by
the tests.

It is possible to build a simple pipeline to insert this data into ElasticSearch
(ES), through Logstash, and make it observable with Kibana. This triplet is
commonly abbreviated "[ELK](https://www.elastic.co/)".

The overall pipeline to process the data into ES for the testbed is as follows:

1. data is generated on probes;
2. data is sent to the collector;
3. data is translated into a structure suitable for ElasticSearch (mostly:
   nested structures are flattened), which produces a new set of JSON files
   containing the translated data;
3. optionally, translated data files are transferred to a machine dedicated to
   run ELK;
4. transformed data is read by Logstash and inserted into ElasticSearch, and
   ready to be consulted via Kibana.

### Why the data is translated

ElasticSearch deals best with time-based series of events, with events of
identical nature having identical properties. For instance, each single result
of a P2P test actually includes several events (connection to a peer, request to
the DHT…), and they must therefore be explicitly separated into distinct JSON
objects whose properties will be taken from the initial data.

Besides, Kibana does not handle nested data structures properly. Therefore,
simple events that do not need to be broken down into multiple events (like the
P2P test) still have OONI-specific data structures that need to be flattened.

After translation, each event is a simple JSON object without nesting.

### How the data is translated

Within one run of the NAT detection test, the probe is likely to receive several
UDP packets from the NAT detection helpers. The translation consists in
exploding the OONI test object into one ElasticSearch event for each packet of
data received by the probe. Each event corresponding to that one OONI test run
will still share some properties' values, like `test_id`, that are common to the
whole OONI test run.

A P2P test outputs its results to standard output as a JSON string, which OONI
serialises into a string variable in the JSON object representing the test
result. The translation first deserialises the string back into JSON, and then
explodes the multiple P2P events it contains into individual ES events. In
addition, out of a (eventually unfounded) doubt that ES may not properly handle
field names containing hyphens, they are translated into underscores.

Each HTTP reachability test also contains several events, as the probe tries to
contact several peers. Additionally, contacting a given peer may lead to several
attempts in case of failure. Out of the OONI data, each connection attempt
yields an individual ES event. Different attempts at contacting the same peer
within the same OONI test run are timestamped with the same value, but are
differenciated with an added `attempt` field.

The exact `jq` commands for these translations are in the `admin` script, should
you want to look at them.

### Running the data translation

`jq` in version at least 1.5 is required. On Debian Jessie, you can download a
precompiled static binary from the [official
website](https://stedolan.github.io/jq/) and install it to `/usr/local/bin/`,
since the packaged version is older than 1.5.

To run the translation, proceed as follows:

1. make sure the environment variable `TB_OONI_DATA` is set properly to the
   folder containing OONI data test results on the collector;
2. set the environment variable `TB_CONVERTED_OONI_JSON_DIR` to the directory
   you want the translated output to;
3. if necessary, set the `JQ` environment variable to the appropriate `jq`
   binary;
4. run the admin script with `convert_ooni_json` as first and only argument.

The script will not re-convert files if the target files already exist. In order
to force re-conversion of all files, simply remove the target directory or point
the script to a different one.

For a continuous pipeline, it is a good idea to add a call to this script
regularly with `cron`.

### Adding HTTP beacons sent by probes

Besides OONI JSON data, the testbed collector includes a web server that
receives HTTP beacons sent by probes regularly. They simply consist in `nginx`
HTTP log files.

The admin script will simply copy the relevant log file from its source
directory to the target directory along with the JSON OONI files.

Make sure the environment variable `TB_WEB_ACCESS_LOG` is properly set, as well
as `TB_CONVERTED_OONI_JSON_DIR` and `JQ`, then run the admin script with
`copy_http_beacon_logs` as sole argument.

### ELK installation and setup

These instructions are for Debian, and were tested on Jessie.

Install package `apt-transport-https`:

    $ sudo apt-get install apt-transport-https

Make Debian aware of Elastic's PGP key and package repository, then install ELK:

    $ wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
    $ echo "deb https://artifacts.elastic.co/packages/5.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-5.x.list
    $ sudo apt-get update
    $ sudo apt-get install elasticsearch logstash kibana nginx certbot apache2-utils

Create one or several user accounts in a `htpasswd` file in
`/etc/nginx/conf.d/htpasswd` and set their password. They will be used to make
sure external access to Kibana and ElasticSearch is authenticated:

    $ sudo htpasswd /etc/nginx/conf.d/htpasswd my_new_user

Make sure a domain name is associated to your machine hosting ELK, and use for
instance Let's Encrypt's `certbot` to generate a TLS certificate that `nginx`
will be able to use.

Install the following files from this repository (see the `elasticsearch/`
folder):

- `/etc/kibana/kibana.yml`;
- `/etc/logstash/conf.d/cenolastic.conf` (make sure you adjust the paths to the
  various data files, as converted and copied by the admin script as shown
  above);
- `/etc/logstash/templates/ooni.json`;
- `/etc/logstash/templates/http_beacon.json`;
- `/etc/nginx/sites-available/elasticsearch` (make sure you edit this file
  and adjust it to your domain name).

Finally, restart the services:

    $ service kibana restart
    $ service logstash restart

Logstash should start processing your files and insert data into ES. You can
start exploring data by connecting to `https://your.domain/dash/`.

## Troubleshooting and gotchas

List of unexpected errors we encountered at eQualit.ie during setup and
maintenance, related to system configuration and that may or may not happen.

### Systemd errors

When executing `systemctl --user enable portsplit` as user `portsplit` (or
similar commands such as when enabling or starting the `oonib` service), you
might encounter this error message:

    Failed to get D-Bus connection: Connection refused

First make sure you did not `su` or `sudo` as the user (SSH directly to the host
as that user). If the error keeps happening, you may need to install the package
`libpam-systemd`. Then log out from your SSH session, make sure `screen` or
`tmux` sessions are closed, and log back in. You should now be able to use user
systemd units.
