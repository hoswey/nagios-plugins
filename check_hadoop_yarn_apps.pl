#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2014-03-05 21:45:08 +0000 (Wed, 05 Mar 2014)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

$DESCRIPTION = "Nagios Plugin to check Hadoop Yarn Apps via Resource Manager jmx

Checks a given queue, 'default' if not specified. Can also list queues for convenience.

Optional thresholds on running yarn apps to aid in capacity planning

Tested on Hortonworks HDP 2.1 (Hadoop 2.4.0.2.1.1.0-385) with Capacity Scheduler queues";

$VERSION = "0.4";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils;
use Data::Dumper;
use JSON::XS;
use LWP::Simple '$ua';

$ua->agent("Hari Sekhon $progname version $main::VERSION");

set_port_default(8088);

env_creds(["HADOOP_YARN_RESOURCE_MANAGER", "HADOOP"], "Yarn Resource Manager");

my $queue = "default";
my $list_queues;

%options = (
    %hostoptions,
    "Q|queue=s"      =>  [ \$queue,         "Queue to output stats for, prefixed with root queue which may be optionally omitted (default: root.default)" ],
    "list-queues"    =>  [ \$list_queues,   "List all queues" ],
    %thresholdoptions,
);
splice @usage_order, 6, 0, qw/queue list-queues/;

get_options();

$host       = validate_host($host);
$port       = validate_port($port);
validate_thresholds(0, 0, { "simple" => "upper", "positive" => 1, "integer" => 0 });

vlog2;
set_timeout();

$status = "OK";

my $url = "http://$host:$port/jmx";

my $content = curl $url;

try{
    $json = decode_json $content;
};
catch{
    quit "invalid json returned by Yarn Resource Manager at '$url'";
};
vlog3(Dumper($json));

my @beans = get_field_array("beans");

# Other MBeans of interest:
#
#       Hadoop:service=ResourceManager,name=RpcActivityForPort8025 (RPC)
#       Hadoop:service=ResourceManager,name=RpcActivityForPort8050 (RPC)
#       java.lang:type=MemoryPool,name=Code Cache
#       java.lang:type=Threading
#       Hadoop:service=ResourceManager,name=RpcActivityForPort8141
#       Hadoop:service=ResourceManager,name=RpcActivityForPort8030
#       Hadoop:service=ResourceManager,name=JvmMetrics
my $apps_submitted = 0;
my $apps_running   = 0;
my $apps_pending   = 0;
my $apps_completed = 0;
my $apps_killed    = 0;
my $apps_failed    = 0;
my $active_users   = 0;
my $active_apps    = 0;

my $mbean_queuemetrics = "Hadoop:service=ResourceManager,name=QueueMetrics";
my $mbean_name = "$mbean_queuemetrics";
$queue =~ /^root(?:\.|$)/ or $queue = "root.$queue";
my $i=0;
foreach(split(/\./, $queue)){
    $mbean_name .= ",q$i=$_";
    $i++;
}
$queue =~ s/^root\.//;
vlog2 "searching for mbean $mbean_name" unless $list_queues;
my @queues;
my $found_queue = 0;
foreach(@beans){
    vlog2 Dumper($_) if get_field2($_, "name") =~ /QueueMetrics/;
    my $this_mbean_name = get_field2($_, "name");
    if($this_mbean_name =~ /^$mbean_queuemetrics,q0=(.*)$/){
        my $q_name = $1;
        $q_name =~ s/,q\d+=/./;
        push(@queues, $q_name);
    }
    next unless $this_mbean_name =~ /^$mbean_name$/;
    $found_queue++;
    $apps_submitted = get_field2_int($_, "AppsSubmitted");
    $apps_running   = get_field2_int($_, "AppsRunning");
    $apps_pending   = get_field2_int($_, "AppsPending");
    $apps_completed = get_field2_int($_, "AppsCompleted");
    $apps_killed    = get_field2_int($_, "AppsKilled");
    $apps_failed    = get_field2_int($_, "AppsFailed");
    $active_users   = get_field2_int($_, "ActiveUsers");
    $active_apps    = get_field2_int($_, "ActiveApplications");
}
if($list_queues){
    print "Queues:\n\n";
    foreach(@queues){
        print "$_\n";
    }
    exit $ERRORS{"UNKNOWN"};
}
quit "UNKNOWN", "failed to find mbean for queue '$queue'. Did you specify the correct queue name? See --list-queues for valid queue names. If you're sure you've specified the right queue name then $nagios_plugins_support_msg_api" unless $found_queue;
quit "UNKNOWN", "duplicate mbeans found for queue '$queue'! $nagios_plugins_support_msg_api" if $found_queue > 1;

$msg  = "yarn apps for queue '$queue': ";
$msg .= "$apps_running running";
check_thresholds($apps_running);
$msg .= ", ";
$msg .= "$apps_pending pending, ";
$msg .= "$active_apps active, ";
$msg .= "$apps_submitted submitted, ";
$msg .= "$apps_completed completed, ";
$msg .= "$apps_killed killed, ";
$msg .= "$apps_failed failed. ";
plural $active_users;
$msg .= "$active_users active user$plural";
$msg .= " | ";
$msg .= "'apps running'=$apps_running";
msg_perf_thresholds();
$msg .= " ";
$msg .= "'apps pending'=$apps_pending ";
$msg .= "'apps active'=$active_apps ";
$msg .= "'apps submitted'=${apps_submitted}c ";
$msg .= "'apps completed'=${apps_completed}c ";
$msg .= "'apps killed'=${apps_killed}c ";
$msg .= "'apps failed'=${apps_failed}c ";
$msg .= "'active users'=$active_users";

quit $status, $msg;