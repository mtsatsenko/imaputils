# IMAP::Utils - common parts of imaputils scripts
#use strict;
#use warnings;

package IMAP::Utils;
require Exporter;
@ISA = qw(Exporter);
@EXPORT= qw(Log openLog connectToHost readResponse 
        sendCommand signalHandler logout login conn_timed_out 
        getDelimiter @response hash trim deleteMsg isAscii createMbx 
        validate_date expungeMbx getMsgIdList getMailboxList mbxExists 
        selectMbx fetchMsg listMailboxes getMsgList fixup_date
		exclude_mbxs findMsg);

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

###
#deleteMsgs
#  Mark a message for deletion by setting \Deleted flag
sub deleteMsg {

my $msgnum = shift;
my $conn   = shift;
my $rc;

   return if $msgnum eq '';

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
   while (1) {
        $response = readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
           $rc = 1;
           Log("       Marked msg number $msgnum for delete");
           last;
        }

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Error setting \Deleted flag for msg $msgnum: $response");
           $rc = 0;
           last;
        }
   }

   return $rc;

}

#  Create the mailbox if necessary
sub createMbx {

my $mbx  = shift;
my $conn = shift;
my $suscribe = shift or 0;

   sendCommand ($conn, "1 CREATE \"$mbx\"");
   while ( 1 ) {
      $response = readResponse ($conn);
      last if $response =~ /^1 OK/i;
      last if $response =~ /already exists/i;
      if ( $response =~ /^1 NO|^1 BAD|^\* BYE/ ) {
         Log ("Error creating $mbx: $response");
         last;
      }
      if ( $response eq ''  or $response =~ /^1 NO/ ) {
         Log ("unexpected CREATE response: >$response<");
         Log("response is NULL");
         resume();
         last;
      }

   }

    #  Subcribe to it.
    if ($subscribe) {
        sendCommand( $conn, "1 SUBSCRIBE \"$mbx\"");
        while ( 1 ) {
            readResponse( $conn );
            if ( $response =~ /^1 OK/i ) {
                Log("Mailbox $mbx has been subscribed") if $debug;
                last;
            } elsif ( $response =~ /^1 NO|^1 BAD|\^* BYE/i ) {
                Log("Unexpected response to subscribe $mbx command: $response");
            last;
            }
        }
    }
}

#  Make sure the "after" date is in DD-MMM-YYYY format
sub validate_date {

my $date = shift;
my $invalid;

   my ($day,$month,$year) = split(/-/, $date);
   $invalid = 1 unless ( $day > 0 and $day < 32 );
   $invalid = 1 unless $month =~ /Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i;
   $invalid = 1 unless $year > 1900 and $year < 2999;
   if ( $invalid ) {
      Log("The 'Sent after' date $date must be in DD-MMM-YYYY format");
      exit;
   }
}

sub expungeMbx {

my $mbx   = shift;
my $conn  = shift;

   Log("Expunging mailbox $mbx");

   sendCommand ($conn, "1 SELECT \"$mbx\"");
   while (1) {
        $response = readResponse ($conn);
        last if ( $response =~ /1 OK/i );
   }

   sendCommand ( $conn, "1 EXPUNGE");
   $expunged=0;
   while (1) {
        $response = readResponse ($conn);
        $expunged++ if $response =~ /\* (.+) Expunge/i;
        last if $response =~ /^1 OK/;

    if ( $response =~ /^1 BAD|^1 NO/i ) {
       Log("Error purging messages: $response");
       last;
    }
   }

   $totalExpunged += $expunged;

   Log("$expunged messages expunged");

   return $expunged;
}

#  getMsgIdList
#
#  Get a list of the user's messages in a mailbox
#
sub getMsgIdList {

my $mailbox = shift;
my $msgids  = shift;
my $conn    = shift;
my $empty;
my $msgnum;
my $from;
my $msgid;

   %$msgids  = ();
   sendCommand ($conn, "1 EXAMINE \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
    $response = readResponse ( $conn );
    if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
    if ( $response =~ /^1 OK/i ) {
        # print STDERR "response $response\n";
        last;
    }
    elsif ( $response !~ /^\*/ ) {
        Log ("unexpected response: $response");
        # print STDERR "Error: $response\n";
        return 0;
    }
   }

   if ( $empty ) {
      return;
   }

   Log("Fetch the header info") if $debug;

   sendCommand ( $conn, "1 FETCH 1:* (body[header.fields (Message-Id)])");
   undef @response;
   while ( 1 ) {
    $response = readResponse ( $conn );
    return if $conn_timed_out;
    if ( $response =~ /^1 OK/i ) {
       last;
    } elsif ( $response =~ /could not be processed/i ) {
           Log("Error:  response from server: $response");
           return;
        } elsif ( $response =~ /^1 NO|^1 BAD/i ) {
           return;
        }
   }

   $flags = '';
   for $i (0 .. $#response) {
       $_ = $response[$i];

       last if /OK FETCH complete/;

       if ($response[$i] =~ /Message-ID:/i) {
          $response[$i] =~ /Message-Id: (.+)/i;
          $msgid = $1;
          trim(*msgid);
          if ( $msgid eq '' ) {
             # Line-wrap, get it from the next line
             $msgid = $response[$i+1];
             trim(*msgid);
          }
          $$msgids{"$msgid"} = 1;
       }
   }

}
#  getMailboxList
#
#  get a list of the user's mailboxes from the source host
#
sub getMailboxList {

my $prefix = shift;
my $conn   = shift;
my $mbxList   = shift;
my $submbxs = shift;
my @mbxs;

   #  Get a list of the user's mailboxes
   #

   Log("Get list of user's mailboxes",2) if $debug;

   if ( $mbxList ) {
      foreach $mbx ( split(/,/, $mbxList) ) {
         $mbx = $prefix . $mbx if $prefix;
         if ( $submbxs ) {
            # Get all submailboxes under the ones specified
            $mbx .= '*';
            @mailboxes = listMailboxes( $mbx, $conn);
            push( @mbxs, @mailboxes );
         } else {
            push( @mbxs, $mbx );
         }
      }
   } else {
      #  Get all mailboxes
      @mbxs = listMailboxes( '*', $conn);
   }

   return @mbxs;
}

#  listMailboxes
#
#  Get a list of the user's mailboxes
#

sub listMailboxes {

my $mbx  = shift;
my $conn = shift;

   sendCommand ($conn, "1 LIST \"\" \"$mbx\"");
   undef @response;
   while ( 1 ) {
        $response = readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
                last;
        }
        elsif ( $response !~ /^\*/ ) {
                &Log ("unexpected response: $response");
                return 0;
        }
   }

   @mbxs = ();
   for $i (0 .. $#response) {
        $response[$i] =~ s/\s+/ /;
        if ( $response[$i] =~ /"$/ ) {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" "(.+)"/i;
           $mbx = $3;
        } elsif ( $response[$i] =~ /\* LIST \((.*)\) NIL (.+)/i ) {
           $mbx   = $2;
        } else {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" (.+)/i;
           $mbx = $3;
        }
        $mbx =~ s/^\s+//;  $mbx =~ s/\s+$//;

        if ($response[$i] =~ /NOSELECT/i) {
           if ( $include_nosel_mbxs ) {
              $nosel_mbxs{"$mbx"} = 1;
           } else {
              Log("$mbx is set NOSELECT, skipping it") if $debug;
              next;
           }
        }
        if ($mbx =~ /^\./) {
            # Skip mailboxes starting with a dot
            next;
        }
        if ($mbx =~ /^\#|^Public Folders/i)  {
            #  Skip public mbxs
            next;
        }
        push ( @mbxs, $mbx ) if $mbx ne '';
   }

   return @mbxs;
}

#  Determine whether a mailbox exists
sub mbxExists {

my $mbx  = shift;
my $conn = shift;
my $status = 1;
#my $loops;

   #  Determine whether a mailbox exists
   sendCommand ($conn, "1 EXAMINE \"$mbx\"");
   while (1) {
        $response = readResponse ($conn);
        last if $response =~ /^1 OK/i;
        if ( $response =~ /^1 NO|^1 BAD|^\* BYE/ ) {
           $status = 0;
           last;
        }
#        if ( $loops++ > 1000 ) {
#           Log("No response to SELECT command, skipping this mailbox");
#           last;
#       } 
   }

   return $status;
}


sub selectMbx {

my $mbx = shift;
my $conn = shift;
my $mode = shift or 'SELECT';

   #  Some IMAP clients such as Outlook and Netscape) do not automatically list
   #  all mailboxes.  The user must manually subscribe to them.  This routine
   #  does that for the user by marking the mailbox as 'subscribed'.

   #sendCommand( $conn, "1 SUBSCRIBE \"$mbx\"");
   #while ( 1 ) {
   #   $response = readResponse( $conn );
   #   if ( $response =~ /^1 OK/i ) {
   #      Log("Mailbox $mbx has been subscribed") if $debug;
   #      last;
   #   } elsif ( $response =~ /^1 NO|^1 BAD|\^* BYE/i ) {
   #      Log("Unexpected response to subscribe $mbx command: $response");
   #      last;
   #   }
   #}

   Log("selecting mbx $mbx") if $debug;

   #  Now select the mailbox
   sendCommand( $conn, "1 $mode \"$mbx\"");
   while ( 1 ) {
      $response = readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD|^\* BYE/i ) {
         Log("Unexpected response to $mode $mbx command: $response");
         last;
      }
   }

}

#here should be reconnect sub
sub resume {
    Log("Fatal error, lost connection to either the source or destination");
    # Log("checkpoint $checkpoint");
    exit;
}

sub fetchMsg {

my $msgnum = shift;
my $conn   = shift;
my $message = shift;

   Log("   Fetching msg $msgnum...") if $debug;

   $$message = '';
   sendCommand( $conn, "1 FETCH $msgnum (rfc822)");
   while (1) {
    $response = readResponse ($conn);
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;

    if ( $response eq '' ) {
        Log("RESP2 >$response<");
        resume();
        return 0;
    }
    if ( $response =~ /^1 OK/i ) {
        $size = length($$message);
        last;
    }
    elsif ($response =~ /message number out of range/i) {
        Log ("Error fetching uid $uid: out of range",2);
        $stat=0;
        last;
    }
    elsif ($response =~ /Bogus sequence in FETCH/i) {
        Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
        $stat=0;
        last;
    }
    elsif ( $response =~ /message could not be processed/i ) {
        Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
        push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$destMbx)");
        $stat=0;
        last;
    }
    elsif
       ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
        ($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
        $cc = 0;
        $$message = "";
        while ( $cc < $len ) {
            $n = 0;
            $n = read ($conn, $segment, $len - $cc);
            if ( $n == 0 ) {
                Log ("unable to read $len bytes");
                                resume();
                return 0;
            }
            $$message .= $segment;
            $cc += $n;
        }
    }
   }

   return $$message;
}

#  getMsgList
#
#  Get a list of the user's messages in the indicated mailbox on
#  the source host
#
sub getMsgList {

my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $mode    = shift;
my $force    = shift or 0;
my $seen;
my $empty;
my $msgnum;
my $from;
my $flags;
my $msgid;

   @$msgs  = ();
   $mode = 'EXAMINE' unless $mode;
   sendCommand ($conn, "1 $mode \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
    $response = readResponse ( $conn );
    if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
    if ( $response =~ /^1 OK/i ) {
        last;
    }
    elsif ( $response !~ /^\*/ ) {
        Log ("unexpected response: $response");
        return 0;
    }
   }

   return 1 if $empty;

   my $start = 1;
   my $end   = '*';
   $start = $start_fetch if $start_fetch;
   $end   = $end_fetch   if $end_fetch;

   sendCommand ( $conn, "1 FETCH $start:$end (uid flags internaldate body[header.fields (From Date Message-Id)])");

   @response = ();
   while ( 1 ) {
    $response = readResponse ( $conn );

    if ( $response =~ /^1 OK/i ) {
        last;
    }
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;
   }

   $flags = '';
   for $i (0 .. $#response) {
    last if $response[$i] =~ /^1 OK FETCH complete/i;

        if ($response[$i] =~ /FLAGS/) {
           #  Get the list of flags
           $response[$i] =~ /FLAGS \(([^\)]*)/;
           $flags = $1;
           $flags =~ s/\\Recent//;
        }

        if ( $response[$i] =~ /INTERNALDATE/) {
           $response[$i] =~ /INTERNALDATE (.+) BODY/i;
           # $response[$i] =~ /INTERNALDATE "(.+)" BODY/;
           $date = $1;

           $date =~ /"(.+)"/;
           $date = $1;
           $date =~ s/"//g;
        }

        if ( $response[$i] =~ /^Message-Id:/i ) {
           $response[$i] =~ /^Message-Id: (.+)/i;
           $msgid = $1;
           trim(*msgid);
           if ( $msgid eq '' ) {
              # Line-wrap, get it from the next line
              $msgid = $response[$i+1];
              trim(*msgid);
           }
        }

        # if ( $response[$i] =~ /\* (.+) [^FETCH]/ ) {
        if ( $response[$i] =~ /\* (.+) FETCH/ ) {
           ($msgnum) = split(/\s+/, $1);
        }

        if ($force or ( $msgnum and $date and $msgid )) {
            push (@$msgs,"$msgnum|$date|$flags|$msgid");
           $msgnum = $date = $msgid = '';
        }
   }

   return 1;
}

sub fixup_date {

my $date = shift;

   #  Make sure the hrs part of the date is 2 digits.  At least
   #  one IMAP server expects this.

   $$date =~ s/^\s+//;
   $$date =~ /(.+) (.+):(.+):(.+) (.+)/;
   my $hrs = $2;

   return if length( $hrs ) == 2;

   my $newhrs = '0' . $hrs if length( $hrs ) == 1;
   $$date =~ s/ $hrs/ $newhrs/;

}

#  exclude_mbxs
#
#  Exclude certain mailboxes from the list if the user
#  has provided an exclude list with the -e argument

sub exclude_mbxs {

my $mbxs = shift;
my @new_list;
my %exclude;

   foreach my $exclude ( split(/,/, $excludeMbxs ) ) {
      $exclude{"$exclude"} = 1;
   }
   foreach my $mbx ( @$mbxs ) {
      next if $exclude{"$mbx"};
      push( @new_list, $mbx );
   }

   @$mbxs = @new_list;

}

sub findMsg {

my $conn  = shift;
my $msgid = shift;
my $mbx   = shift;
my $msgnum;
my $noSuchMbx;

   Log("SELECT $mbx") if $debug;
   &Log("Searching for $msgid in $mbx") if $debug;
   sendCommand ( $conn, "1 SELECT \"$mbx\"");
   while (1) {
    $response = readResponse ($conn);
    if ( $response =~ /^1 NO/ ) {
       $noSuchMbx = 1;
       last;
    }
    last if $response =~ /^1 OK/;
   }
   return '' if $noSuchMbx;

   Log("Search for $msgid") if $debug;
   sendCommand ( $conn, "$rsn SEARCH header Message-ID \"$msgid\"");
   while (1) {
    $response = readResponse ($conn);
    if ( $response =~ /\* SEARCH /i ) {
       ($dmy, $msgnum) = split(/\* SEARCH /i, $response);
       ($msgnum) = split(/ /, $msgnum);
    }

    last if $response =~ /^1 OK/;
    last if $response =~ /complete/i;
   }

   if ( $msgnum ) {
      &Log("Message exists") if $debug;
   } else {
      &Log("Message does not exist") if $debug;
   }

   return $msgnum;
}

1;
