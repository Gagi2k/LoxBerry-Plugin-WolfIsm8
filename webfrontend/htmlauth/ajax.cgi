#!/usr/bin/perl
use warnings;
use strict;
use LoxBerry::System;
use LoxBerry::Log;
use CGI;
use JSON;

my $error;
my $response;
my $cgi = CGI->new;
my $q = $cgi->Vars;

my $log = LoxBerry::Log->new (
    name => 'AJAX',
	stderr => 1,
	loglevel => 7
);

#LOGSTART "Request $q->{action}";

if( $q->{action} eq "servicerestart" ) {
        system ("$lbpbindir/wolf_server restart >/dev/null 2>&1");
        $response = $?;
}

if( $q->{action} eq "servicestatus" ) {
        my $status;
        my $count = `pgrep -c -f "wolf_watchdog"`;
        if ($count >= "2") {
                $status = `pgrep -o -f "wolf_watchdog"`;
        }
        my %response = (
                pid => $status,
        );
        chomp (%response);
        $response = encode_json( \%response );
}

#####################################
# Manage Response and error
#####################################

if( defined $response and !defined $error ) {
	print "Status: 200 OK\r\n";
	print "Content-type: application/json; charset=utf-8\r\n\r\n";
	print $response;
        #LOGOK "Parameters ok - responding with HTTP 200";
}
elsif ( defined $error and $error ne "" ) {
	print "Status: 500 Internal Server Error\r\n";
	print "Content-type: application/json; charset=utf-8\r\n\r\n";
	print to_json( { error => $error } );
        #LOGCRIT "$error - responding with HTTP 500";
}
else {
	print "Status: 501 Not implemented\r\n";
	print "Content-type: application/json; charset=utf-8\r\n\r\n";
	$error = "Action ".$q->{action}." unknown";
        #LOGCRIT "Method not implemented - responding with HTTP 501";
        print to_json( { error => $error } );
}

END {
        #LOGEND if($log);
}

