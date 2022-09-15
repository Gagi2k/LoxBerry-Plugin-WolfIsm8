#!/usr/bin/perl

use CGI;
use LoxBerry::System;
use LoxBerry::Web;
use MIME::Base64;
use Encode qw(decode encode);
  
# cgi
my $cgi = CGI->new;
$cgi->import_names('R');

# version
my $version = LoxBerry::System::pluginversion();

# config
my $cfg = new Config::Simple("$lbpconfigdir/wolf_ism8i.conf");

if (! defined $cfg->param('enable')) {
    $cfg->param('enable', 0)
}
if (! defined $cfg->param('ism8i_port')) {
    $cfg->param('ism8i_port', 12004)
}
if (! defined $cfg->param('input_port')) {
    $cfg->param('input_port', 12005)
}
if (! defined $cfg->param('fw_version')) {
    $cfg->param('fw_version', 1.5)
}
if (! defined $cfg->param('multicast_port')) {
    $cfg->param('multicast_port', 35353)
}
if (! defined $cfg->param('dp_log')) {
    $cfg->param('dp_log', 0)
}

# Template
my $templatefile = "$lbptemplatedir/index.html";
my $template_in = LoxBerry::System::read_file($templatefile);

# Add JS Scripts to template
$templatefile = "$lbptemplatedir/javascript.html";
$template_in .= LoxBerry::System::read_file($templatefile);

# Template
my $template = HTML::Template->new_scalar_ref(
    \$template_in,
    global_vars => 1,
    loop_context_vars => 1,
    die_on_bad_params => 0,
    associate => $cfg,
);

# Language
my %L = LoxBerry::Web::readlanguage($template, "language.ini");

my @datenpunkte;

# Save Form 1
if ($R::saveformdata1) {

        $template->param( FORMNO => '1' );

        %miniservers = LoxBerry::System::get_miniservers();

        # Write configuration file(s)
        $cfg->param("enable", "$R::enable");
        $cfg->param("ism8i_port", "$R::ism8port");
        $cfg->param("input_port", "$R::inport");
        $cfg->param("fw_version", "$R::version");
        $cfg->param("multicast_ip", $miniservers{$R::ms}{IPAddress});
        $cfg->param("multicast_port", "$R::msudpport");
        $cfg->param("dp_log", "$R::dplog");
        if ($R::tcp_udp) {
            $cfg->param("output", "data");
        } else {
            $cfg->param("output", "none");
        }
        $cfg->param("mqtt", "$R::mqtt");
        $cfg->param("pull_on_write", "$R::pull_on_write");

        $cfg->save();

        if ($R::enable) {
            system ("$lbpbindir/wolf_server restart >/dev/null 2>&1");
        } else {
            system ("$lbpbindir/wolf_server stop >/dev/null 2>&1");
        }

        # Template output
        &save;

        exit;
}

#
# Navbar
#

our %navbar;
$navbar{1}{Name} = "$L{'SETTINGS.LABEL_SETTINGS'}";
$navbar{1}{URL} = 'index.cgi?form=1';

$navbar{2}{Name} = "$L{'SETTINGS.LABEL_TEMPLATEBUILDER'}";
$navbar{2}{URL} = 'index.cgi?form=2';

$navbar{3}{Name} = "$L{'SETTINGS.LABEL_LOG'}";
$navbar{3}{URL} = LoxBerry::Web::loglist_url();
$navbar{3}{target} = '_blank';

#
# Menu: Settings
#

if ($R::form eq "1" || !$R::form) {

  $navbar{1}{active} = 1;
  $template->param( "FORM1", 1);

  my @values;
  my %labels;

  # Log all Data
  @values = ('0', '1' );
  %labels = (
        '0' => $L{'SETTINGS.LABEL_OFF'},
        '1' => $L{'SETTINGS.LABEL_ON'},
    );
  my $enable = $cgi->popup_menu(
        -name    => 'enable',
        -id      => 'enable',
        -values  => \@values,
        -labels  => \%labels,
        -default => $cfg->param('enable'),
    );
  $template->param( ENABLE => $enable );

  my $dplog = $cgi->popup_menu(
        -name    => 'dplog',
        -id      => 'dplog',
        -values  => \@values,
        -labels  => \%labels,
        -default => $cfg->param('dp_log'),
    );
  $template->param( DP_LOG => $dplog );

  my $tcp_udp_state = 0;
  if ($cfg->param('output') eq "data") {
      $tcp_udp_state = 1;
  }
  my $tcp_udp = $cgi->popup_menu(
        -name    => 'tcp_udp',
        -id      => 'tcp_udp',
        -values  => \@values,
        -labels  => \%labels,
        -default => $tcp_udp_state,
    );
  $template->param( TCP_UDP => $tcp_udp );

  my $mqtt = $cgi->popup_menu(
        -name    => 'mqtt',
        -id      => 'mqtt',
        -values  => \@values,
        -labels  => \%labels,
        -default => $cfg->param('mqtt'),
    );
  $template->param( MQTT => $mqtt );

  my $pull_on_write = $cgi->popup_menu(
        -name    => 'pull_on_write',
        -id      => 'pull_on_write',
        -values  => \@values,
        -labels  => \%labels,
        -default => $cfg->param('pull_on_write'),
    );
  $template->param( PULL_ON_WRITE => $pull_on_write );

  # Protocol version
  @values = ('1.4', '1.5' );
  %labels = (
        '1.4' => '1.4',
        '1.5' => '1.5',
    );
  my $version = $cgi->popup_menu(
        -name    => 'version',
        -id      => 'version',
        -values  => \@values,
        -labels  => \%labels,
        -default => $cfg->param('fw_version'),
    );
  $template->param( VERSION => $version );

  # Miniservers
  my $msid = LoxBerry::System::get_miniserver_by_ip($cfg->param('multicast_ip'));
  my $mshtml = LoxBerry::Web::mslist_select_html(
          FORMID => 'ms',
          SELECTED => $msid,
          DATA_MINI => 1,
          LABEL => "",
  );
  $template->param('MS', $mshtml);
#
# Menu: Inputs/Outputs
#

} elsif ($R::form eq "2") {

  $navbar{4}{active} = 1;
  $template->param( "FORM2", 1);

  loadDatenpunkte();

  my @data = ();
  my @digitalTypes = ("DPT_Switch","DPT_Bool","DPT_Enable","DPT_OpenClose");
  my $count = scalar(@datenpunkte);

  # Generate a temporary arroy for all virtual inputs
  for ($i = 1; $i < $count; $i++) {
      my %d;
      $d{ID} = sprintf "%03d", $datenpunkte[$i][0];
      $d{NAME} = encode('UTF-8', $datenpunkte[$i][1]." ".$datenpunkte[$i][2]);

      push(@data, \%d);
  }
  my @sorted_data = sort { $a->{NAME} cmp $b->{NAME} } @data;

  my $virtualinput = HTML::Template->new(
          filename => "$lbptemplatedir/virtualinput.xml",
          global_vars => 1,
          loop_context_vars => 1,
          die_on_bad_params => 0,
          associate => $cfg,
  );
  $virtualinput->param("DATA" => \@sorted_data);

  my $vixml = encode_base64($virtualinput->output);
  my $url = "data:application/octet-stream;charset=utf-8;base64,$vixml";
  $template->param('VI_HTTP_URL', $url);


  my @out_data = ();
  # Generate a temporary arroy for all virtual outputs
  for ($i = 1; $i < $count; $i++) {
      my %d;
      if ($datenpunkte[$i][4] =~ m/In/) {
          $d{ID} = $datenpunkte[$i][0];
          $d{NAME} = encode('UTF-8', $datenpunkte[$i][1]." ".$datenpunkte[$i][2]);

          push(@out_data, \%d);
      }
  }
  my @sorted_out_data = sort { $a->{NAME} cmp $b->{NAME} } @out_data;

  my $virtualoutput = HTML::Template->new(
          filename => "$lbptemplatedir/virtualoutput.xml",
          global_vars => 1,
          loop_context_vars => 1,
          die_on_bad_params => 0,
          associate => $cfg,
  );
  $virtualoutput->param("DATA" => \@sorted_out_data);

  my $ip = LoxBerry::System::get_localip();
  my $port = $cfg->param("input_port");
  $virtualoutput->param('ADDRESS', "tcp://$ip:$port");

  my $voxml = encode_base64($virtualoutput->output);
  my $url = "data:application/octet-stream;charset=utf-8;base64,$voxml";
  $template->param('VO_HTTP_URL', $url);
}


# Template
LoxBerry::Web::lbheader($L{'SETTINGS.LABEL_PLUGINTITLE'} . " V$version", "https://www.loxwiki.eu/display/LOXBERRY/Wolf+ISM8", "");
print $template->output();
LoxBerry::Web::lbfooter();

exit;

#####################################################
# Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
# Die Reihenfolge der CSV Spalten lautet: DP ID, Gerät, Datenpunkt KNX-Datenpunkttyp, Output/Input, Einheit
# Die einzelnen CSV Felder dürfen keine Kommas, Leerstellen oder Anführungszeichen enthalten.
#####################################################
sub loadDatenpunkte
{
   #erstmal vorsichtshalber datenpunkte array löschen:
   while(@datenpunkte) { shift(@datenpunkte); }

   my $fw_version = $cfg->param('fw_version');
   $fw_version =~ s/\.//g;
   my $file = $lbpbindir."/wolf_datenpunkte_".$fw_version.".csv";
   my $data;
   open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
   while (my $line = <$data>)
    {
     my @fields = split(/;/, r_trim($line));
         if (scalar(@fields) == 6)
           {
            $datenpunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
                $geraet_max_length = max($geraet_max_length, length($fields[1]));
           }
    }
   close $data;
}

sub r_trim { my $s = shift; $s =~ s/\s+$//; return $s; }
sub max($$) { $_[$_[0] < $_[1]]; }


#####################################################
# Save
#####################################################

sub save
{
        $template->param( "SAVE", 1);
        LoxBerry::Web::lbheader($L{'SETTINGS.LABEL_PLUGINTITLE'} . " V$version", "https://www.loxwiki.eu/display/LOXBERRY/Wolf+ISM8", "help.html");
        print $template->output();
        LoxBerry::Web::lbfooter();

        exit;
}
