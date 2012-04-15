# IMAP::Utils - common parts of imaputils scripts
#use strict;
#use warnings;

package IMAP::Utils;
require Exporter;
@ISA = qw(Exporter);
@EXPORT= qw(Log openLog connectToHost readResponse sendCommand signalHandler logout login);

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

#  login
#
#  login in at the source host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $host = shift;
my $conn = shift;
my $method = shift or 'LOGIN';

   Log("Authenticating to $host as $user");
   if ( uc( $method ) eq 'CRAM-MD5' ) {
      #  A CRAM-MD5 login is requested
      Log("login method $method");
      my $rc = login_cram_md5( $user, $pwd, $conn );
      return $rc;
   }

   #  Otherwise do a PLAIN login

   sendCommand ($conn, "1 LOGIN $user \"$pwd\"");
   while (1) {
        readResponse ( $conn );
        last if $response =~ /^1 OK/i;
        if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
        }
   }
   Log("Logged in as $user") if $debug;

   return 1;
}

sub login_cram_md5 {

my $user = shift;
my $pwd  = shift;
my $conn = shift;

   sendCommand ($conn, "1 AUTHENTICATE CRAM-MD5");
   while (1) {
        readResponse ( $conn );
        last if $response =~ /^\+/;
        if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
        }
   }

   my ($challenge) = $response =~ /^\+ (.+)/;

   Log("challenge $challenge") if $debug;
   $response = cram_md5( $challenge, $user, $pwd );
   Log("response $response") if $debug;

   sendCommand ($conn, $response);
   while (1) {
        readResponse ( $conn );
        last if $response =~ /^1 OK/i;
        if ($response =~ /^1 NO|^1 BAD|^\* BYE/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
        }
   }
   Log("Logged in as $user") if $debug;

   return 1;
}


# logout from IMAP server
sub logout {

   my $conn = shift;

   undef @response;
   sendCommand ($conn, "1 LOGOUT");
   while ( 1 ) {
        $response = readResponse ($conn);
        next if $response =~ /APPEND complete/i;   # Ignore strays
        if ( $response =~ /^1 OK/i ) {
                last;
        }
        elsif ( $response !~ /^\*/ ) {
                print "Unexpected LOGOUT response: $response\n";
                last;
        }
   }
   close $conn;
   return;
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
