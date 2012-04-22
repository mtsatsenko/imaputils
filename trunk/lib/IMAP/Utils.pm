# IMAP::Utils - common parts of imaputils scripts
#use strict;
#use warnings;

package IMAP::Utils;
require Exporter;
@ISA = qw(Exporter);
@EXPORT= qw(Log openLog connectToHost readResponse sendCommand signalHandler logout login conn_timed_out getDelimiter @response hash trim);

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
    if ($debug) { Log (">> $cmd",2); }
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
    Log ("<< *** Connection timeout ***") if $conn_timed_out;
    if ($debug) { Log ("<< $response",2); }
    return $response;
}

#  login
#
#  login in at the source host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $conn = shift;
my $method = shift or 'LOGIN';

   Log("Authenticating as $user");
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

sub cram_md5 {

my $challenge = shift;
my $user      = shift;
my $password  = shift;

eval 'use Digest::HMAC_MD5 qw(hmac_md5_hex)';
use MIME::Base64 qw(decode_base64 encode_base64);

   # Adapated from script by Paul Makepeace <http://paulm.com>, 2002-10-12 
   # Takes user, key, and base-64 encoded challenge and returns base-64 
   # encoded CRAM. See, 
   # IMAP/POP AUTHorize Extension for Simple Challenge/Response: 
   # RFC 2195 http://www.faqs.org/rfcs/rfc2195.html 
   # SMTP Service Extension for Authentication: 
   # RFC 2554 http://www.faqs.org/rfcs/rfc2554.html 
   # Args: tim tanstaaftanstaaf PDE4OTYuNjk3MTcwOTUyQHBvc3RvZmZpY2UucmVzdG9uLm1jaS5uZXQ+ 
   # should yield: dGltIGI5MTNhNjAyYzdlZGE3YTQ5NWI0ZTZlNzMzNGQzODkw 

   my $challenge_data = decode_base64($challenge);
   my $hmac_digest = hmac_md5_hex($challenge_data, $password);
   my $response = encode_base64("$user $hmac_digest");
   chomp $response;

   if ( $debug ) {
      Log("Challenge: $challenge_data");
      Log("HMAC digest: $hmac_digest");
      Log("CRAM Base64: $response");
   }

   return $response;
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
   Log("Resuming");
}

#  Determine whether a string contains non-ASCII characters
sub isAscii {

my $str = shift;
my $ascii = 1;

   my $test = $str;
   $test=~s/\P{IsASCII}/?/g;
   $ascii = 0 unless $test eq $str;

   return $ascii;

}

sub getDelimiter  {

my $conn = shift;
my $delimiter;

   #  Issue a 'LIST "" ""' command to find out what the
   #  mailbox hierarchy delimiter is.

   sendCommand ($conn, '1 LIST "" ""');
   @response = '';
   while ( 1 ) {
        $response = readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
                last;
        }
        elsif ( $response !~ /^\*/ ) {
                Log ("unexpected response: $response");
                return 0;
        }
   }

   for $i (0 .. $#response) {
        $response[$i] =~ s/\s+/ /;
        if ( $response[$i] =~ /\* LIST \((.*)\) "(.*)" "(.*)"/i ) {
           $delimiter = $2;
        }
   }

   return $delimiter;
}

#  Generate an MD5 hash of the message body
sub hash {
use Digest::MD5 qw(md5_hex);
my $msg = shift;
my $body;
my $boundary;

   #  Strip the header and the MIME boundary markers
   my $header = 1;
   foreach $_ ( split(/\n/, $$msg ) ) {
      if ( $header ) {
         if (/boundary="(.+)"/i ) {
            $boundary = $1;
         }
         $header = 0 if length( $_ ) == 1;
      }

      next if /$boundary/;
      $body .= "$_\n" unless $header;
   }

   my $md5 = md5_hex($body);
   Log("md5 hash $md5") if $debug;

   return $md5;
}

#  trim
#
#  remove leading and trailing spaces from a string
sub trim {

local (*string) = @_;

   $string =~ s/^\s+//;
   $string =~ s/\s+$//;

   return;
}

1;
