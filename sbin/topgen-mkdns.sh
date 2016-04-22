#!/bin/bash

# Generate full bind9 configuration from a (TopGen) hosts file
# (glsomlo@cert.org, June 2015)
#
# We assume a well-behaved hosts file consisting of valid lines
# of the form <ip_addr fqdn> (a file auto-generated by the TopGen
# scraper should work unequivocally; for now, though, we skip any
# additional error checking and validation).
#
# NOTE on DELEGATIONS:
# For each delegated 2nd-level domain (forward) or /24 subnet (reverse),
# we list one or more name server fqdn(s), which will handle lookups
# for that respective domain or subnet.
# We then separately list each name server fqdn with its ip address.
# Each listed delegation name server MUST have a subsequent entry
# containing its IP address, but, for now, we do not enforce that.
# (Failure to provide an IP address for any of the delegation name
# servers results in undefined behavior at this time.
# FIXME: we can either read in the following three hashes from a config
# file programmatically (and add the checks there), or we can add a step
# to check for consistency across the three hashes, if it turns out that
# mistakes are simply TOO easy to make :)

# input hosts file (<ip_addr fqdn> for all virtual Web hosts):
SRC_WHOSTS='/var/lib/topgen/etc/hosts.nginx'

# additional input hosts files (<ip_addr fqdn>):
SRC_XHOSTS=''

# input hosts file (<ip_addr fqdn> for all virtual mail servers):
SRC_MHOSTS='/var/lib/topgen/etc/hosts.vmail'

# input delegations file (hashes to be sourced into our namespace):
SRC_DELEG='/etc/topgen/delegations.dns'

# output hosts file (<ip_addr fqdn> for all virtual DNS servers impersonated):
NAMED_HOSTS='/var/lib/topgen/etc/hosts.named'

# output named.conf
NAMED_CONF='/var/lib/topgen/etc/named.conf'

# output folder for zone files:
NAMED_ZD='/var/lib/topgen/named'

# if "yes", force/overwrite any prior existing configuration
FORCE_GEN='no'

# if "yes", do not print warnings and a success notification
QUIET_GEN='no'

###########################################################################
####    NO FURTHER USER-SERVICEABLE PARTS BEYOND THIS POINT !!!!!!!    ####
###########################################################################

# Caching servers (for use in view match, and to ensure existence of A records):
declare -A CACHING_NS=(
  ['b.resolvers.level3.net']='4.2.2.2'
  ['google-public-dns-a.google.com']='8.8.8.8'
  ['google-public-dns-b.google.com']='8.8.4.4'
)

# TLD servers (for use in view match, and to ensure existence of A records):
declare -A TOPLEVEL_NS=(
  ['ns.level3.net']='4.4.4.8'
  ['ns.att.net']='12.12.12.24'
  ['ns.verisign.com']='69.58.181.181'
)

# Root servers (for use in view match, and to ensure existence of A records):
# NOTE: these are "well-known", i.e. hardcoded on various other software
#       packages (e.g., bind9), so don't change them unless you REALLY know
#       what you're doing !!!
declare -A ROOT_NS=(
  ['a.root-servers.net']='198.41.0.4'
  ['b.root-servers.net']='192.228.79.201'
  ['c.root-servers.net']='192.33.4.12'
  ['d.root-servers.net']='199.7.91.13'
  ['e.root-servers.net']='192.203.230.10'
  ['f.root-servers.net']='192.5.5.241'
  ['g.root-servers.net']='192.112.36.4'
  ['h.root-servers.net']='128.63.2.53'
  ['i.root-servers.net']='192.36.148.17'
  ['j.root-servers.net']='192.58.128.30'
  ['k.root-servers.net']='193.0.14.129'
  ['l.root-servers.net']='199.7.83.42'
  ['m.root-servers.net']='202.12.27.33'
)

# usage blurb (to be printed with error messages):
USAGE_BLURB="
Usage:  $0 [-w <web_hosts>] [-m <mail_hosts>] [-d <delegations>] \\
                       [-n <dns_hosts>] [-c <named_conf>] [-z <zone_folder>]

The optional command line arguments are:

    -w <web_hosts>   name of the input hosts list containing <ip_addr fqdn>
                     pairs of all virtual Web TopGen hosts to be hosted by
                     the web server;
                     (default: $SRC_WHOSTS).

    -x <xtra_hosts>  name of additional hosts list(s) containing <ip_addr fqdn>
                     mappings to be resolved by the DNS infrastructure;
                     (default: <empty>).

    -m <mail_hosts>  name of the input hosts list containing <ip_addr fqdn>
                     pairs of all of TopGen's virtual mail servers;
                     (default: $SRC_MHOSTS).

    -d <delegations> name of the input file containing hashes associating
                     delegated forward 2nd-level domains and reverse /24
                     networks with their respective authoritative name
                     servers, and also providing an IP address for each
                     such name server;
                     (default: $SRC_DELEG).

    -n <dns_hosts>   name of the output hosts list containing <ip_addr fqdn>
                     pairs for all virtual DNS TopGen servers supported by
                     the configuration being generated;
                     (default: $NAMED_HOSTS).

    -c <named_conf>  name of the generated bind9 named.conf file;
                     (default: $NAMED_CONF).

    -z <zone_folder> name of the folder where all zone files referenced
                     in named.conf will be generated;
                     (default: $NAMED_ZD).

    -f               do not stop if pre-existing configuration is encountered;
                     instead, forcibly remove and re-create the configuration.
                     CAUTION: pre-existing configuration will be lost !

    -q               do not print warnings or a success notification
                     (output will still be generated if exiting with an error).
 
Generate bind9 configuration (named.conf, zone files, and a list
of DNS virtual hosts) based on a given hosts file (containing a
list of <ip_addr fqdn> pairs) and a list of 2nd-level domain
delegation target name servers.
" # end usage blurb

# process command line options (overriding any defaults, or '-h'):
OPTIND=1
while getopts "w:x:m:d:n:c:z:fqh?" OPT; do
  case "$OPT" in
  w)
    SRC_WHOSTS=$OPTARG
    ;;
  x)
    SRC_XHOSTS=$OPTARG
    ;;
  m)
    SRC_MHOSTS=$OPTARG
    ;;
  d)
    SRC_DELEG=$OPTARG
    ;;
  n)
    NAMED_HOSTS=$OPTARG
    ;;
  c)
    NAMED_CONF=$OPTARG
    ;;
  z)
    NAMED_ZD=$OPTARG
    ;;
  f)
    FORCE_GEN='yes'
    ;;
  q)
    QUIET_GEN='yes'
    ;;
  *)
    echo "$USAGE_BLURB"
    exit 0
    ;;
  esac
done

# we should be left with NO FURTHER arguments on the command line:
shift $((OPTIND-1))
[ -z "$@" ] || {
  echo "
ERROR: invalid argument: $@

$USAGE_BLURB
"
  exit 1
}

# assert existence of $SRC_WHOSTS and $SRC_DELEG files, and $NAMED_ZD folder:
[ -s "$SRC_WHOSTS" -a -s "$SRC_DELEG" -a -d "$NAMED_ZD" ] || {
  echo "
ERROR: files \"$SRC_WHOSTS\", \"$SRC_DELEG\", and
       folder \"$NAMED_ZD\" MUST exist
       before running this command!

$USAGE_BLURB
"
  exit 1
}

# view-specific zone files go in folders underneath $NAMED_ZD:
ROOT_ZD="$NAMED_ZD/rootsrv"
TLD_ZD="$NAMED_ZD/tldsrv"

# assert non-existence of $NAMED_HOSTS, $NAMED_CONF, and per-view zone folders:
[ "$FORCE_GEN" == "yes" ] && rm -rf $NAMED_HOSTS $NAMED_CONF $ROOT_ZD $TLD_ZD
[ -s "$NAMED_HOSTS" -o -s "$NAMED_CONF" -o -d "$ROOT_ZD" -o -d "$TLD_ZD" ] && {
  echo "
ERROR: files \"$NAMED_HOSTS\", \"$NAMED_CONF\", or
       folders \"$ROOT_ZD\", \"$TLD_ZD\" must NOT exist!
       Please remove them manually before running this command again!

$USAGE_BLURB
"
  exit 1
}

# create $ROOT_ZD and $TLD_ZD folders at this point:
mkdir $ROOT_ZD
mkdir $TLD_ZD


# source delegations (imports DELEGATIONS_FWD, DELEGATIONS_REV, DELEGATIONS_NS):
. $SRC_DELEG


# associative array (hash) with key=fqdn and value=ip_addr for each host
declare -A HOSTS_LIST

# assoc. array (hash) with key=domain and value=mx_hostname for each domain
declare -A DOMAIN_MX

# check that a host is not delegated, and insert it into HOSTS_LIST hash
# also insert into DOMAIN_MX array if $IS_MX is "true"
function hosts_list_add {
  IPADDR=$1
  FQDN=$2
  IS_MX=$3

  # parse TLD (last dot-separated segment of FQDN):
  TLD=${FQDN##*.}

  # parse second-level domain:
  # FIXME: can we parse into array, then get TLD=[last] and SLD=[last-1] ?
  TMP=${FQDN%.*} # everything EXCEPT tld
  SLD=${TMP##*.} # last dot-separated segment of "everything EXCEPT tld"

  # skip host if FQDN falls within one of the delegated forward domains:
  for DOM in "${!DELEGATIONS_FWD[@]}"; do
    [ "$SLD.$TLD" = "$DOM" ] && {
      [ "$QUIET_GEN" == "no" ] && echo "
WARNING: skipping host $FQDN in delegated domain $DOM"
      return
    }
  done

  # skip host if IP address falls within one of the delegated IP networks:
  for NET in "${!DELEGATIONS_REV[@]}"; do
    [ "${IPADDR%.*}" = "$NET" ] && {
      [ "$QUIET_GEN" == "no" ] && echo "
WARNING: skipping host $FQDN: ip $IPADDR in delegated network $NET"
      return
    }
  done

  # add host to HOSTS_LIST hash:
  HOSTS_LIST[$FQDN]=$IPADDR

  # is this an MX server?
  [ "$IS_MX" == "true" ] && DOMAIN_MX[$SLD.$TLD]+=" $FQDN"
}


# grab hosts in $SRC_[W|X]HOSTS, skip & warn on collision with delegations:
#cat $SRC_WHOSTS $SRC_XHOSTS | while read IPADDR FQDN; do
while read IPADDR FQDN; do
  hosts_list_add $IPADDR $FQDN false
done < $SRC_WHOSTS

[ -n "$SRC_XHOSTS" -a -s "$SRC_XHOSTS" ] && while read IPADDR FQDN; do
  hosts_list_add $IPADDR $FQDN false
done < $SRC_XHOSTS

# grab hosts in $SRC_MHOSTS, skipping & warning on collision with delegations:
# NOTE: also make sure these get added as MX records for their domain
[ -s "$SRC_MHOSTS" ] && while read IPADDR FQDN; do
  hosts_list_add $IPADDR $FQDN true
done < $SRC_MHOSTS


# unconditionally add all delegations' designated name servers:
for NS in "${!DELEGATIONS_NS[@]}"; do
  [ -n "${HOSTS_LIST[$NS]}" ] && {
    [ "$QUIET_GEN" == "no" ] && echo "
WARNING: Delegation name server $NS already in $SRC_WHOSTS!
         (old address ${HOSTS_LIST[$NS]}, using ${DELEGATIONS_NS[$NS]})"
  }
  HOSTS_LIST[$NS]=${DELEGATIONS_NS[$NS]}
done

# unconditionally add all public caching name servers:
for NS in "${!CACHING_NS[@]}"; do
  [ -n "${HOSTS_LIST[$NS]}" ] && {
    [ "$QUIET_GEN" == "no" ] && echo "
WARNING: Top level name server $NS already exists!
         (old address ${HOSTS_LIST[$NS]}, using ${CACHING_NS[$NS]})"
  }
  HOSTS_LIST[$NS]=${CACHING_NS[$NS]}
done

# unconditionally add all toplevel name servers:
for NS in "${!TOPLEVEL_NS[@]}"; do
  [ -n "${HOSTS_LIST[$NS]}" ] && {
    [ "$QUIET_GEN" == "no" ] && echo "
WARNING: Top level name server $NS already exists!
       (old address ${HOSTS_LIST[$NS]}, using ${TOPLEVEL_NS[$NS]})"
  }
  HOSTS_LIST[$NS]=${TOPLEVEL_NS[$NS]}
done

# unconditionally add all root name servers:
for NS in "${!ROOT_NS[@]}"; do
  [ -n "${HOSTS_LIST[$NS]}" ] && {
    [ "$QUIET_GEN" == "no" ] && echo "
WARNING: Top level name server $NS already exists!
       (old address ${HOSTS_LIST[$NS]}, using ${ROOT_NS[$NS]})"
  }
  HOSTS_LIST[$NS]=${ROOT_NS[$NS]}
done


# generate dns hosts file:
{
  for NS in "${!CACHING_NS[@]}"; do
    echo "${CACHING_NS[$NS]} $NS"
  done
  for NS in "${!TOPLEVEL_NS[@]}"; do
    echo "${TOPLEVEL_NS[$NS]} $NS"
  done
  for NS in "${!ROOT_NS[@]}"; do
    echo "${ROOT_NS[$NS]} $NS"
  done
} > $NAMED_HOSTS


# Initialize $NAMED_CONF, starting with ACLs covering each server class:
{
  echo -e "acl \"cache_addrs\" {"
  for NS in "${!CACHING_NS[@]}"; do
    echo -e "\t${CACHING_NS[$NS]}/32;        /* $NS */"
  done
  echo -e "};\n\nacl \"root_addrs\" {"
  for NS in "${!ROOT_NS[@]}"; do
    echo -e "\t${ROOT_NS[$NS]}/32;        /* $NS */"
  done
  echo -e "};\n\nacl \"tld_addrs\" {"
  for NS in "${!TOPLEVEL_NS[@]}"; do
    echo -e "\t${TOPLEVEL_NS[$NS]}/32;        /* $NS */"
  done 
} > $NAMED_CONF

# full path+name of root zone file:
ROOT_ZONE="$ROOT_ZD/root.zone"

# continue generating $NAMED_CONF (boilerplate options and view configuration)
cat >> $NAMED_CONF << EOT
};

options {
	listen-on port 53 { "cache_addrs"; "root_addrs"; "tld_addrs"; };
	allow-query { any; };
	recursion no;
	check-names master ignore;
	directory "/var/named";
	dump-file "/var/named/data/cache_dump.db";
	statistics-file "/var/named/data/named_stats.txt";
	memstatistics-file "/var/named/data/named_mem_stats.txt";
	pid-file "/run/named/named.pid";
	session-keyfile "/run/named/session.key";
};

logging {
	channel default_debug {
		file "data/named.run";
		severity dynamic;
	};
};

view "caching" {
	match-destinations { "cache_addrs"; };

	recursion yes;

	zone "." IN {
		type hint;
		file "named.ca";
	};
};

view "rootsrv" {
	match-destinations { "root_addrs"; };

	zone "." IN {
		type master;
		file "$ROOT_ZONE";
		allow-update { none; };
	};
};

view "tldsrv" {
	match-destinations { "tld_addrs"; };

EOT


# Initialize $ROOT_ZONE file:
cat > $ROOT_ZONE << "EOT"
$TTL 300
$ORIGIN @
@ SOA a.root-servers.net. admin.step-fwd.net. (15061601 600 300 800 300)
EOT

# list root servers (as NS records) programmatically:
for NS in "${!ROOT_NS[@]}"; do
  echo -e "\t\t\tNS\t$NS."
done >> $ROOT_ZONE

# list root servers (as A glue records) programmatically:
for NS in "${!ROOT_NS[@]}"; do
  echo -e "$NS.\tA\t${ROOT_NS[$NS]}"
done >> $ROOT_ZONE

# list TLD servers (as NS delegations for in-addr.arpa) programmatically:
cat >> $ROOT_ZONE << "EOT"
;
; in-game reverse DNS is also handled by the tld servers:
;
EOT
for NS in "${!TOPLEVEL_NS[@]}"; do
  echo -e "in-addr.arpa.\t\tNS\t$NS."
done >> $ROOT_ZONE

# list TLD servers (as A glue records) programmatically:
for NS in "${!TOPLEVEL_NS[@]}"; do
  echo -e "$NS.\tA\t${TOPLEVEL_NS[$NS]}"
done >> $ROOT_ZONE

cat >> $ROOT_ZONE << "EOT"
;
; begin root zone data here:
;
EOT


# header for regular (tld) zone files
TLD_ZONE_HDR=$(
  cat <<- "EOT"
	$TTL 300
	$ORIGIN @
	@ SOA ns.level3.net. admin.step-fwd.net. (15061601 600 300 800 300)
	EOT
  for NS in "${!TOPLEVEL_NS[@]}"; do
    echo -e "\t\t\tNS\t$NS."
  done
  for NS in "${!TOPLEVEL_NS[@]}"; do
    echo -e "$NS.\tA\t${TOPLEVEL_NS[$NS]}"
  done
  cat <<- "EOT"
	;
	; begin zone data here:
	;
	EOT
) # end regular zone header


# verify existence of forward zone, creating it if necessary:
function ensure_exists_forward
  if [ ! -s "$TLD_ZD/$1.zone" ]; then
    # create forward zone file, paste generic header:
    echo "$TLD_ZONE_HDR" > $TLD_ZD/$1.zone

    # add zone entry in named.conf:
    cat >> $NAMED_CONF << EOT
	zone "$1" IN {
		type master;
		file "$TLD_ZD/$1.zone";
		allow-update { none; };
	};
EOT

    # add NS records pointing at our TLD servers to root.zone:
    for NS in "${!TOPLEVEL_NS[@]}"; do
      echo -e "$1.\tNS\t$NS" >> $ROOT_ZONE
    done
  fi


# verify existence of reverse zone, creating it if necessary:
function ensure_exists_reverse
  if [ ! -s "$TLD_ZD/$1.zone" ]; then
    # create reverse zone file, paste generic header:
    echo "$TLD_ZONE_HDR" > $TLD_ZD/$1.zone

    # add zone entry in named.conf:
    cat >> $NAMED_CONF << EOT
	zone "$1.in-addr.arpa." IN {
		type master;
		file "$TLD_ZD/$1.zone";
		allow-update { none; };
	};
EOT
  fi


# add A and PTR records for all hosts in $HOSTS_LIST, creating zones if needed:
for FQDN in "${!HOSTS_LIST[@]}"; do

  IPADDR=${HOSTS_LIST[$FQDN]}

  # parse IP address octets (no sanity checking):
  # FIXME: parse into array, then use [0], [1], [2], and [3] instead!!!
  IFS=. read IP1 IP2 IP3 IP4 <<< "$IPADDR"

  # parse TLD (last dot-separated segment of FQDN):
  TLD=${FQDN##*.}

  # add A record for this host (stripping off $TLD from $FQDN):
  ensure_exists_forward $TLD
  echo -e "${FQDN%.*}\tA\t$IPADDR" >> $TLD_ZD/$TLD.zone

  # add PTR record to reverse zone file
  ensure_exists_reverse $IP1
  echo -e "$IP4.$IP3.$IP2\tPTR\t$FQDN." >> $TLD_ZD/$IP1.zone

done # end for FQDN in "${!HOSTS_LIST[@]}"


# add NS records for all forward delegations:
for DOM in "${!DELEGATIONS_FWD[@]}"; do

  # parse TLD (last dot-separated segment of DOM):
  TLD=${DOM##*.}

  # add NS record for each of DOM's designated name servers:
  ensure_exists_forward $TLD
  for NS in ${DELEGATIONS_FWD[$DOM]}; do
    echo -e "${DOM%.*}\tNS\t$NS." >> $TLD_ZD/$TLD.zone
  done

done # for DOM in "${!DELEGATIONS_FWD[@]}"


# add NS records for all reverse delegations:
for NET in "${!DELEGATIONS_REV[@]}"; do

  # parse IP network octets (no sanity checking):
  # FIXME: parse into array... (see above)
  IFS=. read IP1 IP2 IP3 <<< "$NET"

  # add NS record for each of DOM's designated name servers:
  ensure_exists_reverse $IP1
  for NS in ${DELEGATIONS_REV[$NET]}; do
    echo -e "$IP3.$IP2\tNS\t$NS." >> $TLD_ZD/$IP1.zone
  done

done # for NET in "${!DELEGATIONS_REV[@]}"


# add MX records for all vmail domains:
for DOM in "${!DOMAIN_MX[@]}"; do

  # parse TLD (last dot-separated segment of DOM):
  TLD=${DOM##*.}

  # add MX record for each of DOM's designated name servers:
  ensure_exists_forward $TLD
  for MX in ${DOMAIN_MX[$DOM]}; do
    echo -e "${DOM%.*}\tMX\t10\t$MX." >> $TLD_ZD/$TLD.zone
  done

done # for DOM in "${!DELEGATIONS_FWD[@]}"


# close out named.conf:
echo '};' >> $NAMED_CONF


# we're done!
SUCCESS_BLURB="
SUCCESS: bind9 configuration generated based on the following inputs:

    Web hosts:   $SRC_WHOSTS
    Xtra hosts:  $([ -n "$SRC_XHOSTS" -a -s "$SRC_XHOSTS" ] && echo $SRC_XHOSTS)
    Mail srvrs:  $([ -s "$SRC_MHOSTS" ] && echo $SRC_MHOSTS)
    Delegations: $SRC_DELEG

Output was written to the following locations:

    DNS hosts:   $NAMED_HOSTS
    named.conf:  $NAMED_CONF
    zone folder: $NAMED_ZD

Required next steps may include:

    - update loopback interface to contain virtual DNS host IP addresses

    - (re-)start topgen-named service
"

[ "$QUIET_GEN" == "no" ] && echo "$SUCCESS_BLURB"


# FIXME: Sort out SELinux policy associated with topgen package !!!
# But, for now, let's label the relevant files for use by named:
chcon -t named_conf_t $NAMED_CONF
chcon -R -t named_zone_t $NAMED_ZD/*
