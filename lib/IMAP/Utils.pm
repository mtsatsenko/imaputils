# IMAP::Utils - common parts of imaputils scripts
#use strict;
#use warnings;

package IMAP::Utils;
require Exporter;
@ISA = qw(Exporter);
@EXPORT= qw(Log openLog connectToHost readResponse sendCommand signalHandler);

#  Open the logFile
#
sub openLog {
   $logfile = shift;
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
         exit;
      }
      select(LOG); $| = 1;
   }
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDOUT
#

sub Log {

my $str = shift;

   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
   if ($year < 99) { $yr = 2000; }
   else { $yr = 1900; }
   $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s %s\n",
             $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$$,$str);
   print LOG "$line";
   print STDOUT "$str\n";

}

sub init {

   #  Determine whether we have SSL support via openSSL and IO::Socket::SSL
   $ssl_installed = 1;
   eval 'use IO::Socket::SSL';
   if ( $@ ) {
      $ssl_installed = 0;
   }

   $utf7_installed = 1;
   eval 'use Unicode::IMAPUtf7';
   if ( $@ ) {
      $utf7_installed = 0;
   }
}

# open a connection to IMAP server

sub connectToHost {

my $host = shift;
my $conn = shift;

   ($host,$port) = split(/:/, $host);
   $port = 143 unless $port;

   # We know whether to use SSL for ports 143 and 993.  For any
   # other ones we'll have to figure it out.
   $mode = sslmode( $host, $port );

   if ( $mode eq 'SSL' ) {
      unless( $ssl_installed == 1 ) {
         warn("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         exit;
      }
      print "Attempting an SSL connection\n" if $debug;
      $$conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        $error = IO::Socket::SSL::errstr();
        print "Error connecting to $host: $error\n";
        exit;
      }
   } else {
      #  Non-SSL connection
      print "Attempting a non-SSL connection\n" if $debug;
      $$conn = IO::Socket::INET->new(
         Proto           => "tcp",
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        print "Error connecting to $host:$port: $@\n";
        warn "Error connecting to $host:$port: $@";
        exit;
      }
   }
   print "Connected to $host on port $port\n";

}


##################
sub sslmode {

my $host = shift;
my $port = shift;
my $mode;

   #  Determine whether to make an SSL connection
   #  to the host.  Return 'SSL' if so.

   if ( $port == 143 ) {
      #  Standard non-SSL port
      return '';
   } elsif ( $port == 993 ) {
      #  Standard SSL port
      return 'SSL';
   }

   unless ( $ssl_installed ) {
      #  We don't have SSL installed on this machine
      return '';
   }

   #  For any other port we need to determine whether it supports SSL

   my $conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
    );

    if ( $conn ) {
       close( $conn );
       $mode = 'SSL';
    } else {
       $mode = '';
    }

   return $mode;
}
#
#  sendCommand
#
#  This subroutine formats and sends an IMAP protocol command to an
#  IMAP server on a specified connection.
#

sub sendCommand {

    my $fd = shift;
    my $cmd = shift;

    print $fd "$cmd\r\n";
    if ($showIMAP) { Log (">> $cmd",2); }
}
#
#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse {

    my $fd = shift;
    exit unless defined $fd;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    if ($showIMAP) { Log ("<< $response",2); }
    return $response;
}

#  Handle signals

sub signalHandler {

my $sig = shift;

   if ( $sig eq 'ALRM' ) {
      Log("Caught a SIG$sig signal, timeout error");
      $conn_timed_out = 1;
   } else {
      Log("Caught a SIG$sig signal, shutting down");
      exit;
   }
}

1;
