package Nagios::Web::Controller::status;

use strict;
use warnings;
use parent 'Catalyst::Controller';

=head1 NAME

Nagios::Web::Controller::status - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut


=head2 index

=cut

sub index :Path :Args(0) :MyAction('AddDefaults') {
    my ( $self, $c ) = @_;

    my $allowed_subpages = {'detail' => 1, 'grid' => 1, 'hostdetail' => 1, 'overview' => 1, 'summmary' => 1};
    my $style = $c->{'request'}->{'parameters'}->{'style'} || 'detail';
    $style = 'detail' unless defined $allowed_subpages->{$style};

    if($style eq 'detail') {
        $self->_process_details_page($c);
    }
    elsif($style eq 'hostdetail') {
        $self->_process_hostdetails_page($c);
    }

    $c->stash->{title}          = 'Current Network Status';
    $c->stash->{infoBoxTitle}   = 'Current Network Status';
    $c->stash->{page}           = 'status';
    $c->stash->{template}       = 'status_'.$style.'.tt';
}

##########################################################
# create the hostdetails page
sub _process_hostdetails_page {
    my ( $self, $c ) = @_;

    # which hostgroup to display?
    my $hostgroup = $c->{'request'}->{'parameters'}->{'hostgroup'} || 'all';
    my $hostfilter    = "";
    my $servicefilter = "";
    if($hostgroup ne 'all') {
        $hostfilter    = "Filter: groups >= $hostgroup\n";
        $servicefilter = "Filter: host_groups >= $hostgroup\n";
    }

    # fill the host/service totals box
    $self->_fill_totals_box($c, $hostfilter, $servicefilter);

    # then add some more filter based on get parameter
    ($hostfilter,$servicefilter) = $self->_extend_filter($c,$hostfilter,$servicefilter);

    # TODO: add comments into hosts.comments and hosts.comment_count
    my $hosts = $c->{'live'}->selectall_arrayref("GET hosts\n$hostfilter", { Slice => {} });
    for my $host (@{$hosts}) {
        $host->{'comment_count'} = 0;
    }

    # do the sort
    my $sorttype   = $c->{'request'}->{'parameters'}->{'sorttype'}   || 1;
    my $sortoption = $c->{'request'}->{'parameters'}->{'sortoption'} || 7;
    my $order = "ASC";
    $order = "DESC" if $sorttype == 2;
    my $sortoptions = {
                '1' => [ 'name',                         'host name'       ],
                '4' => [ ['last_check', 'name'],         'last check time' ],
                '6' => [ ['last_state_change', 'name'],  'state duration'  ],
                '8' => [ ['state', 'name'],              'host status'     ],
    };
    $sortoption = 1 if !defined $sortoptions->{$sortoption};
    my $sortedhosts = Nagios::Web::Helper->sort($c, $hosts, $sortoptions->{$sortoption}->[0], $order);

    $c->stash->{'orderby'}       = $sortoptions->{$sortoption}->[1];
    $c->stash->{'orderdir'}      = $order;
    $c->stash->{'hostgroup'}     = $hostgroup;
    $c->stash->{'hosts'}         = $sortedhosts;
}


##########################################################
sub _fill_totals_box {
    my ( $self, $c, $hostfilter, $servicefilter ) = @_;
    # host status box
    my $host_stats = $c->{'live'}->selectrow_hashref("GET hosts
$hostfilter
Stats: has_been_checked = 1
Stats: state = 0
StatsAnd: 2 as up

Stats: has_been_checked = 1
Stats: state = 1
StatsAnd: 2 as down

Stats: has_been_checked = 1
Stats: state = 2
StatsAnd: 2 as unreachable

Stats: has_been_checked = 0 as pending
");

    # services status box
    my $service_stats = $c->{'live'}->selectrow_hashref("GET services
$servicefilter
Stats: has_been_checked = 1
Stats: state = 0
StatsAnd: 2 as ok

Stats: has_been_checked = 1
Stats: state = 1
StatsAnd: 2 as warning

Stats: has_been_checked = 1
Stats: state = 2
StatsAnd: 2 as critical

Stats: has_been_checked = 1
Stats: state = 3
StatsAnd: 2 as unknown

Stats: has_been_checked = 0 as pending
");

    $c->stash->{'host_stats'}    = $host_stats;
    $c->stash->{'service_stats'} = $service_stats;
}

##########################################################
sub _extend_filter {
    my ( $self, $c, $hostfilter, $servicefilter ) = @_;

    $hostfilter    = '' unless defined $hostfilter;
    $servicefilter = '' unless defined $servicefilter;

    # host statustype filter (up,down,...)
    my($host_statustype_filtername,$host_statustype_filter,$host_statustype_filter_service)
            = $self->_get_host_statustype_filter($c->{'request'}->{'parameters'}->{'hoststatustypes'});
    $hostfilter    .= $host_statustype_filter;
    $servicefilter .= $host_statustype_filter_service;

    $c->stash->{'show_filter_table'}          = 1 if $host_statustype_filter ne '';
    $c->stash->{'host_statustype_filtername'} = $host_statustype_filtername;

    # host props filter (downtime, acknowledged...)
    my($host_prop_filtername,$host_prop_filter,$host_prop_filter_service) = $self->_get_host_prop_filter($c->{'request'}->{'parameters'}->{'hostprops'});
    $hostfilter    .= $host_prop_filter;
    $servicefilter .= $host_prop_filter_service;

    $c->stash->{'show_filter_table'}    = 1 if $host_prop_filter ne '';
    $c->stash->{'host_prop_filtername'} = $host_prop_filtername;


    return($hostfilter,$servicefilter);
}

##########################################################
sub _get_host_statustype_filter {
    my ( $self, $number ) = @_;

    $number = 15 if !defined $number or $number <= 0 or $number > 15;
    my $hoststatusfiltername = 'All';
    my $hostfilter           = '';
    my $servicefilter        = '';
    if($number and $number != 15) {
        my @hoststatusfilter;
        my @servicestatusfilter;
        my @hoststatusfiltername;
        my @bits = reverse split(/ */, unpack("B*", pack("n", int($number))));

        if($bits[0]) {  # 1 - pending
            push @hoststatusfilter,    "Filter: has_been_checked = 0";
            push @servicestatusfilter, "Filter: host_has_been_checked = 0";
            push @hoststatusfiltername, 'Pending';
        }
        if($bits[1]) {  # 2 - up
            push @hoststatusfilter,    "Filter: state = 0\nFilter: has_been_checked = 1\nAnd: 2";
            push @servicestatusfilter, "Filter: host_state = 0\nFilter: has_been_checked = 1\nAnd: 2";
            push @hoststatusfiltername, 'Up';
        }
        if($bits[2]) {  # 4 - down
            push @hoststatusfilter,    "Filter: state = 1\nFilter: has_been_checked = 1\nAnd: 2";
            push @servicestatusfilter, "Filter: host_state = 1\nFilter: has_been_checked = 1\nAnd: 2";
            push @hoststatusfiltername, 'Down';
        }
        if($bits[3]) {  # 4 - unreachable
            push @hoststatusfilter,    "Filter: state = 2\nFilter: has_been_checked = 1\nAnd: 2";
            push @servicestatusfilter, "Filter: host_state = 2\nFilter: has_been_checked = 1\nAnd: 2";
            push @hoststatusfiltername, 'Unreachable';
        }
        $hoststatusfiltername = join(' | ', @hoststatusfiltername);
        $hoststatusfiltername = 'All problems' if $number == 12;

        if(scalar @hoststatusfilter > 1) {
            $hostfilter    .= join("\n", @hoststatusfilter)."\nOr: ".(scalar @hoststatusfilter)."\n";
            $servicefilter .= join("\n", @servicestatusfilter)."\nOr: ".(scalar @servicestatusfilter)."\n";
        }
        elsif(scalar @hoststatusfilter == 1) {
            $hostfilter    .= $hoststatusfilter[0]."\n";
            $servicefilter .= $servicestatusfilter[0]."\n";
        }
    }
    return($hoststatusfiltername,$hostfilter,$servicefilter);
}

##########################################################
sub _get_host_prop_filter {
    my ( $self, $number ) = @_;

    $number = 0 if !defined $number or $number <= 0 or $number > 1048575;
    my $host_prop_filtername = 'Any';
    my $hostfilter           = '';
    my $servicefilter        = '';
    if($number > 0) {
        my @host_prop_filter;
        my @host_prop_filter_service;
        my @host_prop_filtername;
        my @bits = reverse split(/ */, unpack("B*", pack("N", int($number))));

        if($bits[0]) {  # 1 - In Scheduled Downtime
            push @host_prop_filter,         "Filter: scheduled_downtime_depth > 0";
            push @host_prop_filter_service, "Filter: host_scheduled_downtime_depth > 0";
            push @host_prop_filtername,     'In Scheduled Downtime';
        }
        if($bits[1]) {  # 2 - Not In Scheduled Downtime
            push @host_prop_filter,         "Filter: scheduled_downtime_depth = 0";
            push @host_prop_filter_service, "Filter: host_scheduled_downtime_depth = 0";
            push @host_prop_filtername,     'Not In Scheduled Downtime';
        }
        if($bits[2]) {  # 4 - Has Been Acknowledged
            push @host_prop_filter,         "Filter: acknowledged = 1";
            push @host_prop_filter_service, "Filter: host_acknowledged = 1";
            push @host_prop_filtername,     'Has Been Acknowledged';
        }
        if($bits[3]) {  # 8 - Has Not Been Acknowledged
            push @host_prop_filter,         "Filter: acknowledged = 0";
            push @host_prop_filter_service, "Filter: host_acknowledged = 0";
            push @host_prop_filtername,     'Has Not Been Acknowledged';
        }
        if($bits[4]) {  # 16 - Checks Disabled
            push @host_prop_filter,         "Filter: checks_enabled = 0";
            push @host_prop_filter_service, "Filter: host_checks_enabled = 0";
            push @host_prop_filtername,     'Checks Disabled';
        }
        if($bits[5]) {  # 32 - Checks Enabled
            push @host_prop_filter,         "Filter: checks_enabled = 1";
            push @host_prop_filter_service, "Filter: host_checks_enabled = 1";
            push @host_prop_filtername,     'Checks Enabled';
        }
        if($bits[6]) {  # 64 - Event Handler Disabled
            push @host_prop_filter,         "Filter: event_handler_enabled = 0";
            push @host_prop_filter_service, "Filter: host_event_handler_enabled = 0";
            push @host_prop_filtername,     'Event Handler Disabled';
        }
        if($bits[7]) {  # 128 - Event Handler Enabled
            push @host_prop_filter,         "Filter: event_handler_enabled = 1";
            push @host_prop_filter_service, "Filter: host_event_handler_enabled = 1";
            push @host_prop_filtername,     'Event Handler Enabled';
        }
        if($bits[8]) {  # 256 - Flap Detection Disabled
            push @host_prop_filter,         "Filter: flap_detection_enabled = 0";
            push @host_prop_filter_service, "Filter: host_flap_detection_enabled = 0";
            push @host_prop_filtername,     'Flap Detection Disabled';
        }
        if($bits[9]) {  # 512 - Flap Detection Enabled
            push @host_prop_filter,         "Filter: flap_detection_enabled = 1";
            push @host_prop_filter_service, "Filter: host_flap_detection_enabled = 1";
            push @host_prop_filtername,     'Flap Detection Enabled';
        }
        if($bits[10]) {  # 1024 - Is Flapping
            push @host_prop_filter,         "Filter: is_flapping = 1";
            push @host_prop_filter_service, "Filter: host_is_flapping = 1";
            push @host_prop_filtername,     'Is Flapping';
        }
        if($bits[11]) {  # 2048 - Is Not Flapping
            push @host_prop_filter,         "Filter: is_flapping = 0";
            push @host_prop_filter_service, "Filter: host_is_flapping = 0";
            push @host_prop_filtername,     'Is Not Flapping';
        }
        if($bits[12]) {  # 4096 - Notifications Disabled
            push @host_prop_filter,         "Filter: notifications_enabled = 0";
            push @host_prop_filter_service, "Filter: host_notifications_enabled = 0";
            push @host_prop_filtername,     'Notifications Disabled';
        }
        if($bits[13]) {  # 8192 - Notifications Enabled
            push @host_prop_filter,         "Filter: notifications_enabled = 1";
            push @host_prop_filter_service, "Filter: host_notifications_enabled = 1";
            push @host_prop_filtername,     'Notifications Enabled';
        }
        if($bits[14]) {  # 16384 - Passive Checks Disabled
            push @host_prop_filter,         "Filter: accept_passive_checks = 0";
            push @host_prop_filter_service, "Filter: host_accept_passive_checks = 0";
            push @host_prop_filtername,     'Passive Checks Disabled';
        }
        if($bits[15]) {  # 32768 - Passive Checks Enabled
            push @host_prop_filter,         "Filter: accept_passive_checks = 1";
            push @host_prop_filter_service, "Filter: host_accept_passive_checks = 1";
            push @host_prop_filtername,     'Passive Checks Enabled';
        }
        if($bits[16]) {  # 65536 - Passive Checks
            push @host_prop_filter,         "Filter: check_type = 1";
            push @host_prop_filter_service, "Filter: host_check_type = 1";
            push @host_prop_filtername,     'Passive Checks';
        }
        if($bits[17]) {  # 131072 - Active Checks
            push @host_prop_filter,         "Filter: check_type = 0";
            push @host_prop_filter_service, "Filter: host_check_type = 0";
            push @host_prop_filtername,     'Active Checks';
        }
        if($bits[18]) {  # 262144 - In Hard State
            push @host_prop_filter,         "Filter: hard_state = 0";
            push @host_prop_filter_service, "Filter: host_hard_state = 0";
            push @host_prop_filtername,     'In Hard State';
        }
        if($bits[19]) {  # 524288 - In Soft State
            push @host_prop_filter,         "Filter: hard_state = 1";
            push @host_prop_filter_service, "Filter: host_hard_state = 1";
            push @host_prop_filtername,     'In Soft State';
        }

        $host_prop_filtername = join(' & ', @host_prop_filtername);

        if(scalar @host_prop_filter > 1) {
            $hostfilter    .= join("\n", @host_prop_filter)."\nAnd: ".(scalar @host_prop_filter)."\n";
            $servicefilter .= join("\n", @host_prop_filter_service)."\nAnd: ".(scalar @host_prop_filter_service)."\n";
        }
        elsif(scalar @host_prop_filter == 1) {
            $hostfilter    .= $host_prop_filter[0]."\n";
            $servicefilter .= $host_prop_filter_service[0]."\n";
        }
    }
    return($host_prop_filtername,$hostfilter,$servicefilter);
}

=head1 AUTHOR

Sven Nierlein, 2009, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;