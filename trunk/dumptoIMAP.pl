#!/usr/bin/perl

#  $Header: /mhub4/sources/imap-tools/dumptoIMAP.pl,v 1.4 2012/02/09 15:34:55 rick Exp $

use Socket;
use IO::Socket;
use FileHandle;
use File::Find;
use Fcntl;
use Getopt::Std;

init();

connectToHost($imapHost, \$conn);
unless ( login($imapUser,$imapPwd, $conn) ) {
    Log("Check your username and password");
    print STDOUT "Login failed: Check your username and password\n";
    exit;
}

Log("Copying messages from $dir to $mbx folder on the IMAP server");
get_messages( $dir, \@msgs );
foreach $_ ( @msgs ) {
   my $msg; my $date;
   Log("Opening $_");
   unless ( open(F, "<$_") ) {
      Log("Error opening $_: $!");
      next;
   }
   Log("Opened $_ successfully");
   while( <F> ) {
      Log("Reading line $_");
      if ( /^Date: (.+)/ )  {
         $date = $1 unless $date;
         $date =~ s/\r|\m//g;
         chomp $date;
      }
      $msg .= $_;
   }
   close F;
   $size = length( $msg );
   Log("The message is $size bytes");
   Log("contents of msg file");
   Log("$msg") if $debug;
 
   if ( $size == 0 ) {
      Log("The message file is empty");
      next;
   }
   $copied++ if insertMsg($mbx, \$msg, '', $date, $conn);
exit;

   if ( $copied/100 == int($copied/100)) { Log("$copied messages copied "); }

}

logout( $conn );

Log("Done. $copied messages were copied.");
exit;


sub init {

   if ( !getopts('m:L:i:dD:Ix:') ) {
      usage();
   }

   $mbx      = $opt_m;
   $dir      = $opt_D;
   $logfile  = $opt_L;
   $extension = $opt_x;
   $debug     = 1 if $opt_d;
   $showIMAP  = 1 if $opt_I;
   ($imapHost,$imapUser,$imapPwd) = split(/\//, $opt_i);

   if ( $logfile ) {
      if ( ! open (LOG, ">> $logfile") ) {
        print "Can't open logfile $logfile: $!\n";
        $logfile = '';
      }
   }
   Log("Starting");

   #  Determine whether we have SSL support via openSSL and IO::Socket::SSL
   $ssl_installed = 1;
   eval 'use IO::Socket::SSL';
   if ( $@ ) {
      $ssl_installed = 0;
   }
}



sub usage {

   print "Usage: dumptoIMAP.pl\n";
   print "    -D <path to message files>\n";
   print "    -m <name of IMAP mailbox to put messages into>\n";
   print "    -i <server/username/password>\n";
   print "    [-x <extension> Import only files with this extension\n";
   print "    [-L <logfile>]\n";
   print "    [-d debug]\n";
   print "    [-I log IMAP protocol exchanges]\n";

}

sub get_messages {

my $dir  = shift;
my $msgs = shift;

   #  Get a list of the message files 

   opendir D, $dir;
   my @files = readdir( D );
   closedir D;
   foreach $_ ( @files ) {
      next if /^\./;
      if ( $extension ) {
         next unless /$extension$/;
      }
      push( @$msgs, "$dir/$_");
   }
}

#  Print a message to STDOUT and to the logfile if
#  the opt_L option is present.
#

sub Log {

my $line = shift;
my $msg;

   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime (time);
   $msg = sprintf ("%.2d-%.2d-%.4d.%.2d:%.2d:%.2d %s",
                  $mon + 1, $mday, $year + 1900, $hour, $min, $sec, $line);

   if ( $logfile ) {
      print LOG "$msg\n";
   }
   print STDOUT "$line\n";

}

#  connectToHost
#
#  Make an IMAP connection to a host
# 
sub connectToHost {

my $host = shift;
my $conn = shift;

   Log("Connecting to $host") if $debug;

   $sockaddr = 'S n a4 x8';
   ($name, $aliases, $proto) = getprotobyname('tcp');
   ($host,$port) = split(/:/, $host);
   $port = 143 unless $port;

   if ($host eq "") {
	Log ("no remote host defined");
	close LOG; 
	exit (1);
   }

   # We know whether to use SSL for ports 143 and 993.  For any
   # other ones we'll have to figure it out.
   $mode = sslmode( $host, $port );

   if ( $mode eq 'SSL' ) {
      unless( $ssl_installed == 1 ) {
         warn("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         Log("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         exit;
      }
      Log("Attempting an SSL connection") if $debug;
      $$conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        $error = IO::Socket::SSL::errstr();
        Log("Error connecting to $host: $error");
        exit;
      }
   } else {
      #  Non-SSL connection
      Log("Attempting a non-SSL connection") if $debug;
      $$conn = IO::Socket::INET->new(
         Proto           => "tcp",
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        Log("Error connecting to $host:$port: $@");
        warn "Error connecting to $host:$port: $@";
        exit;
      }
   } 

   select( $$conn ); $| = 1;
   return 1;
}

#
#  login in at the IMAP host with the user's name and password
#
sub login {

my $user = shift;
my $pwd  = shift;
my $conn = shift;

   Log("Logging in as $user") if $debug;
   $rsn = 1;
   sendCommand ($conn, "$rsn LOGIN $user $pwd");
   while (1) {
	readResponse ( $conn );
	if ($response =~ /^$rsn OK/i) {
		last;
	}
	elsif ($response =~ /NO/) {
		Log ("unexpected LOGIN response: $response");
		return 0;
	}
   }
   Log("Logged in as $user") if $debug;

   return 1;
}


#  logout
#
#  log out from the host
#
sub logout {

my $conn = shift;

   ++$lsn;
   undef @response;
   sendCommand ($conn, "$lsn LOGOUT");
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^$lsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected LOGOUT response: $response");
		last;
	}
   }
   close $conn;
   return;
}

#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse {

my $fd = shift;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    Log(">>$response") if $showIMAP;
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
    Log(">>$cmd") if $showIMAP;
}

#
#  insertMsg
#
#  Append a message to an IMAP mailbox
#

sub insertMsg {

my $mbx = shift;
my $message = shift;
my $flags = shift;
my $date  = shift;
my $conn  = shift;
my ($lsn,$lenx);

   Log("   Inserting message") if $debug;
   $lenx = length($$message);

print STDERR "lenx $lenx\n";

   if ( $debug ) {
      Log("$$message");
   }

    ($date) = split(/\s*\(/, $date);
    if ( $date =~ /,/ ) {
       $date =~ /(.+),\s+(.+)\s+(.+)\s+(.+)\s+(.+)\s+(.+)/;
       $date = "$2-$3-$4 $5 $6";
    } else {
       $date =~ s/\s/-/;
       $date =~ s/\s/-/;
    }

   #  Create the mailbox unless we have already done so
   ++$lsn;
   if ($destMbxs{"$mbx"} eq '') {
	sendCommand ($conn, "$lsn CREATE \"$mbx\"");
	while ( 1 ) {
	   readResponse ($conn);
	   if ( $response =~ /^$rsn OK/i ) {
		last;
	   }
	   elsif ( $response !~ /^\*/ ) {
		if (!($response =~ /already exists|reserved mailbox name/i)) {
			Log ("WARNING: $response");
		}
		last;
	   }
       }
   } 
   $destMbxs{"$mbx"} = '1';

   $flags =~ s/\\Recent//i;

   $cmd = "1 APPEND \"$mbx\" ($flags) \"$date\" \{$lenx\}\n";
   sendCommand ($conn, "1 APPEND \"$mbx\" ($flags) \"$date\" \{$lenx\}");
   readResponse ($conn);
   if ( $response !~ /^\+/ ) {
       Log ("unexpected APPEND response to $cmd");
       push(@errors,"Error appending message to $mbx for $user");
       return 0;
   }

   if ( $opt_x ) {
      print $conn "$$message\n";
   } else {
      print $conn "$$message\r\n";
   }

   undef @response;
   while ( 1 ) {
       readResponse ($conn);
       if ( $response =~ /^$lsn OK/i ) {
	   last;
       }
       elsif ( $response !~ /^\*/ ) {
	   Log ("unexpected APPEND response: $response");
	   return 0;
       }
   }

   return 1;
}

#  getMsgList
#
#  Get a list of the user's messages in the indicated mailbox on
#  the IMAP host
#
sub getMsgList {

my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $seen;
my $empty;
my $msgnum;

   Log("Getting list of msgs in $mailbox") if $debug;
   trim( *mailbox );
   sendCommand ($conn, "$rsn EXAMINE \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
	if ( $response =~ /^$rsn OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		return 0;
	}
   }

   sendCommand ( $conn, "$rsn FETCH 1:* (uid flags internaldate body[header.fields (Message-Id)])");
   undef @response;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ /^$rsn OK/i ) {
		last;
	}
   }

   #  Get a list of the msgs in the mailbox
   #
   undef @msgs;
   undef $flags;
   for $i (0 .. $#response) {
	$seen=0;
	$_ = $response[$i];

	last if /OK FETCH complete/;

	if ( $response[$i] =~ /FETCH \(UID / ) {
	   $response[$i] =~ /\* ([^FETCH \(UID]*)/;
	   $msgnum = $1;
	}

	if ($response[$i] =~ /FLAGS/) {
	    #  Get the list of flags
	    $response[$i] =~ /FLAGS \(([^\)]*)/;
	    $flags = $1;
   	    $flags =~ s/\\Recent//i;
	}
        if ( $response[$i] =~ /INTERNALDATE ([^\)]*)/ ) {
	    ### $response[$i] =~ /INTERNALDATE (.+) ([^BODY]*)/i; 
	    $response[$i] =~ /INTERNALDATE (.+) BODY/i; 
            $date = $1;
            $date =~ s/"//g;
	}
	if ( $response[$i] =~ /^Message-Id:/i ) {
	    ($label,$msgid) = split(/: /, $response[$i]);
	    push (@$msgs,$msgid);
	}
   }
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

