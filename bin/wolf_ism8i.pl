#!/usr/bin/perl

###########################################################################################
###########################################################################################
##  Server Software zum Empangen, Auswerten und Weitergeben von Wolf ISM8i Datenpunkten  ##
##  Copyright (C) 2017 bei Dr Mugur Dietrich                                             ##
##  Frei für den privaten und schulischen Einsatz                                        ##
##  Kommerziellen Einsatz nur nach vorhergehender Genehmigung !                          ##
##  Support Seite: http://tips-und-mehr.de und das FHEM User Forum                       ##
##  Mailadresse: m.i.dietrich@gmx.de                                                     ##
###########################################################################################
###########################################################################################

use List::MoreUtils qw(first_index);
use IO::Select;
use diagnostics;
use LoxBerry::System;
#my $lbpconfigdir = dirname(__FILE__);
#my $lbplogdir = dirname(__FILE__)."/log";

use strict;
use warnings;
use utf8;
use bignum;

use IO::Socket::INET;
use IO::Socket::Multicast; #   apt install libio-socket-multicast-perl
use Data::Dumper qw(Dumper);
use HTML::Entities;
use File::Basename;
use Math::Round qw(nearest); # apt isntall libmath-round-perl

binmode(STDOUT, ":utf8");


## Prototypen definieren: ###################################################
sub start_IGMPserver;
sub send_IGMPmessage($);
sub start_WolfServer;
sub start_CommandServer;
sub start_event_loop($$);
sub read_command_messages($$);
sub read_wolf_messages($);
sub createRequest($$);
sub create_answer($);
sub create_logdir;
sub log_msg_data($$);
sub add_to_log($);
sub getLoggingTime;
sub dec2ip($);
sub ip2dec($);
sub r_trim;
sub l_trim;
sub all_trim;
sub dbl_trim;
sub l_r_dbl_trim;
sub max($$);
sub min($$);
sub getFhemFriendly($);
sub decodeTelegram($);
sub loadConfig;
sub loadDatenpunkte;
sub showDatenpunkte;
sub writeDatenpunkteToLog;
sub getDatenpunkt($$);
sub getCsvResult($$);
sub parseInput($);
sub pdt_knx_float($);
sub pdt_long($);
sub pdt_time($);
sub pdt_date($);


## Globale Variablen: #######################################################

my $script_path = dirname(__FILE__);
my $verbose = 3; # 0 = nichts, 1 = Telegrammauswertung, 3 = alles
my $fw_actualize = time - 1;
my $geraet_max_length = 0;
my @datenpunkte;
my $last_auswertung = "";
my $igmp_sock;
my %hash = (
             ism8i_ip => '?.?.?.?' ,
             port     => '12004' ,
             fw       => '1.5' ,
             mcip     => '239.7.7.77' ,
             mcport   => '35353' ,
             dplog    => '0' ,
             output   => 'fhem' ,
			);

			
## Ablauf starten ###########################################################
			
# Original Einstellungen sichern
*OLD_STDOUT = *STDOUT;
*OLD_STDERR = *STDERR;

# Umleiten von STDOUT, STDERR
create_logdir(); # Ordner 'log' erzeugen wenn nicht vorhanden.
open(my $log_fh, '>>', $lbplogdir."/wolf_ism8i.log") or die "Could not open/write file 'wolf_ism8i.log' $!";
*STDOUT = $log_fh;
*STDERR = $log_fh;

add_to_log("");
add_to_log("############ Strate Wolf ISM8i Auswertungs-Modul ############");

#Subs aufrufen:
loadConfig();

loadDatenpunkte();

writeDatenpunkteToLog();

#showDatenpunkte();

start_IGMPserver();

start_event_loop(start_WolfServer(), start_CommandServer());

# STDOUT/STDERR wiederherstellen
close $log_fh;
*STDOUT = *OLD_STDOUT;
*STDERR = *OLD_STDERR;


## Sub Definitionen #########################################################

sub start_IGMPserver
# Startet einen Multicast Server
{
   add_to_log("Creating multicast group server $hash{mcip}:$hash{mcport}:");

   $igmp_sock = IO::Socket::Multicast->new(
           Proto     => 'udp',
		   PeerAddr  => "$hash{mcip}:$hash{mcport}",
           ReusePort => '1',
   ) or die "ERROR: Cant create socket: $@! ";

   # ACHTUNG: kein $igmp_sock->mcast_add() bei Server!
   
   add_to_log("   Creating to multicast group success.");
}


sub send_IGMPmessage($)
{
   my $message = shift;
   my $ok = $igmp_sock->send($message) or die "Couldn't send to multicast group: $!";
   if ($ok == 0) { print $ok."\n"; }
}

#
# ID, value
sub createRequest($$)
{
    my $dp_id = $_[0];
    my $dp_state = "00";

    my $dp_value = $_[1];
    my $dp_length = length($dp_value);

    # Building the msg from behind
    my @obj_header = ("F0","C1");
    my $obj_frame = pack("H2 H2 n n n C C ", @obj_header, $dp_id, 1, $dp_id, 0 , $dp_length);

    my @conn_header = ("04","00","00","00");
    my $conn_frame = pack("H2" x 4, @conn_header);

    my @knx_header = ("06","20","F0","80");
    my $knx_frame = pack("H2" x 4 ."n", @knx_header, 6 + 4 + length($obj_frame) + $dp_length);

    my $request = $knx_frame.$conn_frame.$obj_frame.$dp_value;

    if ($verbose == 3) { add_to_log("Sende Daten (".length($request)." Bytes):"); }
    if ($verbose == 3) { add_to_log(join(" ", unpack("H2" x length($request), $request))); }

    return $request;
}

sub createPullRequest()
{
    my @a = ("06","20","F0","80","00","16","04","00","00","00","F0","D0");
    if ($verbose == 3) { add_to_log("Pull Request: ".join(" ", @a)); }
    return pack("H2" x 17, @a);
}

sub start_CommandServer()
#Startet einen blocking Server(Loop) an dem sich das Wolf ISM8i Modul verbinden und seine Daten schicken kann.
{
   # auto-flush on socket
   $| = 1;

   # creating a listening socket
   my $socket = new IO::Socket::INET (
      LocalHost => '0.0.0.0',
      LocalPort => 9999,
      Proto => 'tcp',
      Listen => 5,
      Reuse => 1
   );
   die "Cannot create socket $!\n" unless $socket;
   add_to_log("Server wartet auf Loxone Verbindung auf Port $hash{port}:");

   return $socket;
}

sub start_WolfServer()
#Startet einen blocking Server(Loop) an dem sich das Wolf ISM8i Modul verbinden und seine Daten schicken kann. 
{
   # auto-flush on socket
   $| = 1;
 
   # creating a listening socket
   my $socket = new IO::Socket::INET (
      LocalHost => '0.0.0.0',
      LocalPort => $hash{port},
      Proto => 'tcp',
      Listen => 5,
      Reuse => 1
   );
   die "Cannot create socket $!\n" unless $socket;
   add_to_log("Server wartet auf ISM8i Verbindung auf Port $hash{port}:");

   return $socket;
}

sub start_event_loop($$) {
    my $wolf_socket = $_[0];
    my $command_socket = $_[1];
    my $wolf_client;
    my $command_client;

    my $read_select  = IO::Select->new();

    $read_select->add($wolf_socket);
    $read_select->add($command_socket);

    while (1) {

        ## No timeout specified (see docs for IO::Select).  This will block until a TCP
        ## client connects or we have data.
        my @read = $read_select->can_read();

        foreach my $read (@read) {
            if ($read == $wolf_socket) {
                if (!$wolf_client) {
                    # waiting for a new client connection
                    $wolf_client = $wolf_socket->accept();

                    # get information about a newly connected client
                    my $client_address = $wolf_client->peerhost();
                    $hash{ism8i_ip} = $wolf_client;
                    my $client_port = $wolf_client->peerport();
                    add_to_log("   Verbindung eines ISM8i Moduls von $client_address:$client_port");

                    #   add_to_log("Sende Pull Request zum ISM8i Modul: $client_address");
                    #   my $pull_request = createPullRequest();
                    #   if (length($pull_request) > 0) { $client_socket->send($pull_request); }
                }
                $read_select->add($wolf_client);

                read_wolf_messages($wolf_client);
            }

            if ($read == $wolf_client) {
                read_wolf_messages($wolf_client);
            }

            if ($read == $command_socket) {
                if (!$command_client) {
                    # waiting for a new client connection
                    $command_client = $command_socket->accept();

                    # get information about a newly connected client
                    my $client_address = $command_client->peerhost();
                    my $client_port = $command_client->peerport();
                    add_to_log("   Verbindung eines Clients von $client_address:$client_port");
                }

                read_command_messages($command_client, $wolf_client);

                # Close the client connection after every command. The commands are short enough
                # to be read in one go.
                shutdown($command_client, 1);
                $command_client = undef;
            }
        }
    }

    if ($wolf_client) {
        # notify client that response has been sent
        shutdown($wolf_client, 1);

        $wolf_socket->close();
    }
}

sub read_command_messages($$) {
   my $client_socket = $_[0];
   my $ism8_socket = $_[1];

   # read up to 4096 characters from the connected client
   my $rec_data = "";
   $client_socket->recv($rec_data, 4096);

   if (!$ism8_socket) {
        add_to_log("No ISM8 connection, ignoring command!");
        return;
   }

   add_to_log("Read command $rec_data");
   my $send_data = parseInput($rec_data);
   $ism8_socket->send($send_data);
}
 
sub read_wolf_messages($) {
   my $client_socket = $_[0];
 
   # read up to 4096 characters from the connected client
   my $rec_data = "";
   $client_socket->recv($rec_data, 4096);

   if ($verbose == 3) { add_to_log("Daten Empfang (".length($rec_data)." Bytes):"); }
   if ($verbose == 3) { add_to_log(join(" ", unpack("H2" x length($rec_data), $rec_data))); }

   my $starter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
   my @fields = split(/$starter/, $rec_data);
   foreach my $r (@fields)
      {
       if (length($r) > 0)
         {
          $r = $starter.$r;

          # Falls ein SetDatapointValue.Req gesendet wurde wird mit einem SetDatapointValue.Res als Bestätigung geantwortet.
          my $send_data = create_answer($r);
          if (length($send_data) > 0) { $client_socket->send($send_data); }

            decodeTelegram($r);
          }
      }
}


sub create_answer($)
#Erzeugt ein SetDatapointValue.Res Telegramm das an das ISM8i zurückgeschickt wird.
{
   my @h = unpack("H2" x length($_[0]), $_[0]);
   
   if (length($_[0]) < 14)
      {
	   return "";
	  }
   elsif ($h[10] eq "f0" and $h[11] eq "06")
      {
       my @a = ($h[0],$h[1],$h[2],$h[3],"00","11",$h[6],$h[7],$h[8],$h[9],$h[10],"86",$h[12],$h[13],"00","00","00");
       if ($verbose == 3) { add_to_log("Antwort: ".join(" ", @a)); }
       return pack("H2" x 17, @a);
	  }
   else
      {
	   return "";
	  }
}


sub create_logdir
# Erstellt den Ordner für Logs.
{
   my $log_ordner = $lbplogdir;
   if (not (-e "$log_ordner")) {
      my $ok = mkdir("$log_ordner",0755);
      if ($ok == 0) { die "Could not create dictionary '$log_ordner' $!"; }
   }
}


sub log_msg_data($$)
# Loggt die als Multicast versendeten Daten in ein Logfile.
{
   my ($msg,$format) = @_;
   my $filename = $lbplogdir."/wolf_data.log";
   open(my $fh, '>>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   
   if ($format eq 'fhem') {
      print $fh getLoggingTime()." $msg\n";
   } elsif ($format eq 'csv') {
      print $fh getLoggingTime().";$msg\n";
   } elsif ($format eq 'data') {
      print $fh getLoggingTime().";$msg\n";
   }
   
   close $fh;
}


sub add_to_log($)
#fügt einen Eintrag zur Logdatei hinzu
{
   my $msg = shift;
   my $filename = $lbplogdir."/wolf_ism8i.log";
   open(my $fh, '>>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   print $fh getLoggingTime()." $msg\n";
   close $fh;
}


sub getLoggingTime
#Returnt eine gut lesbare Zeit für Logeinträge.
{
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    my $nice_timestamp = sprintf ("%04d.%02d.%02d %02d:%02d:%02d", $year+1900,$mon+1,$mday,$hour,$min,$sec);
    return $nice_timestamp;
}


###############################################################
# this sub converts a decimal IP to a dotted IP
sub dec2ip($) { join '.', unpack 'C4', pack 'N', shift; }

###############################################################
# this sub converts a dotted IP to a decimal IP
sub ip2dec($) { unpack N => pack CCCC => split /\./ => shift; }

###############################################################
### Whitespace (v.a. CR LF) rechts im String löschen

sub r_trim { my $s = shift; $s =~ s/\s+$//; return $s; }

###############################################################
### Whitespace links im String löschen

sub l_trim { my $s = shift; $s =~ s/^\s+//; return $s; }

###############################################################
### Allen Whitespace im String löschen

sub all_trim { my $s = shift; $s =~ s/\s+//g; return $s; }

###############################################################
### Doppelten Whitespace im String durch ein Leezeichen ersetzen

sub dbl_trim { my $s = shift; $s =~ s/\s+/ /g; return $s; }

###############################################################
### r_trim, l_trim, dbl_trim zusammen auf einen String anwenden

sub l_r_dbl_trim { my $s = shift; my $r = l_trim(r_trim(dbl_trim($s))); return $r; }


sub max($$) { $_[$_[0] < $_[1]]; }

sub min($$) { $_[$_[0] > $_[1]]; }


sub getFhemFriendly($)
#Ersetzt alle Zeichen so, dass das Ergebnis als FHEM Reading Name taugt.
{
my $working_string = shift;
my @tbr = ("ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz","[[:punct:][:space:][:cntrl:]]","_","___","_","__","_","^_","","_\$","");

for (my $i=0; $i <= scalar(@tbr)-1; $i+=2)
  {
   my $f = $tbr[$i];
   if ($working_string =~ /$f/)
      {
       my $r = $tbr[$i+1];
	   $working_string =~ s/$f/$r/g;
	  }
   }
return $working_string;
}


sub decodeTelegram($)
#Telegramme entschlüsseln und die entsprechenden Werte zur weiteren Entschlüsselung weiterreichen an sub getCsvResult
{
   my $TelegrammLength = length($_[0]);
   my @h = unpack("H2" x $TelegrammLength, $_[0]);
   
   my $hex_result = join(" ", @h);
   if ($verbose == 3) { add_to_log($hex_result); }
 
   my $FrameSize = hex($h[4].$h[5]);
   my $MainService = hex($h[10]);
   my $SubService = hex($h[11]);
   
   if ($FrameSize != $TelegrammLength) {
	  if ($verbose >= 1) { add_to_log("*** ERROR: TelegrammLength/FrameSize missmatch. [".$FrameSize."/".$TelegrammLength."] ***"); }
   } elsif ($SubService != 0x06) {
	  if ($verbose >= 1) { add_to_log("*** WARNING: No SetDatapointValue.Req. [".sprintf("%x", $SubService)."] ***"); }
   } elsif ($MainService == 0xF0 and $SubService == 0x06) {
      my $StartDatapoint = hex($h[12].$h[13]);
      my $NumberOfDatapoints = hex($h[14].$h[15]);
	  my $Position = 0;
	  
	  for (my $n=1; $n <= $NumberOfDatapoints; $n++) {
         my $DP_ID = hex($h[$Position + 16].$h[$Position + 17]);
         my $DP_command = hex($h[$Position + 18]);
         my $DP_length = hex($h[$Position + 19]);
         my $v = "";
		 my $send_msg = "";
         for (my $i=0; $i <= $DP_length - 1; $i++) { $v .= $h[$Position + 20 + $i]; }
         my $DP_value = hex($v);
	     my $auswertung =  getLoggingTime.";".getCsvResult($DP_ID, $DP_value);
		 if ($auswertung ne $last_auswertung) {
			$last_auswertung = $auswertung;
			 
			my @fields = split(/;/, $auswertung); # [0]=Timestamp, [1]=DP ID, [2]=Geraet, [3]=Datenpunkt, [4]=Wert, optional [5]=Einheit
			 
			if ($hash{output} eq 'fhem') {
			   ## Auswertung für FHEM erstellen ##
	           $send_msg = getFhemFriendly($fields[2]).".".$fields[1].".".getFhemFriendly($fields[3]); # Geraet - DP ID - Datenpunkt
			   if (scalar(@fields) == 6) { $send_msg .= ".".getFhemFriendly($fields[5]); } # Einheit (wenn vorhanden)
			   $send_msg .= " ".$fields[4]; # Wert (nach Leerstelle!)
			} elsif ($hash{output} eq 'csv') {
			   ## Auswertung als CSV erstellen ##
	           $send_msg = $fields[1].";".$fields[2].";".$fields[3].";".$fields[4];
			   if (scalar(@fields) == 6) { $send_msg .= ";".$fields[5]; }
                        } elsif ($hash{output} eq 'data') {
                            my @types = ("DPT_Scaling","DPT_Value_Temp","DPT_Value_Tempd","DPT_Value_Pres",
                                       "DPT_Power","DPT_Value_Volume_Flow","DPT_TimeOfDay",
                                       "DPT_Date","DPT_FlowRate_m3/h","DPT_ActiveEnergy",
                                       "DPT_ActiveEnergy_kWh" );
                            my $datatype = getDatenpunkt($DP_ID, 3);

                            if (grep( /^$datatype$/, @types )) {
                                $send_msg = $fields[1].";".$fields[4];
                            } else {
                                $send_msg = $fields[1].";".$DP_value;
                            }
                        }

			## Auswertung an Multicast Gruppe schicken ..
			send_IGMPmessage($send_msg);
			
			## Wenn aktiviert, Auswertung in ein File schreiben ##
			if ($hash{dplog} eq '1') { log_msg_data($send_msg,$hash{output}); }
			 
			## Wolf ISMi basierte Werte alle 60 Minuten schicken ##
			if (time >= $fw_actualize and $hash{output} eq 'fhem') { 
			   send_IGMPmessage("ISM8i.997.IP $hash{ism8i_ip}");
			   send_IGMPmessage("ISM8i.998.Port $hash{port}");
			   send_IGMPmessage("ISM8i.999.Firmware $hash{fw}");
			   $fw_actualize = time + 3600;
			}	
		 }
		 $Position += 4 + $DP_length;
	  }
   }
}


sub loadConfig
#Config Datei laden und Werte zwischenspeichern. Wenn keine Config Datei vorhanden ist wird eine angelegt.
#Wenn die Werte in der Config nicht den Vorgaben entsprechen, dann werden die Standardwerte genommen. 
#
#Bedeutung der Einträge der Config:
#   ism8i_port = Port auf dem das Modul auf den TCP Trafic des Wolf ISM8i Schnittstellenmoduls hört.
#                Die IP und der Port wird im Webinterface des Schnittstellenmoduls eingestellt. Die IP
#                ist die IP des PCs/Raspis auf dem dieses Modul läuft.
#                Default ist 12004.
#   fw_version = Die Firmware Version des Wolf ISM8i Schnittstellenmoduls. Diese steht im Webinterface des Schnittstellenmoduls.
#                Möglich sind 1.4 oder 1.5.
#                Default ist 1.5.
#   multicast_ip = die IPv4 Adresse der Multicast Gruppe an der die die entschlüsselten Datagramme geschickt werden. Default ist 
#                  Bitte beim Ändern auf die Vorgaben für Multicast Adressen achten!
#                  Default ist 239.7.7.77.
#   multicast_port = Der Port der Multicast Gruppe. Möglich von 1 bis 65535.
#                    Default ist 35353.
#   dp_log = Gibt an ob die empfangenen Datenpunkte als Log ausgegeben werden sollnen.
#            Wenn geloggt wird bitte in regelmäßigen Abständen die Größe des Logfiles prüfen und ggf. löschen, dader Log schnell sehr groß werden kann.
#            Möglich sind 0 oder 1.
#            Default ist 0.
#   output = Das Format in welchem die Datenpunkte an die Multicast Gruppe oder an das Datenpunkte-Log gesickt wird. 
#            Möglich ist 'csv' für das CSV Format (mit Semikolon (;) separiert) z.B. zum Importieren in Tabekkenkalkulationen. 
#            Möglich ist 'fhem' als Spezialformat für das ISM8I Modul.
#            Default ist 'fhem'.
#
{
   my $file = $lbpconfigdir."/wolf_ism8i.conf";
   add_to_log("Reading Config:");
   if (-e $file) {
	  my $data;
      open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
      add_to_log("   Config file '$file' found and opened for reading.");
      while (my $line = <$data>) {
	    $line = lc($line); # alles lowe case
		if ($line !~ m/#/) {
		   my @fields = split(/ /, l_r_dbl_trim($line));
	       if (scalar(@fields) == 2) {
              add_to_log("      $fields[0] -> $fields[1]");
	          if ($fields[0] eq "ism8i_port") { 
		         if ($fields[1] =~ m/^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$/ and $fields[1] > 0 and $fields[1] <= 65535) {
			        $hash{port} = $fields[1]; } else { $hash{port} = '12004'; }
		      } elsif ($fields[0] eq "fw_version") {
		         if ($fields[1] =~ m/^\d{1}\.\d{1}$/) {
		         $hash{fw} = $fields[1]; } else { $hash{fw} = '1.5'; }
			     if ($hash{fw} ne '1.4') { $hash{fw} = '1.5'; }
		      } elsif ($fields[0] eq "multicast_ip") {
     		     if ($fields[1] =~ m/^(?:(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.){3}(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])$/) {
		         $hash{mcip} = $fields[1]; } else { $hash{mcip} = '239.7.7.77'; }
		      } elsif ($fields[0] eq "multicast_port") {
		         if ($fields[1] =~ m/^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$/ and $fields[1] > 0 and $fields[1] <= 65535) {
			        $hash{mcport} = $fields[1]; } else { $hash{mcport} = '35353'; }
		      } elsif ($fields[0] eq "dp_log") {
		         if ($fields[1] =~ m/^(1|0)$/) {
		            $hash{dplog} = $fields[1]; } else { $hash{dplog} = '0'; }
		      } elsif ($fields[0] eq "output") {
                         if ($fields[1] =~ m/^(csv|fhem|data)$/) {
		            $hash{output} = $fields[1]; } else { $hash{dplog} = 'fhem'; }
	          }
		   }	  
	    }
      }
	  close $data;
   } else {
     add_to_log("   Config file not found, creating new config file.");
     open(my $fh, '>:encoding(UTF-8)', $file) or die "Could not open/write file '$file' $!";
	  
     print $fh "######################################################################################################################################################\n";
     print $fh "#Config Datei laden und Werte zwischenspeichern. Wenn keine Config Datei vorhanden ist wird eine angelegt.\n";
     print $fh "#Wenn die Werte in der Config nicht den Vorgaben entsprechen, dann werden die Standardwerte genommen.\n";
     print $fh "######################################################################################################################################################\n";
     print $fh "#Bedeutung der Einträge der Config:\n";
     print $fh "#\n";
     print $fh "#   ism8i_port = Port auf dem das Modul auf den TCP Trafic des Wolf ISM8i Schnittstellenmoduls hört.\n";
     print $fh "#                Die IP und der Port wird im Webinterface des Schnittstellenmoduls eingestellt. Die IP\n";
     print $fh "#                ist die IP des PCs/Raspis auf dem dieses Modul läuft.\n";
     print $fh "#                Default ist 12004.\n";
     print $fh "#   fw_version = Die Firmware Version des Wolf ISM8i Schnittstellenmoduls. Diese steht im Webinterface des Schnittstellenmoduls.\n";
     print $fh "#                Möglich sind 1.4 oder 1.5\n";
     print $fh "#                Default ist 1.5\n";
     print $fh "#   multicast_ip = die IPv4 Adresse der Multicast Gruppe an der die die entschlüsselten Datagramme geschickt werden. Default ist\n";
     print $fh "#                  Bitte beim Ändern auf die Vorgaben für Multicast Adressen achten!\n";
     print $fh "#                  Default ist 239.7.7.77.\n";
     print $fh "#   multicast_port = Der Port der Multicast Gruppe. Möglich von 1 bis 65535.\n";
     print $fh "#                    Default ist 35353.\n";
     print $fh "#   dp_log = Gibt an ob die empfangenen Datenpunkte als Log ausgegeben werden sollnen.\n";
     print $fh "#            Wenn geloggt wird bitte in regelmäßigen Abständen die Größe des Logfiles prüfen und ggf. löschen, dader Log schnell sehr groß werden kann.\n";
     print $fh "#            Möglich sind 0 oder 1.\n";
     print $fh "#            Default ist 0.\n";
     print $fh "#   output = Das Format in welchem die Datenpunkte an die Multicast Gruppe oder an das Datenpunkte-Log gesickt wird.\n";
     print $fh "#            Möglich ist 'csv' für das CSV Format (mit Semikolon (;) separiert) z.B. zum Importieren in Tabekkenkalkulationen.\n";
     print $fh "#            Möglich ist 'fhem' als Spezialformat für das ISM8I Modul.\n";
     print $fh "#            Default ist 'fhem'\n";
     print $fh "######################################################################################################################################################\n\n";
	 
	 print $fh "ism8i_port $hash{port}\n";
	 print $fh "fw_version $hash{fw}\n";
	 print $fh "multicast_ip $hash{mcip}\n";
	 print $fh "multicast_port $hash{mcport}\n";
	 print $fh "dp_log $hash{dplog}\n";
	 print $fh "output $hash{output}\n";

     close $fh;
   }
	
   add_to_log("      [$hash{port}] [$hash{fw}] [$hash{mcip}] [$hash{mcport}] [$hash{dplog}] [$hash{output}]");
}


sub loadDatenpunkte
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: DP ID, Gerät, Datenpunkt KNX-Datenpunkttyp, Output/Input, Einheit
#Die einzelnen CSV Felder dürfen keine Kommas, Leerstellen oder Anführungszeichen enthalten.
{
   #erstmal vorsichtshalber datenpunkte array löschen:
   while(@datenpunkte) { shift(@datenpunkte); }
   
   my $fw_version = $hash{fw};
   $fw_version =~ s/\.//g;
   my $file = $script_path."/wolf_datenpunkte_".$fw_version.".csv";
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


sub showDatenpunkte
#Devloper Sub zur Kontrolle des eingelesenen CSV Files
{
   print "\n";
   foreach my $o (@datenpunkte) {
	  foreach my $i (@$o) { print $i."  "; }
	  print "\n";
   }
}


sub writeDatenpunkteToLog
#Devloper Sub zur Kontrolle des eingelesenen CSV Files
{
   my $filename = $lbplogdir."/wolf_ism8i_datenpunkte.log";
   open(my $fh, '>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   print $fh "\n";
   foreach my $o (@datenpunkte)
     {
	  foreach my $i (@$o) { print $fh $i."  "; }
	  print $fh "\n";
	 }
   close $fh;
}


sub getDatenpunkt($$)
#Returnt aus dem 2D Array mit Datenpunkten den Datenpunkt als Array mit der übergebenen DP ID.
#$1 = DP ID , $2 = Index des Feldes (0 = DP ID, 1 = Gerät, 2 = Datenpunkt, 3 = KNX-Datenpunkttyp, 4 = Output/Input, 5 = Einheit)
{
   my $d = $datenpunkte[$_[0]][$_[1]];
   if ( (defined $d) and (length($d)>0) ) { return $d; } else { return "ERR:NotFound"; } 
}


sub getCsvResult($$)
#Berchnet den Inhalt des Telegrams und gibt das Ergebnis im CSV Mode ';'-separiert.
#$1 = DP ID , $2 = DP Value
#Ergebnis: DP_ID [1]; Gerät [2]; Erignis [3]; Wert [4]; Einheit [5] (falls vorhanden)
{
   my $dp_id = $_[0];
   my $dp_val = $_[1];
   my $geraet = getDatenpunkt($dp_id, 1);
   my $ereignis = getDatenpunkt($dp_id, 2);
   my $datatype = getDatenpunkt($dp_id, 3);
   my $result = $dp_id.";".$geraet.";".$ereignis.";";
   my $v = "ERR:NoResult";
   
   if ($datatype eq "DPT_Switch") 
     {
	  if ($dp_val == 0) {$v = "Aus";} elsif ($dp_val == 1) {$v = "An";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Bool") 
     {
	  if ($dp_val == 0) {$v = "Falsch";} elsif ($dp_val == 1) {$v = "Wahr";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Enable") 
     {
	  if ($dp_val == 0) {$v = "Deaktiviert";} elsif ($dp_val == 1) {$v = "Aktiviert";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_OpenClose") 
     {
	  if ($dp_val == 0) {$v = "Offen";} elsif ($dp_val == 1) {$v = "Geschlossen";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Scaling") 
     {
	  $result .= nearest(0.01, ($dp_val & 0xff) * 100 / 255).";%";
	 }
   elsif ($datatype eq "DPT_Value_Temp") 
     {
	  $result .= pdt_knx_float($dp_val).";°C";
	 }
   elsif ($datatype eq "DPT_Value_Tempd") 
     {
	  $result .= pdt_knx_float($dp_val).";K";
	 }
   elsif ($datatype eq "DPT_Value_Pres") 
     {
	  $result .= pdt_knx_float($dp_val).";Pa";
	 }
   elsif ($datatype eq "DPT_Power") 
     {
	  $result .= pdt_knx_float($dp_val).";kW";
	 }
   elsif ($datatype eq "DPT_Value_Volume_Flow") 
     {
	  $result .= pdt_knx_float($dp_val).";l/h";
	 }
   elsif ($datatype eq "DPT_TimeOfDay") 
     {
	  $result .= pdt_time($dp_val);
	 }
   elsif ($datatype eq "DPT_Date") 
     {
	  $result .= pdt_date($dp_val);
	 }
   elsif ($datatype eq "DPT_FlowRate_m3/h") 
     {
	  $result .= (pdt_long($dp_val) * 0.0001).";m³/h";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy") 
     {
	  $result .= pdt_long($dp_val).";Wh";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy_kWh") 
     {
	  $result .= pdt_long($dp_val).";kWh";
	 }
   elsif ($datatype eq "DPT_HVACMode") 
     {
	  my @Heizkreis = ("Automatikbetrieb","Heizbetrieb","Standby","Sparbetrieb","-");

	  my @CWL = ("Automatikbetrieb","Nennlüftung","-","Reduzierung Lüftung","-");
	 
      if ($geraet =~ /Heizkreis/ or $geraet =~ /Mischerkreis/)
	   	{ $v = $Heizkreis[$dp_val]; }
	  elsif ($geraet =~ /CWL/)
	   	{ $v = $CWL[$dp_val]; }
      
	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_DHWMode") 
     {
	  my @Warmwasser = ("Automatikbetrieb","-","Dauerbetrieb","-","Standby");

      if ($geraet =~ /Warmwasser/) { $v = $Warmwasser[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_HVACContrMode") 
     {
	  my @CGB2_MGK2_TOB = ("Schornsteinferger","Heiz- Warmwasserbetrieb","-","-","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","Kalibration");

      my @BWL1S = ("Antilegionellenfunktion","Heiz- Warmwasserbetrieb","Vorwärmung","Aktive Kühlung","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","-");
				   
	  if ($geraet =~ /CGB-2/ or $geraet =~ /MGK-2/ or $geraet =~ /TOB/)
	    { $v = $CGB2_MGK2_TOB[$dp_val]; }
	  elsif ($geraet =~ /BWL-1-S/)
	   	{ $v = $BWL1S[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
	else
	 {
	  $result .= "ERR:TypeNotFound[".$datatype."]";
	 }

   return $result;   
}

# "<ID> <VALUE>"
# test parseInput("104;-30");
sub parseInput($)
{
    my @input = split /;/, $_[0];
    my $id = $input[0];
    my $data = $input[1];
    if (scalar(@input) != 2) {
        add_to_log("Invalid command, expected the format: <ID>;<VALUE>");
        return;
    }
    my $geraet = getDatenpunkt($id, 1);
    my $datatype = getDatenpunkt($id, 3);
    my $writeable = getDatenpunkt($id, 4) =~ m/In/;
    if (!$writeable) {
        add_to_log("Datenpunkt $id kann nicht beschrieben werden!");
        return;
    }

    add_to_log("VALUE: ".$data);

    my $enc_value;

    if ($datatype eq "DPT_Switch" ||
        $datatype eq "DPT_Bool" ||
        $datatype eq "DPT_Enable" ||
        $datatype eq "DPT_OpenClose") {
        if ($data < 0 || $data > 1) {
            add_to_log("Invalid input!");
            return;
        }
        $enc_value = pack("C", $data);
    }
    elsif ($datatype eq "DPT_Scaling") {
        $enc_value = pack("C", round($data / 100 * 255));
    }
    elsif ($datatype eq "DPT_Value_Temp" ||
           $datatype eq "DPT_Value_Tempd" ||
           $datatype eq "DPT_Value_Pres" ||
           $datatype eq "DPT_Power" ||
           $datatype eq "DPT_Value_Volume_Flow")
    {
        $enc_value = to_pdt_float($data);
    }
    elsif ($datatype eq "DPT_TimeOfDay")
    {
        $enc_value = to_pdt_time($data);
    }
    elsif ($datatype eq "DPT_Date")
    {
        $enc_value = to_pdt_date($data);
    }
    elsif ($datatype eq "DPT_FlowRate_m3/h")
    {
        $enc_value = to_pdt_long($data * 10000);
    }
    elsif ($datatype eq "DPT_ActiveEnergy" ||
           $datatype eq "DPT_ActiveEnergy_kWh") {
        $enc_value = to_pdt_long($data);
    }
    elsif ($datatype eq "DPT_HVACMode")  {
        if ($geraet =~ /Heizkreis/ or $geraet =~ /Mischerkreis/) {
            if ($data < 0 || $data > 3) {
                add_to_log("Invalid input!");
                return;
            }
            $enc_value = pack("C", $data);
        } elsif ($geraet =~ /CWL/) {
            if (!($data == 0 || $data == 1 || $data == 3)) {
                add_to_log("Invalid input!");
                return;
            }
            $enc_value = pack("C", $data);
        } else {
            add_to_log("errr");
            add_to_log("Invalid input!");
            return;
        }
    }
    elsif ($datatype eq "DPT_DHWMode") {
        if ($geraet =~ /Warmwasser/) {
            if (!($data == 0 || $data == 2 || $data == 4)) {
                add_to_log("Invalid input!");
                return;
            }
            $enc_value = pack("C", $data);
        } else {
            add_to_log("Invalid input!");
            return;
        }
    }
    else {
        add_to_log("Invalid type!");
        return;
    }

    return createRequest($id, $enc_value);
}

sub pdt_knx_float($)
{
# Format: 
#   2 octets: F16
#   octet nr: 2MSB 1LSB
#   field names: FloatValue
#   encoding: MEEEEMMMMMMMMMMM
# Encoding: 
#   Float Value = (0,01*M)*2**(E)
#   E = [0...15]
#   M = [-2048...2047], two‘s complement notation
#   For all Datapoint Types 9.xxx, the encoded value 7FFFh shall always be used to denote invalid data.
# Range: [-671088,64...670760,96]
# PDT: PDT_KNX_FLOAT
#
   my $val = $_[0];
   my $m = (-2048 * (($val & 0b10000000_00000000) >> 15)) + ($val & 0b111_11111111);
   my $e = ($val & 0b01111000_00000000) >> 11;

   return (0.01 * $m) * (2 ** $e);
}

sub to_pdt_float($)
{
    my $mant = int(100 * $_[0]);
    my $exp = 0;
    while($mant < -2047 || $mant > 2047) {
        $mant = int($mant / 2);
        $exp += 1;
    }
    my $sign = 0;
    if ($mant < 0) {
        $sign = 1;
        $mant = -$mant;
        $mant = (~$mant + 1) & 0x7FF;
    }

    $exp = $exp << 11;
    $sign = $sign << 15;
    my $val = $mant | $exp | $sign;
#    printf ("mant %10b %3d\n",$mant,$mant);
#    printf ("exp %10b %3d\n",$exp,$exp);
#    printf ("sign %10b %3d\n",$sign,$sign);
#    printf ("val %10b %3d\n",$val,$val);

    return pack("n", $val);
}


sub pdt_long($)
{
# Format: 4 octets: V32
# octet nr: 4MSB 3 2 1LSB
# field names: SignedValue
# encoding: VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
# Encoding: Two‘s complement notation
# Range: SignedValue = [-2 147 483 648 ... 2 147 483 647]
# PDT: PDT_LONG   my $val = $_[0];
#
   my $val = $_[0];
   my $r = (-1 * ($val & 0b10000000_00000000_00000000_00000000)) + ($val & 0b1111111_11111111_11111111_11111111);

   return $r;
}

sub to_pdt_long($)
{
    return pack("N", $_[0]);
}

sub pdt_time($)
{
# 3 Byte Time
# DDDHHHHH RRMMMMMM RRSSSSSS
# R Reserved
# D Weekday
# H Hour
# M Minutes
# S Seconds
   my $b1 = ($_[0] & 0xff0000) >> 16;
   my $b2 = ($_[0] & 0x00ff00) >> 8;
   my $b3 = ($_[0] & 0x0000ff);
   my $weekday = ($b1  & 0xe0) >> 5;
   my @weekdays = ["","Mo","Di","Mi","Do","Fr","Sa","So"];
   my $hour = $b1 & 0x1f;
   my $min = $b2 & 0x3f;
   my $sec = $b3 & 0x3f;
   return sprintf("%s %d:%d:%d", $weekdays[$weekday], $hour, $min, $sec);
}

sub to_pdt_time($)
{
    my @d = split / /, $_[0];
    my @h = split / /, $d[1];
    my $day = $d[0];
    my $hour = $h[0];
    my $min = $h[1];
    my $sec = $h[2];
    my @weekdays = ["","Mo","Di","Mi","Do","Fr","Sa","So"];

    $day = first_index { $_ eq $day } @weekdays;
    if ($day == 0) {
        add_to_log("Couldn't parse day. Possibe values: ".join(" ",@weekdays));
        return -1;
    }
    if ($hour < 0 || $hour > 23) {
        add_to_log("Invalid hour: $hour");
        return -1;
    }
    if ($min < 0 || $min > 59) {
        add_to_log("Invalid minute: $min");
        return -1;
    }
    if ($sec < 0 || $sec > 59) {
        add_to_log("Invalid seconds: $sec");
        return -1;
    }
    $day = $day << 5;
    return pack("C C C", $day | $hour, $min, $sec);
}

sub pdt_date($)
{
# 3 byte Date
# RRRDDDDD RRRRMMMM RYYYYYYY
# R Reserved
# D Day
# M Month
# Y Year
   my $b1 = ($_[0] & 0xff0000) >> 16;
   my $b2 = ($_[0] & 0x00ff00) >> 8;
   my $b3 = ($_[0] & 0x0000ff);
   my $day = $b1 & 0x1f;
   my $mon = $b2 & 0xf;
   my $year = $b3 & 0x7f;
   if ($year < 90) { $year += 2000; } else { $year += 1900; }
   return sprintf("%02d.%02d.%04d", $day, $mon, $year);
}

sub to_pdt_date($)
{
    my @d = split /\./, $_[0];
    my $day = $d[0];
    my $mon = $d[1];
    my $year = $d[2];
    if ($day < 0 || $day > 31) {
        add_to_log("Invalid day: $day");
        return -1;
    }
    if ($mon < 0 || $mon > 12) {
        add_to_log("Invalid month: $mon");
        return -1;
    }
    if ($year < 0 || $year > 99) {
        add_to_log("Invalid year: $year");
        return -1;
    }
    return pack("C C C",$day, $mon, $year);
}

sub getBitweise($$$)
#Berechnet aus einer Zahl eine Zahl anhand der vorgegebenen Bits.
#$1 = Zahl, $2 = Startbit, $3 = Endbit
{
   my $start_bit = $_[1];
   my $end_bit = $_[2];
   my $val = $_[0] >> $start_bit - 1;
   my $mask = 0xffffffff >> (32 - ($end_bit - $start_bit +1));
   my $result = $val & $mask;
   return $result;
}

exit 0;
