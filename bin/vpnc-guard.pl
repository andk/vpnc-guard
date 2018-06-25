#!/usr/bin/env perl

=head1 NAME

vpnc-guard.pl - TODO

=head1 SYNOPSIS

Run as root in endless loop:

  C<< while true; do ./bin/vpnc-guard.pl; date; sleep 60; done >>

=cut

use strict;
use warnings;
use Carp;
use Commands::Guarded qw(:default fgrep);
use DateTime;
use Log::Log4perl;

{

    package Testrunner;
    use Moose;
    with qw/
        MooseX::Getopt
        MooseX::SimpleConfig
        /;

    use Moose::Util::TypeConstraints;
    use namespace::autoclean;

=head1 PARAMETERS

=cut

    has "dry_run",
        is       => 'ro',
        isa      => 'Bool',
        init_arg => "dry-run";

    has "verbose",
        is  => 'ro',
        isa => 'Bool',
        ;
    has "networkinterrupt",
        is            => 'ro',
        isa           => 'Str',
        default       => '^04:0[45]:',
        documentation => <<'HERE';
force reconnect
HERE

    has "to_sleep",
        is      => "ro",
        isa     => "Int",
        default => 15;

    has "to_resolve",
        is            => "ro",
        isa           => "Str",
        required      => 1,
        documentation => <<'HERE';
host name shoud be resolveable
HERE

    has "ping_times",
        is            => "ro",
        isa           => "Int",
        default       => 6,
        documentation => <<'HERE';
the number of ping attempts
HERE

    has "default_gateway",
        is            => "ro",
        isa           => "Str",
        required      => 1,
        documentation => <<'HERE';
the value of "ip route add default via .."
HERE

    has "route_to_ensure",
        is            => "ro",
        isa           => "ArrayRef[Str]",
        required      => 1,
        auto_deref    => 1,
        documentation => <<'HERE';
a list of routes should be insured
HERE

    has "nameserver_qr",
        is            => "ro",
        isa           => "Str",
        required      => 1,
        documentation => <<'HERE';
a nameserver value of /etc/resolv.conf to be matched
HERE

    has "host_to_ping",
        is            => "ro",
        isa           => "ArrayRef[Str]",
        required      => 0,
        default       => sub {qw/ 8.8.8.8 /},
        auto_deref    => 1,
        documentation => <<'HERE';
a list of hosts to ping
HERE

=head2 logger_config

    C<logger_config> is subtype of C<LoggerConfigStr>.

    Configuration of C<_log> parameter.

    cmd alias: lc

=cut

    subtype "LoggerConfigStr", as "Str", where {

        # do init for config validation purpose
        local $Log::Log4perl::Config::CONFIG_INTEGRITY_CHECK;
        Log::Log4perl::init_once(\$_);
        Log::Log4perl::Config::config_is_sane();
    }, message {
        sprintf "Log::Log4perl configuration check failed:\n%s", $_ || '';
    };

    has "logger_config",
        is       => "ro",
        isa      => "LoggerConfigStr",
        required => 0,
        default  => <<'HERE',
log4perl.rootLogger              = DEBUG, Screen
log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
log4perl.appender.Screen.stderr  = 0
log4perl.appender.Screen.layout=PatternLayout
log4perl.appender.Screen.layout.ConversionPattern=%d %5p [%5P]%L - %m%n
HERE
        documentation => <<'HERE';
logger_config is subtype of LoggerConfigStr.
Configuration of _log parameter.
HERE

=head2 __log

C<Log::Log4perl::Logger> object

=cut

    has "_log",
        init_arg      => undef,
        is            => "ro",
        isa           => "Log::Log4perl::Logger",
        lazy_build    => 1,
        documentation => <<'HERE';
_log is an object of Log::Log4perl::Logger initialized with logger_config property
HERE

    sub _build__log {
        my ($self) = @_;
        my $cfg = $self->logger_config;
        Log::Log4perl::init_once(\$cfg);
        return Log::Log4perl->get_logger();
    } ## end sub _build__log

    sub die_if_dryrun {
        my ($self, $mess) = @_;
        $mess ||= caller;
        if ($self->dry_run) {
            Carp::confess($mess);
        }
        elsif ($self->verbose) {
            $self->_log->info("Entering $mess");
        }
    } ## end sub die_if_dryrun

    no Moose;
}

my $tr = Testrunner->new_with_options();

my $vpnc_config = qw|/etc/vpnc/default.conf|;
-r $vpnc_config || $tr->_log->logdie("can't read $vpnc_config");

my $hms_matcher = $tr->networkinterrupt;
if ($hms_matcher) {
    my $hms = DateTime->now(time_zone => 'Europe/Berlin')->hms;
    my $qr = qr/$hms_matcher/;
    if ($tr->verbose) {
        $tr->_log->info("hms=$hms qr=$qr");
    }
    if ($hms =~ $qr) {
        if ($tr->dry_run) {
            $tr->_log->info("DRYRUN: WOULD NOW INTERRUPT NETWORK");
        }
        else {
            $tr->_log->warn("ALERT EVERYBODY: NETWORK INTERRUPT NOW!");
            system "vpnc-disconnect";
        }
        exit;
    } ## end if ($hms =~ $qr)
} ## end if ($hms_matcher)

step "setup wlan" => ensure {
    unless (fgrep qr/ESSID:"(?:TC-Intern)"/, "iwconfig wlan0 |") {
        $tr->_log->warn('does not match ESSID:"(?:TC-Intern)');
        return 0;
    }
    $tr->_log->info("WLAN OK");
    return 1;
} ## end ensure
using {
    # 0 == system iwconfig => 'wlan0', 'essid', 'TC-Intern' or die;
    # ^^ reichte nicht am 5.1.2018

    0 == system "/etc/init.d/network-manager", "restart"
        or $tr->_log->logdie("Could not restart network manager");

    # ^^ noch nicht battle-tested, introduced 5.1.2018

    # die "please make sure the wlan runs for TC-Intern";
    # iwconfig wlan0 essid TC-Intern
    # vpnc-connect is called elsewhere, so it has probably not succeeded
};

my $only_wlan_default_route = step only_wlan_default_route => ensure {
    open my $fh, "-|", ip => "route";
    my $seen = 0;
    while (<$fh>) {
        my ($net) = /^(default)\s.*\bdev wlan0/ or next;
        $seen++;
    }
    unless (close $fh) {
        $tr->_log->warn("no dev wlan in ip r");
        return 0;
    }
    unless ($seen == 1) {
        $tr->_log->warn("wlan routes counted should be 1, is $seen");
        return 0;
    }
    $tr->_log->info("DEFAULT ROUTE COUNT 1 OK");
    return 1;
} ## end ensure
using {
    $tr->die_if_dryrun();

    # die "did not see a uniq default route";
    open my $fh, "-|", ip => "route";
    my $has_wlan;
    while (<$fh>) {
        my ($full, $net) = /^(default.+dev\s+(\w+))/ or next;
        if ($net =~ /^wlan0/) {
            $has_wlan = 1;
            next;
        }
        system "ip route del $full";
    } ## end while (<$fh>)
    unless (close $fh) {
        $tr->_log->warn("ERROR");
        return 0;
    }
    unless ($has_wlan) {
        system join ' ', "ip route add default via", $tr->default_gateway;
    }
    return 1;
};

my $ensure_route_tun = step ensure_route_tun => ensure {
    my ($route) = @_;
    open my $fh, "-|", ip => "route";
    my $seen = 0;
    while (<$fh>) {
        my ($net, $tun_dev) = /^(\S+) via [0-9\.]+ dev (tun\d+)/ or next;
        if ($net eq $route) {
            $seen = 1;
        }
    } ## end while (<$fh>)
    unless (close $fh) {
        $tr->_log->error("could not close 'ip r' handle");
        return 0;
    }
    unless ($seen) {
        $tr->_log->error("no route for $route seen");
        return 0;
    }
    $tr->_log->warn("ROUTE $route OK");
    return 1;
} ## end ensure
using {
    $tr->die_if_dryrun();
    my ($route) = @_;

    # die "please set route for $route";
    my ($tun_dev, $in_tun, $tun_gate);
    open my $fh, "-|", ip => "addr";
    while (<$fh>) {
        my ($dev) = /^\d+:\s+([a-z0-9]+):/;
        if ($dev && $dev =~ /^tun\d+$/) {
            $in_tun  = 1;
            $tun_dev = $dev;
        }
        elsif ($dev) {
            $in_tun = 0;
        }
        if ($in_tun) {
            if (/inet ([0-9\.]+)\/32/) {
                $tun_gate = $1;
            }
        }
    } ## end while (<$fh>)
    unless (close $fh) {
        $tr->_log->warn("error on close of 'ip a'");
        return 0;
    }
    unless ($tun_dev && $tun_gate) {
        $tr->_log->warn("no tun interface in 'ip a'");
        return 0;
    }

    system ip => 'route', 'add', $route, 'via', $tun_gate;
};

step setup_vpnc => ensure {
    my ($pid, $nameserver, $resolved);
    {
        open my $fh, "-|", "ps auxww | grep vpnc-connect|grep -v grep";
        while (<$fh>) {
            if (/^root\s+(\d+)/) {
                $pid = $1;
                last;
            }
        } ## end while (<$fh>)
        unless ($pid) {
            $tr->_log->warn("pid for vpnc-connect process not found");
            return 0;
        }
        $tr->_log->info("VPNC PROCESS $pid OK");
    }
    {
        my $nameserver_qr = $tr->nameserver_qr;
        my $resolv_conf   = q|/etc/resolv.conf|;

        open my $fh, "-|",
            "grep '^nameserver' $resolv_conf | head -2 | grep '$nameserver_qr'";
        while (<$fh>) {
            if (/^nameserver\s+([0-9\.]+)/) {
                $nameserver = $1;
                last;
            }
        } ## end while (<$fh>)
        unless ($nameserver) {
            $tr->_log->warn("no $nameserver_qr in $resolv_conf");
            return 0;
        }
        $tr->_log->warn("seen $nameserver_qr in $resolv_conf");
    }

    $only_wlan_default_route->do;

    $ensure_route_tun->do_foreach($tr->route_to_ensure);
    {
        my $trypingnameserver = $tr->ping_times;
    TRY: for my $i (1 .. $trypingnameserver) {
            open my $fh, "-|", ping => '-c', 1, $nameserver;
            while (<$fh>) {

                # print
            }
            if (close $fh) {
                last TRY;
            }
            elsif ($i < $trypingnameserver) {
                $tr->_log->warn(
                    "cannot ping nameserver '$nameserver', will retry");
                sleep 5;
            }
            else {
                my $allow_broken_nameserverping_forever = 0;
                if ($allow_broken_nameserverping_forever) {

                    # nonono: we have no better indicator for a borken
                    # network than the nameserver as far as I know, so if
                    # the nameserver goes away we need to tear down that
                    # building and rebuild it. Last week Alexei suggested
                    # that we ignore the broken nameserver and the outcome
                    # was that nobody rebuilt anything forever.
                    $tr->_log->warn(
                        "cannot ping nameserver '$nameserver' in $trypingnameserver attempts but we probably can wait until later with this"
                    );
                    return 1;
                } ## end if ($allow_broken_nameserverping_forever)
                return 0;
            } ## end else [ if (close $fh) ]
        } ## end TRY: for my $i (1 .. $trypingnameserver)
        $tr->_log->info("PING NAMESERVER OK");
    }
    {
        my $to_resolve = $tr->to_resolve;
        open my $fh, "-|", host => $to_resolve;
        while (<$fh>) {
            if (/$to_resolve has address ([0-9\.]+)/) {
                $resolved = $1;
                last;
            }
        } ## end while (<$fh>)
        unless ($resolved) {
            $tr->_log->warn("cannot resolve $to_resolve");
            return 0;
        }
        $tr->_log->info("resolved $to_resolve");
    }
    {
        my $trypingsomeserver = $tr->ping_times;  # 12 took really annoying long
        for my $s ($resolved, $tr->host_to_ping) {
        TRY: for my $i (1 .. $trypingsomeserver) {
                open my $fh, "-|", ping => '-c', 1, $s;
                while (<$fh>) {

                    # print
                }
                if (close $fh) {
                    last TRY;
                }
                elsif ($i < $trypingsomeserver) {
                    $tr->_log->warn("cannot ping someserver '$s', will retry");
                    sleep 4;
                    next TRY;
                }
                else {
                    my $ignore = 1;
                    if ($ignore) {
                        $tr->_log->error(
                            "cannot ping '$s', but will ignore for now");
                        return 1;
                    }
                    else {
                        $tr->_log->info("cannot ping '$s'");
                        return 0;
                    }
                } ## end else [ if (close $fh) ]
                $tr->_log->info("PING $s OK");
            } ## end TRY: for my $i (1 .. $trypingsomeserver)
        } ## end for my $s ($resolved, $tr...)
        $tr->_log->info("PING someservers OK");
    }
    return 1;
} ## end ensure
using {
    $tr->die_if_dryrun("setup_vpnc");
    my $to_sleep = $tr->to_sleep;
    system "vpnc-disconnect";
    $tr->_log->info("sleeping $to_sleep after disconnect");
    sleep $to_sleep;
    system "vpnc-connect";
    $tr->_log->info("sleeping $to_sleep after connect");
    sleep $to_sleep;
};

$only_wlan_default_route->do;
