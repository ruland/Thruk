package Thruk::Utils;

=head1 NAME

Thruk::Utils - Utilities Collection for Thruk

=head1 DESCRIPTION

Utilities Collection for Thruk

=cut

use strict;
use warnings;
use Config::General;
use Carp;
use Data::Dumper;
use Digest::MD5  qw(md5_hex);
use Date::Calc qw/Localtime Mktime Monday_of_Week Week_of_Year Today/;
use Monitoring::Livestatus::MULTI;


##############################################
=head1 METHODS

=cut

##############################################

=head2 get_auth_filter

  my $filter_string = get_auth_filter('hosts');

returns a filter which can be used for authorization

=cut
sub get_auth_filter {
    my $c    = shift;
    my $type = shift;

    return("") if $type eq 'status';

    # if authentication is completly disabled
    if($c->{'cgi_cfg'}->{'use_authentication'} == 0 and $c->{'cgi_cfg'}->{'use_ssl_authentication'} == 0) {
        return("");
    }

    # if the user has access to everthing
    if($c->check_user_roles('authorized_for_all_hosts') and $c->check_user_roles('authorized_for_all_services')) {
        return("");
    }

    # host authorization
    if($type eq 'hosts') {
        if($c->check_user_roles('authorized_for_all_hosts')) {
            return("");
        }
        return("Filter: contacts >= ".$c->user->get('username'));
    }

    # hostgroups authorization
    elsif($type eq 'hostgroups') {
        return("");
    }

    # service authorization
    elsif($type eq 'services') {
        if($c->check_user_roles('authorized_for_all_services')) {
            return("");
        }
        return("Filter: contacts >= ".$c->user->get('username')."\nFilter: host_contacts >= ".$c->user->get('username')."\nOr: 2");
    }

    # servicegroups authorization
    elsif($type eq 'servicegroups') {
        return("");
    }

    # servicegroups authorization
    elsif($type eq 'timeperiods') {
        return("");
    }

    # comments / downtimes authorization
    elsif($type eq 'comments' or $type eq 'downtimes') {
        my @filter;
        if(!$c->check_user_roles('authorized_for_all_services')) {
            push @filter, "Filter: service_contacts >= ".$c->user->get('username')."\n";
        }
        if(!$c->check_user_roles('authorized_for_all_hosts')) {
            push @filter, "Filter: host_contacts >= ".$c->user->get('username')."\n";
        }
        if(scalar @filter == 0) {
            return("");
        }
        if(scalar @filter == 1) {
            return($filter[0]);
        }
        return(join("\n", @filter)."\nOr: ".scalar @filter);
    }

    # logfile authorization
    elsif($type eq 'log') {
        my @filter;
        if(!$c->check_user_roles('authorized_for_all_services')) {
            push @filter, "Filter: current_service_contacts >= ".$c->user->get('username')."\n";
        }
        if(!$c->check_user_roles('authorized_for_all_hosts')) {
            push @filter, "Filter: current_host_contacts >= ".$c->user->get('username')."\n";
        }
        if(scalar @filter == 0) {
            return("");
        }
        if(scalar @filter == 1) {
            return($filter[0]);
        }
        return(join("\n", @filter)."\nOr: ".scalar @filter);
    }

    else {
        croak("type $type not supported");
    }

    croak("cannot authorize query");
    return;
}


##############################################

=head2 filter_duration

  my $string = filter_duration($seconds);

formats a duration into the
format: 0d 0h 29m 43s

=cut
sub filter_duration {
    my $duration = shift;
    my $withdays = shift;

    croak("undef duration in filter_duration(): ".$duration) unless defined $duration;
    $duration = $duration * -1 if $duration < 0;

    $withdays = 1 unless defined $withdays;

    croak("unknown withdays in filter_duration(): ".$withdays) if($withdays != 0 and $withdays != 1 and $withdays != 2);

    if($duration < 0) { $duration = time() + $duration; }

    my $days    = 0;
    my $hours   = 0;
    my $minutes = 0;
    my $seconds = 0;
    if($withdays == 1) {
        if($duration >= 86400) {
            $days     = int($duration/86400);
            $duration = $duration%86400;
        }
    }
    if($duration >= 3600) {
        $hours    = int($duration/3600);
        $duration = $duration%3600;
    }
    if($duration >= 60) {
        $minutes  = int($duration/60);
        $duration = $duration%60;
    }
    $seconds = $duration;

    if($withdays == 1) {
        return($days."d ".$hours."h ".$minutes."m ".$seconds."s");
    }
    if($withdays == 2) {
        return($minutes."min ".$seconds."sec");
    }
    return($hours."h ".$minutes."m ".$seconds."s");
}


######################################

=head2 get_cgi_cfg

  my $conf = get_cgi_cfg($c);

parse and return the cgi.cg as hash ref

=cut
sub get_cgi_cfg {
    my $c = shift;

    $c->stats->profile(begin => "Utils::get_cgi_cfg()");

    # read only once per request
    our(%config, $cgi_config_already_read);

    return(\%config) if $cgi_config_already_read;

    my $file = Thruk->config->{'cgi_cfg'};

    if(!defined $file or $file eq '') {
        Thruk->config->{'cgi_cfg'} = 'undef';
        $c->log->error("cgi.cfg not set");
        $c->error("cgi.cfg not set");
        $c->detach('/error/index/4');
    }
    if(! -r $file) {
        $c->log->error("cgi.cfg not readable: ".$!);
        $c->error("cgi.cfg not readable: ".$!);
        $c->detach('/error/index/4');
    }

    $cgi_config_already_read = 1;
    my $conf = new Config::General($file);
    %config  = $conf->getall;

    $c->stats->profile(end => "Utils::get_cgi_cfg()");

    return(\%config);
}


######################################

=head2 get_livestatus

  my $conf = get_livestatus($c)

return the livestatus object

=cut
sub get_livestatus {
    my $c = shift;

    $c->stats->profile(begin => "Utils::get_livestatus()");

    our $livestatus;

    if(defined $livestatus) {
        $c->log->debug("got livestatus from cache");
        return($livestatus);
    }
    $c->log->debug("creating new livestatus");

    my $livestatus_config = Thruk::Utils::get_livestatus_conf($c);
    if(!defined $livestatus_config or !defined $livestatus_config->{'peer'} ) {
        $c->detach("/error/index/14");
    }

    if(defined $livestatus_config->{'verbose'} and $livestatus_config->{'verbose'}) {
        $livestatus_config->{'logger'} = $c->log
    }
    $livestatus = Monitoring::Livestatus::MULTI->new(%{$livestatus_config});

    $c->stats->profile(end => "Utils::get_livestatus()");

    return($livestatus);
}


########################################

=head2 sort

  sort($c, $data, \@keys, $order)

sort a array of hashes by hash keys

=cut
sub sort {
    my $c = shift;
    my $data  = shift;
    my $key   = shift;
    my $order = shift;
    my @sorted;

    if(!defined $key) { $c->error('missing options in sort()'); }

    $c->stats->profile(begin => "Utils::sort()") if defined $c;

    $order = "ASC" if !defined $order;

    return if !defined $data;
    return if scalar @{$data} == 0;

    my @keys;
    if(ref($key) eq 'ARRAY') {
        @keys = @{$key};
    } else {
        @keys = ($key);
    }

    my @compares;
    for my $key (@keys) {
        # sort numeric
        if(defined $data->[0]->{$key} and $data->[0]->{$key} =~ m/^\d+$/xm) {
            push @compares, '$a->{'.$key.'} <=> $b->{'.$key.'}';
        }
        # sort alphanumeric
        else {
            push @compares, '$a->{'.$key.'} cmp $b->{'.$key.'}';
        }
    }
    my $sortstring = join(' || ', @compares);
    $c->log->debug("ordering by: ".$sortstring) if defined $c;

    if(uc $order eq 'ASC') {
        eval '@sorted = sort { '.$sortstring.' } @{$data};';
    } else {
        eval '@sorted = reverse sort { '.$sortstring.' } @{$data};';
    }

    $c->stats->profile(end => "Utils::sort()") if defined $c;

    return(\@sorted);
}


########################################

=head2 remove_duplicates

  remove_duplicates($c, $data)

removes duplicate entries from a array of hashes

=cut
sub remove_duplicates {
    my $c    = shift;
    my $data = shift;

    # only needed when using multiple backends
    return $data unless scalar @{$c->stash->{'backends'}} > 1;

    $c->stats->profile(begin => "Utils::remove_duplicates()");

    # calculate md5 sums
    my $uniq = {};
    for my $dat (@{$data}) {
        my $peer_key  = $dat->{'peer_key'};  delete $dat->{'peer_key'};
        my $peer_name = $dat->{'peer_name'}; delete $dat->{'peer_name'};
        my $peer_addr = $dat->{'peer_addr'}; delete $dat->{'peer_addr'};
        my $md5 = md5_hex(join(';', values %{$dat}));
        if(!defined $uniq->{$md5}) {
            $dat->{'peer_key'}  = $peer_key;
            $dat->{'peer_name'} = $peer_name;
            $dat->{'peer_addr'} = $peer_addr;

            $uniq->{$md5} = {
                              'data'      => $dat,
                              'peer_key'  => [ $peer_key ],
                              'peer_name' => [ $peer_name ],
                              'peer_addr' => [ $peer_addr ],
                            };
        } else {
            push @{$uniq->{$md5}->{'peer_key'}},  $peer_key;
            push @{$uniq->{$md5}->{'peer_name'}}, $peer_name;
            push @{$uniq->{$md5}->{'peer_addr'}}, $peer_addr;
        }
    }

    my $return = [];
    for my $data (values %{$uniq}) {
        $data->{'data'}->{'backend'} = {
            'peer_key'  => $data->{'peer_key'},
            'peer_name' => $data->{'peer_name'},
            'peer_addr' => $data->{'peer_addr'},
        };
        push @{$return}, $data->{'data'};

    }

    $c->stats->profile(end => "Utils::remove_duplicates()");
    return($return);
}


########################################

=head2 get_livestatus_conf

  get_livestatus_conf($c)

returns config for livestatus backends

=cut
sub get_livestatus_conf {
    my $c = shift;

    my $livestatus_config = Thruk->config->{'Monitoring::Livestatus'};

    if(defined $livestatus_config) {
        # with only on peer, we have to convert to an array
        if(defined $livestatus_config->{'peer'} and ref $livestatus_config->{'peer'} eq 'HASH') {
            my $peer = $livestatus_config->{'peer'};
            delete $livestatus_config->{'peer'};
            push @{$livestatus_config->{'peer'}}, $peer;
        }
    }

    $c->log->debug("livestatus config: ".Dumper($livestatus_config));

    return($livestatus_config);
}


############################################################

=head2 get_service_exectution_stats_old

  my $stats = get_service_exectution_stats_old($c);

Returns a hash with statistical data, calculation is obsolete
with newer livestatus versions

=cut
sub get_service_exectution_stats_old {
    my $c = shift;

    $c->stats->profile(begin => "Utils::get_service_exectution_stats_old()");

    my $now    = time();
    my $min1   = $now - 60;
    my $min5   = $now - 300;
    my $min15  = $now - 900;
    my $min60  = $now - 3600;

    my $check_stats;
    for my $type (qw{hosts services}) {
        $check_stats->{$type} = {
            'active_sum'                => 0,
            'active_1_min'              => 0,
            'active_5_min'              => 0,
            'active_15_min'             => 0,
            'active_60_min'             => 0,
            'active_all_min'            => 0,

            'active_1_min_perc'         => 0,
            'active_5_min_perc'         => 0,
            'active_15_min_perc'        => 0,
            'active_60_min_perc'        => 0,
            'active_all_min_perc'       => 0,

            'execution_time_min'        => undef,
            'execution_time_max'        => undef,
            'execution_time_avg'        => 0,
            'execution_time_sum'        => 0,

            'latency_min'               => undef,
            'latency_max'               => undef,
            'latency_avg'               => 0,
            'latency_sum'               => 0,

            'active_state_change_min'   => undef,
            'active_state_change_max'   => undef,
            'active_state_change_avg'   => 0,
            'active_state_change_sum'   => 0,

            'passive_sum'               => 0,
            'passive_1_min'             => 0,
            'passive_5_min'             => 0,
            'passive_15_min'            => 0,
            'passive_60_min'            => 0,
            'passive_all_min'           => 0,

            'passive_1_min_perc'        => 0,
            'passive_5_min_perc'        => 0,
            'passive_15_min_perc'       => 0,
            'passive_60_min_perc'       => 0,
            'passive_all_min_perc'      => 0,

            'passive_state_change_min'  => undef,
            'passive_state_change_max'  => undef,
            'passive_state_change_avg'  => 0,
            'passive_state_change_sum'  => 0,
        };

        for my $data (@{$c->{'live'}->selectall_arrayref("GET $type\n".Thruk::Utils::get_auth_filter($c, $type)."\nColumns: execution_time has_been_checked last_check latency percent_state_change check_type", { Slice => 1, AddPeer => 1 })}) {
            my $minall = $c->stash->{'pi_detail'}->{$data->{'peer_key'}}->{'program_start'};

            if($data->{'check_type'} == 0) {
                $check_stats->{$type}->{'active_sum'}++;
            } else {
                $check_stats->{$type}->{'passive_sum'}++;
            }

            if($data->{'has_been_checked'}) {

                # active checks
                if($data->{'check_type'} == 0) {
                    if($data->{'last_check'} >= $min1)   { $check_stats->{$type}->{'active_1_min'}++;   }
                    if($data->{'last_check'} >= $min5)   { $check_stats->{$type}->{'active_5_min'}++;   }
                    if($data->{'last_check'} >= $min15)  { $check_stats->{$type}->{'active_15_min'}++;  }
                    if($data->{'last_check'} >= $min60)  { $check_stats->{$type}->{'active_60_min'}++;  }
                    if($data->{'last_check'} >= $minall) { $check_stats->{$type}->{'active_all_min'}++; }

                    # sum up all values to calculate averages later
                    $check_stats->{$type}->{'execution_time_sum'}       += $data->{'execution_time'};
                    $check_stats->{$type}->{'latency_sum'}              += $data->{'latency'};
                    $check_stats->{$type}->{'active_state_change_sum'}  += $data->{'percent_state_change'};

                    # check min/max values
                    if(!defined $check_stats->{$type}->{'execution_time_min'} or $check_stats->{$type}->{'execution_time_min'} > $data->{'execution_time'}) {
                        $check_stats->{$type}->{'execution_time_min'} = $data->{'execution_time'};
                    }
                    if(!defined $check_stats->{$type}->{'execution_time_max'} or $check_stats->{$type}->{'execution_time_max'} < $data->{'execution_time'}) {
                        $check_stats->{$type}->{'execution_time_max'} = $data->{'execution_time'};
                    }

                    if(!defined $check_stats->{$type}->{'latency_min'} or $check_stats->{$type}->{'latency_min'} > $data->{'latency'}) {
                        $check_stats->{$type}->{'latency_min'} = $data->{'latency'};
                    }
                    if(!defined $check_stats->{$type}->{'latency_max'} or $check_stats->{$type}->{'latency_max'} < $data->{'latency'}) {
                        $check_stats->{$type}->{'latency_max'} = $data->{'latency'};
                    }

                    if(!defined $check_stats->{$type}->{'active_state_change_min'} or $check_stats->{$type}->{'active_state_change_min'} > $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_min'} = $data->{'percent_state_change'};
                    }
                    if(!defined $check_stats->{$type}->{'active_state_change_max'} or $check_stats->{$type}->{'active_state_change_max'} < $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_max'} = $data->{'percent_state_change'};
                    }
                }
                # passive checks
                else {
                    $check_stats->{$type}->{'passive_sum'}++;
                    if($data->{'last_check'} >= $min1)   { $check_stats->{$type}->{'passive_1_min'}++;   }
                    if($data->{'last_check'} >= $min5)   { $check_stats->{$type}->{'passive_5_min'}++;   }
                    if($data->{'last_check'} >= $min15)  { $check_stats->{$type}->{'passive_15_min'}++;  }
                    if($data->{'last_check'} >= $min60)  { $check_stats->{$type}->{'passive_60_min'}++;  }
                    if($data->{'last_check'} >= $minall) { $check_stats->{$type}->{'passive_all_min'}++; }

                    # sum up all values to calculate averages later
                    $check_stats->{$type}->{'passive_state_change_sum'} += $data->{'percent_state_change'};

                    # check min/max values
                    if(!defined $check_stats->{$type}->{'passive_state_change_min'} or $check_stats->{$type}->{'passive_state_change_min'} > $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'active_state_change_min'} = $data->{'percent_state_change'};
                    }
                    if(!defined $check_stats->{$type}->{'passive_state_change_max'} or $check_stats->{$type}->{'passive_state_change_max'} < $data->{'percent_state_change'}) {
                        $check_stats->{$type}->{'passive_state_change_max'} = $data->{'percent_state_change'};
                    }
                }
            }
        }

        # calculate averages
        if($check_stats->{$type}->{'active_sum'} > 0) {
            $check_stats->{$type}->{'execution_time_avg'}       = $check_stats->{$type}->{'execution_time_sum'}       / $check_stats->{$type}->{'active_sum'};
            $check_stats->{$type}->{'latency_avg'}              = $check_stats->{$type}->{'latency_sum'}              / $check_stats->{$type}->{'active_sum'};
            $check_stats->{$type}->{'active_state_change_avg'}  = $check_stats->{$type}->{'active_state_change_sum'}  / $check_stats->{$type}->{'active_sum'};
        } else {
            $check_stats->{$type}->{'execution_time_avg'}       = 0;
            $check_stats->{$type}->{'latency_avg'}              = 0;
            $check_stats->{$type}->{'active_state_change_avg'}  = 0;
        }
        if($check_stats->{$type}->{'passive_sum'} > 0) {
            $check_stats->{$type}->{'passive_state_change_avg'} = $check_stats->{$type}->{'passive_state_change_sum'} / $check_stats->{$type}->{'passive_sum'};
        } else {
            $check_stats->{$type}->{'passive_state_change_avg'} = 0;
        }

        # calculate percentages
        if($check_stats->{$type}->{'active_sum'} > 0) {
            $check_stats->{$type}->{'active_1_min_perc'}   = $check_stats->{$type}->{'active_1_min'}   / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_5_min_perc'}   = $check_stats->{$type}->{'active_5_min'}   / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_15_min_perc'}  = $check_stats->{$type}->{'active_15_min'}  / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_60_min_perc'}  = $check_stats->{$type}->{'active_60_min'}  / $check_stats->{$type}->{'active_sum'} * 100;
            $check_stats->{$type}->{'active_all_min_perc'} = $check_stats->{$type}->{'active_all_min'} / $check_stats->{$type}->{'active_sum'} * 100;
        }

        if($check_stats->{$type}->{'passive_sum'} > 0) {
            $check_stats->{$type}->{'passive_1_min_perc'}   = $check_stats->{$type}->{'passive_1_min'}   / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_5_min_perc'}   = $check_stats->{$type}->{'passive_5_min'}   / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_15_min_perc'}  = $check_stats->{$type}->{'passive_15_min'}  / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_60_min_perc'}  = $check_stats->{$type}->{'passive_60_min'}  / $check_stats->{$type}->{'passive_sum'} * 100;
            $check_stats->{$type}->{'passive_all_min_perc'} = $check_stats->{$type}->{'passive_all_min'} / $check_stats->{$type}->{'passive_sum'} * 100;
        }

        # set possible undefs to zero if still undef
        for my $key (qw{execution_time_min execution_time_max latency_min latency_max active_state_change_min
                          active_state_change_max passive_state_change_min passive_state_change_max}) {
            $check_stats->{$type}->{$key} = 0 unless defined $check_stats->{$type}->{$key};
        }
    }

    $c->stats->profile(end => "Utils::get_service_exectution_stats_old()");

    return($check_stats);
}


############################################################

=head2 get_service_exectution_stats

  my $stats = get_service_exectution_stats($c);

Returns a hash with statistical data

=cut
sub get_service_exectution_stats {
    my $c = shift;

    $c->stats->profile(begin => "Utils::get_service_exectution_stats()");

    my $now    = time();
    my $min1   = $now - 60;
    my $min5   = $now - 300;
    my $min15  = $now - 900;
    my $min60  = $now - 3600;

    my $check_stats;
    for my $type (qw{hosts services}) {
        $check_stats->{$type} = {
            'execution_time_min'        => undef,
            'execution_time_max'        => undef,
            'execution_time_avg'        => 0,
            'execution_time_sum'        => 0,

            'latency_min'               => undef,
            'latency_max'               => undef,
            'latency_avg'               => 0,
            'latency_sum'               => 0,
        };

        my $query = "GET $type\n".Thruk::Utils::get_auth_filter($c, $type)."\n";
        $query .= "Filter: has_been_checked = 1\n";
        $query .= "Filter: check_type = 0\n";
        $query .= "Stats: sum has_been_checked as has_been_checked\n";
        $query .= "Stats: sum latency as latency_sum\n";
        $query .= "Stats: sum execution_time as execution_time_sum\n";
        $query .= "Stats: min latency as latency_min\n";
        $query .= "Stats: min execution_time as execution_time_min\n";
        $query .= "Stats: max latency as latency_max\n";
        $query .= "Stats: max execution_time as execution_time_max\n";

        my $data = $c->{'live'}->selectall_arrayref($query, { Slice => 1, AddPeer => 1});
        for my $backend_result (@{$data}) {
            $check_stats->{$type}->{'has_been_checked'}   += $backend_result->{'has_been_checked'};
            $check_stats->{$type}->{'execution_time_sum'} += $backend_result->{'execution_time_sum'};
            $check_stats->{$type}->{'latency_sum'}        += $backend_result->{'latency_sum'};
            if(!defined $check_stats->{$type}->{'execution_time_min'} or $check_stats->{$type}->{'execution_time_min'} > $backend_result->{'execution_time_min'}) { $check_stats->{$type}->{'execution_time_min'} = $backend_result->{'execution_time_min'}; }
            if(!defined $check_stats->{$type}->{'latency_min'} or $check_stats->{$type}->{'latency_min'} > $backend_result->{'latency_min'}) { $check_stats->{$type}->{'latency_min'} = $backend_result->{'latency_min'}; }
            if(!defined $check_stats->{$type}->{'latency_max'} or $check_stats->{$type}->{'execution_time_max'} < $backend_result->{'execution_time_max'}) { $check_stats->{$type}->{'execution_time_max'} = $backend_result->{'execution_time_max'}; }
            if(!defined $check_stats->{$type}->{'latency_max'} or $check_stats->{$type}->{'latency_max'} < $backend_result->{'latency_max'}) { $check_stats->{$type}->{'latency_max'} = $backend_result->{'latency_max'}; }
        }
        #$c->log->error(Dumper($data));

        if($check_stats->{$type}->{'has_been_checked'} > 0) {
            $check_stats->{$type}->{'execution_time_avg'} = $check_stats->{$type}->{'execution_time_sum'} / $check_stats->{$type}->{'has_been_checked'};
            $check_stats->{$type}->{'latency_avg'}        = $check_stats->{$type}->{'latency_sum'}        / $check_stats->{$type}->{'has_been_checked'};
        }

        # set possible undefs to zero if still undef
        for my $key (qw{execution_time_min execution_time_max latency_min latency_max }) {
            $check_stats->{$type}->{$key} = 0 unless defined $check_stats->{$type}->{$key};
        }
    }

    $c->stats->profile(end => "Utils::get_service_exectution_stats()");

    return($check_stats);
}


########################################

=head2 get_hostcomments

  my $comments = get_hostcomments($c, $filter)

return all host comments for a given filter

=cut
sub get_hostcomments {
    my $c      = shift;
    my $filter = shift;

    $c->stats->profile(begin => "Utils::get_hostcomments()");

    $filter = '' unless defined $filter;
    my $hostcomments;
    my $comments    = $c->{'live'}->selectall_arrayref("GET comments\n".Thruk::Utils::get_auth_filter($c, 'comments')."\n$filter\nFilter: service_description =\nColumns: host_name id", { Slice => 1 });

    for my $comment (@{$comments}) {
        $hostcomments->{$comment->{'host_name'}}->{$comment->{'id'}} = $comment;
    }

    $c->stats->profile(end => "Utils::get_hostcomments()");

    return $hostcomments;
}


########################################

=head2 get_servicecomments

  my $comments = get_servicecomments($c, $filter);

returns all comments for a given filter

=cut
sub get_servicecomments {
    my $c      = shift;
    my $filter = shift;

    $c->stats->profile(begin => "Utils::get_servicecomments()");

    my $servicecomments;
    my $comments = $c->{'live'}->selectall_arrayref("GET comments\n".Thruk::Utils::get_auth_filter($c, 'comments')."\n$filter\nFilter: service_description !=\nColumns: host_name service_description id", { Slice => 1 });

    for my $comment (@{$comments}) {
        $servicecomments->{$comment->{'host_name'}}->{$comment->{'service_description'}}->{$comment->{'id'}} = $comment;
    }

    $c->stats->profile(end => "Utils::get_servicecomments()");

    return $servicecomments;
}


########################################

=head2 calculate_overall_processinfo

  my $process_info = calculate_overall_processinfo($process_info)

computes a combined status for process infos

=cut
sub calculate_overall_processinfo {
    my $pi = shift;
    my $return;
    for my $peer (keys %{$pi}) {
        for my $key (keys %{$pi->{$peer}}) {
            my $value = $pi->{$peer}->{$key};
            if($value eq "0" or $value eq "1") {
                if(!defined $return->{$key}) {
                    $return->{$key} = $value;
                }elsif($return->{$key} == -1) {
                    # do nothing, result already varies
                }elsif($return->{$key} == $value) {
                    # do nothing, result is the same
                }elsif($return->{$key} != $value) {
                    # set result to vary
                    $return->{$key} = -1;
                }
            }
        }
    }
    return($return);
}


########################################

=head2 get_start_end_for_timeperiod

  my($start, $end) = get_start_end_for_timeperiod($timeperiod,
                                                  $smon,
                                                  $sday,
                                                  $syear,
                                                  $shour,
                                                  $smin,
                                                  $ssec,
                                                  $emon,
                                                  $eday,
                                                  $eyear,
                                                  $ehour,
                                                  $emin,
                                                  $esec,
                                                  $t1,
                                                  $t2);

returns a start and end timestamp for a report date definition

=cut
sub get_start_end_for_timeperiod {
    my($timeperiod,$smon,$sday,$syear,$shour,$smin,$ssec,$emon,$eday,$eyear,$ehour,$emin,$esec,$t1,$t2) = @_;

    my $start;
    my $end;
    $timeperiod = 'custom' unless defined $timeperiod;
    if($timeperiod eq 'today') {
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $start = Mktime($year,$month,$day,  0,0,0);
        $end   = time();
    }
    elsif($timeperiod eq 'last24hours') {
        $end   = time();
        $start = $end - 86400;
    }
    elsif($timeperiod eq 'yesterday') {
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $start = Mktime($year,$month,$day,  0,0,0) - 86400;
        $end   = $start + 86400;
    }
    elsif($timeperiod eq 'thisweek') {
        # start on last sunday 0:00 till now
        my @today  = Today();
        my @monday = Monday_of_Week(Week_of_Year(@today));
        $start     = Mktime(@monday,  0,0,0) - 86400;
        $end       = time();
    }
    elsif($timeperiod eq 'last7days') {
        $end   = time();
        $start = $end - 7 * 86400;
    }
    elsif($timeperiod eq 'lastweek') {
        # start on last weeks sunday 0:00 till last weeks saturday 24:00
        my @today  = Today();
        my @monday = Monday_of_Week(Week_of_Year(@today));
        $end       = Mktime(@monday,  0,0,0) - 86400;
        $start     = $end - 7*86400;
    }
    elsif($timeperiod eq 'thismonth') {
        # start on first till now
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $start = Mktime($year,$month,1,  0,0,0);
        $end   = time();
    }
    elsif($timeperiod eq 'last31days') {
        $end   = time();
        $start = $end - 31 * 86400;
    }
    elsif($timeperiod eq 'lastmonth') {
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $end   = Mktime($year,$month,1,  0,0,0);
        my $lastmonth = $month - 1;
        if($lastmonth <= 0) { $lastmonth = $lastmonth + 12; $year--;}
        $start = Mktime($year,$lastmonth,1,  0,0,0);
    }
    elsif($timeperiod eq 'thisyear') {
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $start = Mktime($year,1,1,  0,0,0);
        $end   = time();
    }
    elsif($timeperiod eq 'lastyear') {
        my($year,$month,$day, $hour,$min,$sec, $doy,$dow,$dst) = Localtime();
        $start = Mktime($year-1,1,1,  0,0,0);
        $end   = Mktime($year,1,1,  0,0,0);
    }
    elsif(defined $t1 and defined $t2) {
        $start = $t1;
        $end   = $t2;
        if(!defined $start) {
            $start = Mktime($syear,$smon,$sday, $shour,$smin,$ssec);
        }
        if(!defined $end) {
            $end   = Mktime($eyear,$emon,$eday, $ehour,$emin,$esec);
        }
    } else {
        return(undef, undef);
    }

    return($start, $end);
}

1;

=head1 AUTHOR

Sven Nierlein, 2009, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut